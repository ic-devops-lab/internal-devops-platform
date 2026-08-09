# Helm setup guide

## Configuration

Helm version and repositories are configured in `group_vars/k3s01_servers.yml`.

On the control VM
```bash
# find valid Helm version strings
apt-cache madison helm
```
Use the desired version in vars file.

---

## Setup

Helm is installed on the k3s control-plane node as part of the k3s playbook:

On tht host machine
```bash
cd lab-infra

ansible-playbook playbooks/k3s.yml

# to install or re-install Helm independently (without re-deploying the cluster):
ansible-playbook playbooks/k3s-helm.yml
```

---