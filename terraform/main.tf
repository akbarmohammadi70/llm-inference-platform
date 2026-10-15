
# ============================================================
# Private Network
# ============================================================
resource "arvancloud_iaas_network" "private" {
  name              = var.network_name
  availability_zone = var.availability_zone
  cidr              = var.network_cidr
  enable_dhcp       = var.enable_dhcp
  dhcp_range        = var.dhcp_range
  dns_servers       = join(",", var.dns_servers)
  enable_gateway    = var.enable_gateway
}
# ============================================================
# Servers
# Two NICs per node:
#   1. private NIC: attached at creation via private_network_ids
#      (private IP assigned by DHCP)
#   2. public NIC:  attached afterwards by arvancloud_iaas_public_ip
# ============================================================
resource "arvancloud_iaas_server" "node" {
  for_each          = var.servers
  name              = each.key
  availability_zone = var.availability_zone
  flavor_id         = each.value.flavor_id
  image_id          = var.image_id
  disk_size         = var.disk_size
  ha_enabled        = var.ha_enabled
  key_name          = var.ssh_key_name
  enable_backup     = var.enable_backup
  # The public NIC is added by arvancloud_iaas_public_ip below.
  enable_ipv4         = false
  enable_ipv6         = false
  private_network_ids = [arvancloud_iaas_network.private.id]
  security_groups = [
    var.default_security_group_id
  ]
  lifecycle {
    ignore_changes = [
      security_groups
    ]
  }
}

# ============================================================
# Public IPs
# Terraform obtains the assigned public IPs automatically.
# The NIC is hot-plugged, so the OS only configures it after
# the reboot below.
# ============================================================
resource "arvancloud_iaas_public_ip" "node" {
  for_each          = arvancloud_iaas_server.node
  server_id         = each.value.id
  availability_zone = var.availability_zone
  ip_type           = "ipv4"
  security_groups = [
    var.default_security_group_id
  ]
  lifecycle {
    ignore_changes = [security_groups]
  }
}
# ============================================================
# Reboot each node once, after the public IP is attached,
# so the OS configures the hot-plugged public NIC.
# (Done through the API, so it does not need SSH.)
# ============================================================
resource "arvancloud_iaas_server_action" "reboot" {
  for_each   = arvancloud_iaas_server.node
  server_id  = each.value.id
  action     = "reboot"
  depends_on = [arvancloud_iaas_public_ip.node]
}
# The action does not wait for the server to come back, so wait here.
resource "time_sleep" "after_reboot" {
  for_each        = var.servers
  create_duration = "40s"
  triggers = {
    reboot = arvancloud_iaas_server_action.reboot[each.key].id
  }
}
# SSH over the public IP only works after the reboot,
# so this also waits until the node is reachable.
resource "null_resource" "wait_for_node" {
  for_each = var.servers
  triggers = {
    waited = time_sleep.after_reboot[each.key].id
  }
  connection {
    type        = "ssh"
    host        = arvancloud_iaas_public_ip.node[each.key].public_ip
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "10m"
  }
  provisioner "remote-exec" {
    inline = ["uptime"]
  }
}
# ============================================================
# Kernel Tuning (after the node is reachable)
# ============================================================
resource "null_resource" "kernel_tuning" {
  for_each = var.servers
  triggers = {
    server_id = arvancloud_iaas_server.node[each.key].id
    public_ip = arvancloud_iaas_public_ip.node[each.key].public_ip
  }
  connection {
    type        = "ssh"
    host        = arvancloud_iaas_public_ip.node[each.key].public_ip
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "10m"
  }
  provisioner "file" {
    source      = "${path.module}/scripts/kernel-tuning.sh"
    destination = "/tmp/kernel-tuning.sh"
  }
  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/kernel-tuning.sh",
      "bash /tmp/kernel-tuning.sh",
      "rm -f /tmp/kernel-tuning.sh"
    ]
  }
  depends_on = [null_resource.wait_for_node]
}
# ============================================================
# Install Kubespray
# ============================================================
resource "null_resource" "install_kubespray" {
  triggers = {
    server_ids = join(",", [
      for name in sort(keys(arvancloud_iaas_server.node)) :
      arvancloud_iaas_server.node[name].id
    ])
    public_ips = jsonencode({
      for name, ip in arvancloud_iaas_public_ip.node :
      name => ip.public_ip
    })
    network_cidr = var.network_cidr
    version      = var.kubespray_version
  }
  depends_on = [
    arvancloud_iaas_public_ip.node,
    null_resource.kernel_tuning
  ]
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "bash \"${path.module}/scripts/install-kubespray.sh\""
    environment = {
      PROJECT_DIR          = path.module
      KUBESPRAY_VERSION    = var.kubespray_version
      KUBESPRAY_WORKDIR    = "${path.module}/.work/kubespray"
      SSH_USER             = var.ssh_user
      SSH_PRIVATE_KEY_PATH = pathexpand(var.ssh_private_key_path)
      MASTER_PUBLIC_IP     = arvancloud_iaas_public_ip.node["master"].public_ip
      WORKER1_PUBLIC_IP    = arvancloud_iaas_public_ip.node["worker1"].public_ip
      WORKER2_PUBLIC_IP    = arvancloud_iaas_public_ip.node["worker2"].public_ip
      # First three octets of the private network, e.g. "192.168.40."
      PRIVATE_NET_PREFIX = "${join(".", slice(split(".", var.network_cidr), 0, 3))}."
    }
  }
}
# ============================================================
# VictoriaMetrics Storage
# ============================================================
resource "null_resource" "victoria_metrics_storage" {
  for_each = var.servers
  triggers = {
    server_id = arvancloud_iaas_server.node[each.key].id
    public_ip = arvancloud_iaas_public_ip.node[each.key].public_ip
    data_path = "/data/victoria-metrics"
  }
  connection {
    type        = "ssh"
    host        = arvancloud_iaas_public_ip.node[each.key].public_ip
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "10m"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo mkdir -p /data/victoria-metrics",
      "sudo chmod 755 /data/victoria-metrics"
    ]
  }
  depends_on = [
    null_resource.kernel_tuning
  ]
}
# ============================================================
# Post-install on Master
# ============================================================
resource "null_resource" "post_install_master" {
  triggers = {
    master_id = arvancloud_iaas_server.node["master"].id
    public_ip = arvancloud_iaas_public_ip.node["master"].public_ip
  }
  depends_on = [
    null_resource.install_kubespray,
    null_resource.victoria_metrics_storage
  ]
  connection {
    type        = "ssh"
    host        = arvancloud_iaas_public_ip.node["master"].public_ip
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "10m"
  }
  provisioner "file" {
    source      = "${path.module}/scripts/post-kubespray-master.sh"
    destination = "/tmp/post-kubespray-master.sh"
  }
  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/post-kubespray-master.sh",
      "sudo bash /tmp/post-kubespray-master.sh",
      "rm -f /tmp/post-kubespray-master.sh"
    ]
  }
}
