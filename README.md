# homelab-iac

Infrastructure As Code for my self hosted homelab. Terraform creates Incus VMs on my Debian machine, Ansible configures them, and Prometheus monitors them. A destroyed VM is rebuilt and fully configured with a single script.


## Architecture

```
 MacBook (control plane)                 Dell Vostro (homelab, Debian)
┌──────────────────────┐   Incus API    ┌──────────────────────────────────────────┐
│ Terraform            │ ─────────────▶ │ Incus (project: iac)                     │
│  (lxc/incus provider)│   :8443, mTLS  │   ├─ iac-1  10.95.18.201                 │
│                      │                │   └─ iac-2  10.95.18.202                 │
│ Ansible              │ ── SSH via ──▶ │        ▲ cloud-init (SSH key, user)      │
│                      │   jump host    │        │                                 │
└──────────────────────┘                │ apt-cacher-ng :3142 (package cache)      │
                                        │ Prometheus ◀── scrapes node_exporter     │
                                        │                :9100 on each VM          │
                                        └──────────────────────────────────────────┘
```

- Terraform runs on the Mac and talks to the Dell's Incus API over HTTPS with client-certificate authentication.
- VMs live in a dedicated Incus project (`iac`), so Terraform can never touch other instances on the host.
- cloud-init creates an `ansible` user with my SSH key and installs `openssh-server` on first boot.
- Ansible reaches the VMs by SSH through the Dell as a jump host (the VM addresses are on a private bridge).
- VMs have fixed IPs, so the Ansible inventory and Prometheus targets survive rebuilds.

## Repository layout

```
homelab-iac/
├── terraform/
│   ├── main.tf            # Incus provider, VM definitions (for_each), fixed IPs
│   └── cloud-init.yaml    # first-boot user, SSH key, openssh-server
├── ansible/
│   ├── ansible.cfg
│   ├── inventory.ini      # fixed VM addresses
│   ├── site.yml
│   └── roles/
│       ├── hardening/     # ufw, fail2ban, SSH config, apt cache proxy
│       ├── docker/        # Docker from the Debian repositories
│       └── node_exporter/ # Prometheus node exporter + firewall rule
└── rebuild-timer.sh                 # destroy, recreate and reconfigure one VM, with timings
```

## Prerequisites

| Where             | What                                                                            |
|-------------------|---------------------------------------------------------------------------------|
| Dell (Incus host) | Incus with the HTTPS API enabled, Docker (for the apt cache), Prometheus        |
| Mac               | `terraform`, `ansible`, `incus` client (`brew install terraform ansible incus`) |
| Network           | The Mac can SSH to the Dell; both are on the same network or Tailscale          |

## One-time setup

**On the Dell**

```bash
# Expose the Incus API (bind to a private/Tailscale address, not 0.0.0.0)
incus config set core.https_address <machine-ip-tailscale/private>:8443

# A separate project for Terraform-managed VMs; reuse existing profiles and images
incus project create iac -c features.profiles=false -c features.images=false

# One-time trust token for the Mac
incus config trust add mac-terraform

# Package cache used by the VMs
docker run -d --name apt-cacher-ng --restart unless-stopped \
  -p 3142:3142 -v apt-cache:/var/cache/apt-cacher-ng \
  sameersbn/apt-cacher-ng
```

**On the Mac**

```bash
incus remote add dell <machine-ip-tailscale/private>:8443     # paste the token when asked
incus list dell: --project iac          		      # should be empty
```

**SSH jump host** (`~/.ssh/config` on the Mac):

```
Host dell
  HostName <dell-hostname-or-ip>
  User <dell-user>

Host 10.95.*
  ProxyJump dell
  User ansible
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
```

Host-key checking is disabled for the lab subnet because the VMs are disposable and get new keys on every rebuild. Do not use this for real servers.

**Edit before first use**

- `terraform/cloud-init.yaml`: replace the SSH public key with yours.
- `terraform/main.tf`: set `config_dir` in the provider block to your Incus client config directory (on macOS: `~/Library/Application Support/incus`, as a full path), and adjust the VM list and IPs in `locals`.
- Prometheus: add a scrape job for the VMs (see Monitoring).

## Usage

**Create the VMs**

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

**Configure them**

```bash
cd ../ansible
ansible-playbook site.yml
ansible-playbook site.yml     # second run should report changed=0 (idempotent)
```

**Rebuild one VM from scratch and time it**

```bash
./rebuild-timer.sh
```

The script destroys `iac-2`, recreates it, waits for SSH, runs the full playbook against it, and prints the time for each phase.

## What the Ansible roles do

| Role | Does |
|---|---|
| `hardening` | Uses the apt cache; installs ufw, fail2ban and `python3-systemd`; disables SSH password and root login; allows SSH and enables the firewall with default-deny; configures the fail2ban `sshd` jail to read the systemd journal |
| `docker` | Installs `docker.io` from Debian, enables the service, adds the `ansible` user to the `docker` group |
| `node_exporter` | Installs `prometheus-node-exporter` and opens port 9100 to the Incus bridge subnet only |

All roles are idempotent: a second run reports `changed=0`.

## Monitoring

Prometheus on the Dell scrapes `node_exporter` on each VM. Add to `prometheus.yml`:

```yaml
  - job_name: 'iac-vms'
    static_configs:
      - targets: ['10.95.18.201:9100', '10.95.18.202:9100']
```

Because the VMs have fixed addresses, the targets stay valid across rebuilds.

## Rebuild timings

Measured with `rebuild-timer.sh` on the Dell Vostro (i5, 8 GB RAM) over a phone-hotspot connection. Each run destroys `iac-2`, recreates it, and runs the full playbook against it.

| Phase | Without apt cache | With apt cache |
|---|---|---|
| Terraform creates the VM | 24 s | 24 s |
| SSH reachable (cloud-init) | 107 s | 92 s |
| Fully configured (Ansible done) | 1206 s (~20 min) | **200 s (~3 min 20 s)** |

The apt caching proxy cut the full rebuild by about 6x. Over the test period, apt-cacher-ng served 57% of requests (66% of data) from cache.

## What broke, and how I fixed it

**Terraform could not find the Dell.** The provider tried a local Incus socket, which does not exist on macOS. The `incus` client stores its config in `~/Library/Application Support/incus`, not `~/.config/incus`. Fixed by setting `config_dir` in the provider block and naming `remote = "dell"` on the resource.

**SSH refused on a fresh VM.** The VM was reachable but nothing was listening on port 22, because the minimal cloud image does not include `openssh-server`. Fixed by installing it through cloud-init `packages:` and enabling it with `runcmd`.

**fail2ban crash-looped.** The idempotency check caught this: the second Ansible run still reported a change, and `systemctl is-active fail2ban` said `failed`. The journal showed `Have not found any log file for sshd jail`. The minimal image has no `/var/log/auth.log`, so fail2ban's default SSH jail had nothing to read. Fixed by installing `python3-systemd` and setting the jail's `backend = systemd`.

**VM IPs changed on every rebuild**, which broke the inventory and Prometheus targets. Fixed by assigning fixed IPs through the VM's network device in Terraform.

**Rebuilds took 20 minutes.** Re-running the playbook on an already-configured VM took 39 s, so the extra time on a fresh VM was package downloads, repeated for every rebuild over a slow connection. Fixed with an apt-cacher-ng container on the host and a proxy setting in the hardening role.

## Limitations

- The VMs are small (1 vCPU, 1 GiB RAM) because the host has 8 GB of RAM.
- Terraform state is stored locally and is not committed. It is not suitable for a team without a remote backend.
- Disabling host-key checking is a deliberate lab-only tradeoff.
- The `rebuild` script rebuilds one VM; a full-environment rebuild is `terraform destroy` followed by the usual apply and playbook steps.

## Possible next steps

- Run `terraform plan` on pull requests in CI.
- Move Terraform state to a remote backend (for example MinIO).
- Deploy workloads on k3s running inside these VMs.
