#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
start=$(date +%s)

terraform -chdir=terraform destroy -target='incus_instance.vm["iac-2"]' -auto-approve
terraform -chdir=terraform apply -auto-approve
t_tf=$(date +%s)

for i in $(seq 1 150); do
  ssh $SSH_OPTS ansible@10.95.18.202 true 2>/dev/null && break
  [ "$i" -eq 150 ] && { echo "SSH never came up after 5 min"; exit 1; }
  sleep 2
done
t_ssh=$(date +%s)

(cd ansible && ANSIBLE_CALLBACKS_ENABLED=profile_tasks ansible-playbook site.yml --limit 10.95.18.202)
end=$(date +%s)

echo "Terraform: $((t_tf-start))s | SSH ready: $((t_ssh-start))s | fully configured: $((end-start))s"
