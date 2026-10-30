## Host Prerequisites

Additional prerequisites for the host machine:
- `ansible.posix.firewalld` module
> **Note** If `ansible.posix` is not listed already at [`requirements.yml`](../lab-infra/requirements.yml))

```bash
# install
ansible-galaxy collection install ansible.posix

# verify
ansible-doc ansible.posix.firewalld
```

## Configuring new VM for Jenkins

Congiguration file for Jenkins Vagrant VM: [see](../lab-infra/_nodes/jenkins01.yaml)

RockyLinux 9 was chosen as OS (RHEL-family, stable, lightweight, close to production).

This VM will be operate only as a Jenkins Controller, all workloads we plan to send to Jenkins k3s Agents, so assumption is that we won't need that much space we wold need for a single Jenkins server, for now 20GB should be enough.

---

## Ansible

- Inventory update
Check out [Ansible inventory](../lab-infra/inventory.yml).

- [Group variables](../lab-infra/group_vars/jenkins.yml)

- Jenkins role
  - [`defaults/main.yml`](../lab-infra/roles/platform/jenkins/defaults/main.yml)
  - [`tasks/main.yml`](../lab-infra/roles/platform/jenkins/tasks/main.yml)
  - [`tasks/prerequisites.yml`](../lab-infra/roles/platform/jenkins/tasks/prerequisites.yml)
  - [`tasks/repository.yml`](../lab-infra/roles/platform/jenkins/tasks/repository.yml)
  - [`tasks/install.yml`](../lab-infra/roles/platform/jenkins/tasks/install.yml)
  - [`tasks/systemd.yml`](../lab-infra/roles/platform/jenkins/tasks/systemd.yml)
  - [`tasks/validate.yml`](../lab-infra/roles/platform/jenkins/tasks/validate.yml)
  - [`tasks/plugins.yml`](../lab-infra/roles/platform/jenkins/tasks/plugins.yml)
  - [`tasks/firewall.yml`](../lab-infra/roles/platform/jenkins/tasks/firewall.yml)
  - [`handlers/main.yml`](../lab-infra/roles/platform/jenkins/handlers/main.yml)
  - [`templates/override.conf.j2`](../lab-infra/roles/platform/jenkins/templates/override.conf.j2)
  - [`templates/plugins.txt.j2`](../lab-infra/roles/platform/jenkins/templates/plugins.txt.j2)

- [Jenkins playbook](../lab-infra/playbooks/jenkins.yml)

### Why configure both NetworkManager and firewalld?

NetworkManager manages the persistent connection profile for `eth1`.

Setting `connection.zone` ensures the interface is assigned to the correct zone when the connection is activated, including after reboot.

The `firewall-cmd --change-interface` command applies the assignment immediately without disconnecting the interface.

This is important because we don't want to restart the network connection and potentially interrupt the Ansible SSH session.


---

## Jenkins server setup

On the host
```bash
cd lab-infra

# deploy VM(s)
vagrant up jenkins01

# check connectivity of the group and a single server
ansible jenkins -m ping -o
ansible jenkins01 -m ping -o

# provision DNS server
ansible-playbook playbooks/jenkins.yml

```

---