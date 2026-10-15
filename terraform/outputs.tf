output "private_network_id" {
  value = arvancloud_iaas_network.private.id
}
output "private_subnet_id" {
  value = arvancloud_iaas_network.private.subnet_id
}
output "server_ids" {
  value = {
    for name, server in arvancloud_iaas_server.node :
    name => server.id
  }
}
output "public_ips" {
  value = {
    for name, ip in arvancloud_iaas_public_ip.node :
    name => ip.public_ip
  }
}
