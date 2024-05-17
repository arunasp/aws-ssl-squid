# aws-ssl-squid

Transparent routing Whitelist SSL proxy.
Requires Ellastic Interface ID for public subnet routing and whitelist URLs list (one entry per line).

## Required environment variables

`${vpc_cidr}` - VPC subnet CIDR
`$NIC_EC2` - Ellastic Interface ID for Squid EC2 instance
`${http_proxy_port}` - Squid public proxy port
`${http_transparent_proxy_port}` - Squid internal transparent proxy SSL port for traffic interception
`${allowed_sites}`  - Whitelist domains for Squid SSL proxy
`${cloudwatch_agent_config}` - AWS Cloudwatch agent configuration
