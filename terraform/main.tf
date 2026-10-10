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

resource "incus_instance" "test" {
	remote = "dell"
	name = "tf-test-1"
	project = "iac"
	image = "images:debian/12/cloud"
	type = "virtual-machine"
	profiles = ["default"]
	
	config = {
		"limits.cpu" = "1"
		"limits.memory" = "1GiB"
		"cloud-init.user-data" = file("${path.module}/cloud-init.yaml")
	}
}

output "test_ip" {
	value = incus_instance.test.ipv4_address
}
