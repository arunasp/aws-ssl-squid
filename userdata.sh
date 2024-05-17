NIC_EC2=$(sudo ip -o address show scope global | head -n 1 | cut -f2 -d' ')
NIC_IF="$NIC_EC2"
NIC_MAC=""
if [ ! -z "${nic_allocation_id}" ]; then
  echo "************* Associate with the static IP address *******************"
  INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
  AZ_ID=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)

  NIC_ID=$(aws ec2 describe-network-interfaces \
    --filters "Name=network-interface-id,Values=${nic_allocation_id}" "Name=availability-zone, Values=$AZ_ID"  \
    --query 'NetworkInterfaces[*].NetworkInterfaceId' \
    --region ${aws_region} \
    --output text | sed ':a;N;$!ba;s/\n/,/g')

  aws ec2 attach-network-interface \
      --network-interface-id $NIC_ID \
      --instance-id $INSTANCE_ID \
      --device-index 1 \
      --region ${aws_region}

  NIC_MAC=$(aws ec2 describe-network-interfaces \
    --filters "Name=network-interface-id,Values=$NIC_ID" \
    --query 'NetworkInterfaces[*].MacAddress' \
    --region ${aws_region} \
    --output text | sed ':a;N;$!ba;s/\n/,/g')


  NIC_IF=$(sudo ip -o link show | grep $NIC_MAC | cut -f2 -d':' | tr -d ' ')
fi

sudo yum update -y
## Now ready to install SQUID

echo "************* Install and configure Squid proxy *******************"
sudo yum install -y squid

sudo mkdir /etc/squid/ssl
cd /etc/squid/ssl
### FIXME: replace with AWS ACM signed certificate
sudo openssl genrsa -out squid.key 2048
sudo openssl req -new -key squid.key -out squid.csr -subj "/C=XX/ST=XX/L=squid/O=squid/CN=squid"
sudo openssl x509 -req -days 3650 -in squid.csr -signkey squid.key -out squid.crt
sudo cat squid.key squid.crt | sudo tee squid.pem

sudo touch /etc/squid/allowed_sites
sudo echo "${allowed_sites}" | base64 --decode > /etc/squid/allowed_sites

cat | sudo tee /etc/squid/squid.conf <<EOF
visible_hostname squid
dns_v4_first on # Prefer IPv4 DNS lookups
cache_mem 500 MB
cache_mgr support@example.com
minimum_expiry_time 300 seconds # I decided to set it for just 5 minutes and not more, because it's already not easy to debug
# Debug
#debug_options ALL,2 28,9

#Handling HTTP requests
http_port ${http_proxy_port} # HTTP Proxy mode
http_port ${http_transparent_proxy_port} intercept
#Handling HTTPS requests
https_port ${https_proxy_port} cert=/etc/squid/ssl/squid.pem # SSL Proxy mode
https_port ${https_transparent_proxy_port} cert=/etc/squid/ssl/squid.pem ssl-bump intercept generate-host-certificates=on dynamic_cert_mem_cache_size=12MB
always_direct allow all
sslproxy_options NO_SSLv2,NO_SSLv3,SINGLE_DH_USE
sslproxy_flags DONT_VERIFY_PEER

acl allowed_http_sites dstdomain "/etc/squid/allowed_sites"
acl allowed_https_sites ssl::server_name -i "/etc/squid/allowed_sites"
#acl allowed_https_sites ssl::server_name www.google.com
acl HTTP_Ports port 80 # http
acl SSL_Ports port 443 # https
acl SSL_Ports port 8443 # alt https
acl localnet src ${vpc_cidr} # local VPC
acl CONNECT method CONNECT

http_access deny !HTTP_Ports !SSL_Ports
http_access deny CONNECT !SSL_ports
http_access allow localhost manager
http_access deny manager
http_access deny to_localhost

http_access allow allowed_http_sites
http_access allow allowed_https_sites

http_access allow CONNECT localnet
http_access allow localhost

http_access deny all

# SslBump https://wiki.squid-cache.org/Features/SslPeekAndSplice#processing-steps
acl step1 at_step SslBump1 # SslBump1: After getting TCP-level and HTTP CONNECT info.
acl step2 at_step SslBump2 # SslBump2: After getting SSL Client Hello info.
acl step3 at_step SslBump3 # SslBump3: After getting SSL Server Hello info.

# https://wiki.squid-cache.org/Features/SslPeekAndSplice#actions
ssl_bump peek step1
ssl_bump peek step2 allowed_https_sites
ssl_bump terminate step2 all
ssl_bump splice all
EOF

if [ ! -d /var/lib/ssl_db ]; then
  /usr/lib64/squid/ssl_crtd -c -s /var/lib/ssl_db && chown -R squid: /var/lib/ssl_db
fi

sudo yum install iptables-services -y
sudo iptables -t nat -A PREROUTING -i $NIC_IF -p tcp --dport 80 -j REDIRECT --to-port ${http_transparent_proxy_port}
sudo iptables -t nat -A PREROUTING -i $NIC_IF -p tcp --dport 443 -j REDIRECT --to-port ${https_transparent_proxy_port}
sudo iptables -t nat -A PREROUTING -i $NIC_IF -p tcp --dport 8443 -j REDIRECT --to-port ${https_transparent_proxy_port}
sudo iptables -t nat -A POSTROUTING -p tcp --dport 53 -o $NIC_EC2 -j MASQUERADE # DNS
sudo iptables -t nat -A POSTROUTING -p udp --dport 53 -o $NIC_EC2 -j MASQUERADE # DNS
sudo iptables -t nat -A POSTROUTING -p tcp --dport 123 -o $NIC_EC2 -j MASQUERADE # NTP
sudo iptables -t nat -A POSTROUTING -p udp --dport 123 -o $NIC_EC2 -j MASQUERADE # NTP
sudo iptables -t nat -A POSTROUTING -p tcp -m limit --syn --limit 2/min -o $NIC_EC2 -j LOG --log-prefix "DROP TCP " # Log unknown TCP
sudo iptables -t nat -A POSTROUTING -p udp -m limit --limit 2/min -o $NIC_EC2 -j LOG --log-prefix "DROP UDP " # Log unknown UDP
sudo service iptables save
sysctl -w "net.ipv4.ip_forward=1"
grep -qxF 'net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >>/etc/sysctl.conf
sudo service iptables restart

sudo service squid start

## now configure the agent
## install CW Agent
sudo yum install -y amazon-cloudwatch-agent
sudo touch /opt/aws/amazon-cloudwatch-agent/bin/config.json
sudo echo "${cloudwatch_agent_config}" | base64 --decode > /opt/aws/amazon-cloudwatch-agent/bin/config.json
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/bin/config.json -s
