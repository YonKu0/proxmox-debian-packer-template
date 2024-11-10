# --- Required Plugins ---
packer {
  required_plugins {
    proxmox = {
      version = ">= 1.1.3"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

# --- Variables: VM Configuration ---
variable "proxmox_host" {
  type        = string
  description = "The Proxmox host IP and port"
}

variable "proxmox_node" {
  type        = string
  description = "The Proxmox node where the VM will be created"
}

variable "proxmox_api_user" {
  type        = string
  description = "The Proxmox API user"
}

variable "proxmox_api_password" {
  type        = string
  sensitive   = true
  description = "The Proxmox API user password"
}

# --- Variables: ISO Configuration ---
variable "iso_file" {
  type        = string
  description = "The ISO file to be used for VM creation"
  default     = "local:iso/debian-12.7.0-amd64-netinst.iso"
}

variable "iso_checksum" {
  type        = string
  description = "The checksum of the ISO file"
  default     = "sha512:e0bd9ba03084a6fd42413b425a2d20e3731678a31fe5fb2cc84f79332129afca2ad4ec897b4224d6a833afaf28a5d938b0fe5d680983182944162c6825b135ce"
}

# --- Variables: VM Hardware ---
variable "cloudinit_storage_pool" {
  type        = string
  description = "The storage pool for cloud-init configuration"
  default     = "local-zfs"
}

variable "disk_storage_pool" {
  type        = string
  description = "The storage pool for VM disks"
  default     = "local-zfs"
}

variable "cores" {
  type        = number
  description = "Number of CPU cores"
  default     = 2
}

variable "memory" {
  type        = number
  description = "Memory size in MB"
  default     = 2048
}

variable "disk_size" {
  type        = string
  description = "Disk size for the VM"
  default     = "20G"
}

variable "disk_format" {
  type        = string
  description = "Disk format type"
  default     = "raw"
}

variable "cpu_type" {
  type        = string
  description = "CPU type"
  default     = "host"
}

variable "network_vlan" {
  type        = string
  description = "VLAN tag for the network adapter"
  default     = ""
}

variable "machine_type" {
  type        = string
  description = "Machine type for the VM"
  default     = ""
}

# --- Source Configuration ---
source "proxmox-iso" "debian" {
  node                     = var.proxmox_node
  username                 = var.proxmox_api_user
  password                 = var.proxmox_api_password
  proxmox_url              = "https://${var.proxmox_host}/api2/json"
  insecure_skip_tls_verify = true

  template_description = "Built from ${basename(var.iso_file)} on ${formatdate("YYYY-MM-DD hh:mm:ss ZZZ", timestamp())}"

  # --- Boot ISO Configuration ---
  boot_iso {
    type         = "scsi"
    unmount      = true
    iso_file     = var.iso_file
    iso_checksum = var.iso_checksum
  }

  # --- Network Configuration ---
  network_adapters {
    bridge   = "vmbr0"
    firewall = true
    model    = "virtio"
    vlan_tag = var.network_vlan
  }

  # --- Disk Configuration ---
  disks {
    disk_size    = var.disk_size
    format       = var.disk_format
    io_thread    = true
    storage_pool = var.disk_storage_pool
    type         = "scsi"
  }

  # --- VM Agent & CloudInit ---
  qemu_agent              = true
  cloud_init              = true
  cloud_init_storage_pool = var.cloudinit_storage_pool

  # --- VM Properties ---
  vm_name         = trimsuffix(basename(var.iso_file), ".iso")
  cpu_type        = var.cpu_type
  os              = "l26"
  memory          = var.memory
  cores           = var.cores
  sockets         = 1
  scsi_controller = "virtio-scsi-single"
  machine         = var.machine_type

  # --- SSH Settings for Provisioning ---
  ssh_username = "root"
  // Root password seted in the preseed.cfg file
  ssh_password = "packer"
  ssh_timeout  = "10m"

  # --- HTTP Boot Configuration ---
  http_directory = "./"
  boot_wait      = "5s"
  boot_command   = ["<esc><wait>auto url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg<enter>"]
}

# --- Build Configuration ---
build {
  sources = ["source.proxmox-iso.debian"]

  # Step 1: Copy the cloud-init configuration files
  provisioner "file" {
    source      = "files/99-pve-datasource.cfg"
    destination = "/tmp/99-pve-datasource.cfg"
  }

  provisioner "file" {
    source      = "files/user-data"
    destination = "/tmp/user-data"
  }

  provisioner "file" {
    source      = "files/meta-data"
    destination = "/tmp/meta-data"
  }

  # Step 2: Move the configuration files to the correct locations
  provisioner "shell" {
    inline = [
      # Copy the cloud-init configuration for Proxmox
      "sudo cp /tmp/99-pve-datasource.cfg /etc/cloud/cloud.cfg.d/99-pve-datasource.cfg",
      "sudo chmod 644 /etc/cloud/cloud.cfg.d/99-pve-datasource.cfg",

      # Copy user-data and meta-data files
      "sudo mkdir -p /var/lib/cloud/seed/nocloud/",
      "sudo cp /tmp/user-data /var/lib/cloud/seed/nocloud/user-data",
      "sudo cp /tmp/meta-data /var/lib/cloud/seed/nocloud/meta-data",
      "sudo chmod 644 /var/lib/cloud/seed/nocloud/*"
    ]
  }


  # --- Provisioners ---
  # Step 3: Provision the VM to install cloud-init and configure it
  provisioner "shell" {
    inline = [
      # Install cloud-init if not already installed
      "sudo apt-get install -y cloud-init",

      # Enable and start cloud-init service
      "sudo systemctl daemon-reload",
      "sudo systemctl enable cloud-init",
      "sudo systemctl start cloud-init",

      # Clean up cloud-init state and reinitialize
      "sudo cloud-init clean",
      "sudo cloud-init init",
      "sudo cloud-init status --wait",

      # Remove SSH host keys to regenerate on first boot
      "sudo rm -f /etc/ssh/ssh_host_*",

      # Clear machine ID to ensure uniqueness
      "sudo truncate -s 0 /etc/machine-id",

      # Clean up unused packages and files
      "sudo apt-get autoremove -y --purge",
      "sudo apt-get clean -y",
      "sudo apt-get autoclean -y",

      # Remove potentially conflicting cloud-init network config
      "sudo rm -f /etc/cloud/cloud.cfg.d/subiquity-disable-cloudinit-networking.cfg",

      # Ensure all changes are written to disk
      "sudo sync"
    ]
  }

  # Provisioning the VM Template with Docker Installation 
  provisioner "shell" {
    script = "scripts/install_docker.sh"
  }
}
