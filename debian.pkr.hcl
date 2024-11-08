packer {
  required_plugins {
    proxmox = {
      version = ">= 1.1.3"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

variable "iso_file" {
  type    = string
  default = "local:iso/debian-12.7.0-amd64-netinst.iso"
}

variable "cloudinit_storage_pool" {
  type    = string
  default = "local-zfs"
}

variable "cores" {
  type    = string
  default = "2"
}

variable "disk_format" {
  type    = string
  default = "raw"
}

variable "disk_size" {
  type    = string
  default = "20G"
}

variable "disk_storage_pool" {
  type    = string
  default = "local-zfs"
}

variable "cpu_type" {
  type    = string
  default = "host"
}

variable "memory" {
  type    = string
  default = "2048"
}

variable "network_vlan" {
  type    = string
  default = ""
}

variable "machine_type" {
  type    = string
  default = ""
}

variable "proxmox_api_password" {
  type      = string
  sensitive = true
}

variable "proxmox_api_user" {
  type = string
}

variable "proxmox_host" {
  type = string
}

variable "proxmox_node" {
  type = string
}

source "proxmox-iso" "debian" {
  username                 = var.proxmox_api_user
  password                 = var.proxmox_api_password
  proxmox_url              = "https://${var.proxmox_host}/api2/json"
  node                     = var.proxmox_node
  insecure_skip_tls_verify = true
  template_description     = "Built from ${basename(var.iso_file)} on ${formatdate("YYYY-MM-DD hh:mm:ss ZZZ", timestamp())}"

  boot_iso {
    type         = "scsi"
    unmount      = true
    iso_file     = var.iso_file
    iso_checksum = "sha512:e0bd9ba03084a6fd42413b425a2d20e3731678a31fe5fb2cc84f79332129afca2ad4ec897b4224d6a833afaf28a5d938b0fe5d680983182944162c6825b135ce"
  }

  network_adapters {
    bridge   = "vmbr0"
    firewall = true
    model    = "virtio"
    vlan_tag = var.network_vlan
  }

  disks {
    disk_size    = var.disk_size
    format       = var.disk_format
    io_thread    = true
    storage_pool = var.disk_storage_pool
    type         = "scsi"
  }

  scsi_controller = "virtio-scsi-single"

  http_directory          = "./"
  boot_wait               = "5s"
  boot_command            = ["<esc><wait>auto url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg<enter>"]
  cloud_init              = true
  cloud_init_storage_pool = var.cloudinit_storage_pool

  vm_name  = trimsuffix(basename(var.iso_file), ".iso")
  cpu_type = var.cpu_type
  os       = "l26"
  memory   = var.memory
  cores    = var.cores
  sockets  = "1"
  machine  = var.machine_type

  # Note: this password is needed by packer to run the file provisioner, but
  # once that is done - the password will be set to random one by cloud init.
  ssh_password = "packer"
  ssh_username = "root"
}


build {
  sources = ["source.proxmox-iso.debian"]

  provisioner "file" {
    destination = "/etc/cloud/cloud.cfg"
    source      = "cloud.cfg"
  }
}
