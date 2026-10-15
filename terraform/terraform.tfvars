api_key              = "<API-KEY>"
availability_zone    = "ir-central1-b"
ssh_user             = "root"
network_name         = "app-private-network"
network_cidr         = "192.168.40.0/24"
ssh_key_name         = "macair"
enable_dhcp          = true
dhcp_range           = "192.168.40.10-192.168.40.200"
kubespray_version    = "v2.32.0"
ssh_private_key_path = "~/.ssh/id_ed25519"
dns_servers = [
  "1.1.1.1",
  "8.8.8.8",
  "4.2.2.4"
]
default_security_group_id = "68e36522-e082-4210-bbf8-0c5e7c7e5571"
enable_gateway            = false
image_id                  = "0a020563-cfda-4441-ba34-f69781bbb2d7"
disk_size                 = 75
ha_enabled                = true
enable_backup             = false
enable_port_security      = true
servers = {
  master = {
    flavor_id = "g2-8-4-0"
  }
  worker1 = {
    flavor_id = "g2-8-4-0"
  }
  worker2 = {
    flavor_id = "g2-8-4-0"
  }
}