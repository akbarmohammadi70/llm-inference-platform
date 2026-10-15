variable "api_key" {
  description = "ArvanCloud API key"
  type        = string
  sensitive   = true
}
variable "availability_zone" {
  description = "ArvanCloud availability zone"
  type        = string
}
variable "network_name" {
  description = "Private network name"
  type        = string
}
variable "network_cidr" {
  description = "Private network CIDR"
  type        = string
}
variable "enable_dhcp" {
  description = "Enable DHCP on the private network"
  type        = bool
}
variable "dhcp_range" {
  description = "DHCP address range"
  type        = string
}
variable "dns_servers" {
  description = "DNS server addresses"
  type        = list(string)
}
variable "enable_gateway" {
  description = "Enable private network gateway"
  type        = bool
}
variable "image_id" {
  description = "ArvanCloud operating system image ID"
  type        = string
}
variable "disk_size" {
  description = "Server disk size in GB"
  type        = number
}
variable "ha_enabled" {
  description = "Enable high availability for servers"
  type        = bool
}
variable "enable_backup" {
  description = "Enable server backups"
  type        = bool
}
variable "enable_port_security" {
  description = "Enable security on network ports"
  type        = bool
}
variable "ssh_user" {
  description = "SSH user on the Ubuntu servers"
  type        = string
}
variable "ssh_key_name" {
  description = "SSH public key name registered in ArvanCloud"
  type        = string
}
variable "ssh_private_key_path" {
  description = "Path to the SSH private key"
  type        = string
}
variable "kubespray_version" {
  description = "Kubespray Git version or tag"
  type        = string
}
variable "servers" {
  description = "Kubernetes server definitions"
  type = map(object({
    flavor_id = string
  }))
  validation {
    condition = (
      contains(keys(var.servers), "master") &&
      contains(keys(var.servers), "worker1") &&
      contains(keys(var.servers), "worker2")
    )
    error_message = "The servers map must contain master, worker1, and worker2."
  }
}

variable "default_security_group_id" {
  type = string
}