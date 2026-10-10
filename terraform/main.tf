terraform{
	required_providers {
		incus = {
			source = "lxc/incus"
			version = "~> 1.0"
		}
	}
}

provider "incus" {
	config_dir = "/Users/priyanshukumarjha/Library/Application Support/incus"
	generate_client_certificates = false
	accept_remote_certificate = false
	default_remote = "dell"
}

locals {
	vms = {
		"iac-1" = "10.95.18.201"
		"iac-2" = "10.95.18.202"
	}
}

resource "incus_instance" "vm" {
	for_each = local.vms

	remote = "dell"
	name = each.key
	project = "iac"
	image = "images:debian/12/cloud"
	type = "virtual-machine"
	profiles = ["default"]

	device {
		name = "eth0"
		type = "nic"
		properties = {
			network = "incusbr0"
			"ipv4.address" = each.value
		}
	}	

	config = {
		"limits.cpu" = "1"
		"limits.memory" = "1GiB"
		"cloud-init.user-data" = file("${path.module}/cloud-init.yaml")
	}
}

output "vm_ips" {
	value = local.vms
}
