# K3S setup guide

## Architectural changes

- K3S control-plane and workers on private network:
  - Host kubectl accesses cluster via fetched kubeconfig artifact;
- Pinned k3s version:
  - `kubectl_version` in [`lab-infra/group_vars/all.yml`](../lab-infra/group_vars/all.yml);
  - `k3s_version` in [`lab-infra/group_vars/k3s01.ym`](../lab-infra/group_vars/k3s01.yml);
  - flannel interface used by installer (`k3s_flannel_iface` in [`lab-infra/group_vars/k3s01.ym`](../lab-infra/group_vars/k3s01.yml));

**control-plane token flow to agents**
During cluster bootstrap, worker nodes join the control-plane using the shared K3S node token generated on the server node.

1.Control-plane starts first:
The control-plane node is installed by the server role and exposes the Kubernetes API on port 6443.
2. Control-plane token is collected:
After server install, Ansible reads the token from the server token file and stores it as an Ansible fact (k3s_token). The token is hidden from logs for safety.
3. Agents wait for API readiness:
Before agent installation, each worker waits until the control-plane API endpoint is reachable.
4. Agents join with server URL + token:
Each worker installs K3S agent using:

- K3S_URL pointing to the control-plane API endpoint
- K3S_TOKEN pulled from control-plane host facts

*Result*:
Workers register to the cluster and appear as Ready nodes once kubelet and networking are up.

>Notes:
> This flow currently assumes a single control-plane host name for token lookup.
> If the control-plane is rebuilt, re-running the K3S playbook ensures workers rejoin using the current token.

**Node addresses and roles added**
| Host         | IP address     | Service role             |
| ------------ | -------------- | ------------------------ |
| k3s01-ctrl01 | 192.168.56.11  | K3S server/control-plane |
| k3s01-wrk01  | 192.168.56.12  | K3S worker               |
| k3s01-wrk02  | 192.168.56.13  | K3S worker               |

---

## IaC Changes

- Updates and refactoring in the playbook deploying prerequisites to the host; see [`playbooks/host-prerequisites.yml`](../lab-infra/playbooks/host-prerequisites.yml).

- 3 new VMs added to [`lab-infra/Vagrantfile`](../lab-infra/Vagrantfile) for cluster nodes: 1 server and 2 agents.

- Cluster VMs added to Ansible inventory; see [`lab-infra/inventory.yml`](../lab-infra/inventory.yml).

- DNS configuration updated; see [`lab-infra/group_vars/dns.yml`](../lab-infra/group_vars/dns.yml)

- File with variables for k3s cluster created; see [`lab-infra/group_vars/k3s01.yml`](../lab-infra/group_vars/k3s01.yml)

- A role for preparing all VMs added: see [`roles/common/common/tasks/main.yml`](../lab-infra/roles/common/common/tasks/main.yml)

  **Role responsibilities:**
  - update the APT cache;
  - install basic packages
  - configure DNS resolver

- A role for preparing cluster nodes created; see [`roles/k3s/k3s_common/tasks/main.yml`](../lab-infra/roles/k3s/k3s_common/tasks/main.yml)

  **Role responsibilities:**
  - update the APT cache;
  - install basic packages specific for k3s nodes;
  - disable swap;
  - [not implemented yet] load required kernel modules;
  - [not implemented yet] configure sysctl settings;
  - configure DNS;
  - [not implemented yet] ensure time synchronization;
  - [not implemented yet] configure hostnames if necessary.

- A role for configuring a controle-plane node added: see [`roles/k3s/k3s_server/tasks/main.yml`](../lab-infra/roles/k3s/k3s_server/tasks/main.yml)

  **Role responsibilities:**
  - download the official k3s installer;
  - install the pinned k3s version;
  - bind the Kubernetes API to the private address;
  - configure node name and node IP;
  - wait for the API server;
  - retrieve the node token;
  - retrieve kubeconfig;
  - validate the server node.

- A role for configuring a worker node added; see [`roles/k3s/k3s_agent/tasks/main.yml`](../lab-infra/roles/k3s/k3s_agent/tasks/main.yml)

  **Role responsibilities:**
  - ensure the k3s server is reachable;
  - retrieve the cluster token from Ansible facts;
  - install the pinned k3s agent version;
  - configure node name and node IP;
  - wait until the node joins;
  - verify the agent service.

- A playbook for deploying k3s cluster added; see [`playbooks/k3s.yml`](../lab-infra/playbooks/k3s.yml)

- A playbook uninstalling cluster agents and servers and cleaning up leftover data; see [`playbooks/k3s-reset.yml`](../lab-infra/playbooks/k3s-reset.yml)

- A role for installing Helm on the control-plane node added; see [`roles/k3s/k3s_helm/tasks/main.yml`](../lab-infra/roles/k3s/k3s_helm/tasks/main.yml)

  **Role responsibilities:**
  - verify GPG key fingerprint of the Helm APT package (key pinned);
  - install Helm from the official Buildkite APT repository;
  - add configured Helm repositories (set in [`group_vars/k3s01_servers.yml`](../lab-infra/group_vars/k3s01_servers.yml)).

  > Helm version and repositories are configured in [`lab-infra/group_vars/k3s01_servers.yml`](../lab-infra/group_vars/k3s01_servers.yml).

- A standalone playbook for (re-)installing Helm without rebuilding the whole cluster; see [`playbooks/k3s-helm.yml`](../lab-infra/playbooks/k3s-helm.yml)

---

## Infrastructure setup/update

On the host
```bash
cd lab-infra

# update host's prerequisites (new were added)
ansible-playbook playbooks/host-prerequisites.yml

# deploy VMs
vagrant up k3s01-ctrl01 k3s01-wrk01 k3s01-wrk02

# check connectivity
ansible k3s01 -m ping -o

ansible k3s01_servers -m ping -o
ansible k3s01_agents -m ping -o

ansible k3s01-ctrl01 -m ping -o
ansible k3s01-wrk01 -m ping -o
ansible k3s01-wrk02 -m ping -o

# run DNS playbook to update DNS records
ansible-playbook playbooks/dns.yml

# validate
dig +short @192.168.56.2 k3s01-ctrl01
dig +short @192.168.56.2 k3s01-wrk01
dig +short @192.168.56.2 k3s01-wrk02

dig +short @192.168.56.2 k3s01-ctrl01.lab.internal
dig +short @192.168.56.2 k3s01-wrk01.lab.internal
dig +short @192.168.56.2 k3s01-wrk02.lab.internal

# deploy k3s
ansible-playbook playbooks/k3s.yml

# verify the cluster is up and has control-plane and worker nodes
vagrant ssh k3s01-ctrl01 -c "kubectl get nodes -o wide"

# add or update KUBECONFIG on the host
grep -q '^KUBECONFIG=' .env 2>/dev/null \
  && sed -i 's|^KUBECONFIG=.*|KUBECONFIG="$PWD/artifacts/kubeconfig"|' .env \
  || echo 'KUBECONFIG="$PWD/artifacts/kubeconfig"' >> .env
# kubectl runs in a child process, so just `source .env` is not enough
# we need to export environment variables using auto-export option
set -a ; source .env; set +a
# verify connection to k3s from the host
kubectl get nodes -o wide
```

---

## Uninstalling cluster nodes / Removing cluster node VMs

On the host
```bash
cd lab-infra

# Soft rebuild:
ansible-playbook playbooks/k3s-reset.yml
ansible-playbook playbooks/k3s.yml

# Full rebuild:
vagrant destroy -f k3s01-ctrl01 k3s01-wrk01 k3s01-wrk02
vagrant up k3s01-ctrl01 k3s01-wrk01 k3s01-wrk02
ansible-playbook playbooks/k3s.yml
```

---

## Possible improvements

### k3s-common role

#### Configure kernel modules

1. Create `roles/k3s-common/templates/k3s-modules.conf.j2` with the content:
```
overlay
br_netfilter
```

2. Deploy to: `/etc/modules-load.d/k3s.conf`

3. Then load them:
```
modprobe overlay
modprobe br_netfilter
```

---

#### Configure sysctl

1. Create `roles/k3s-common/templates/k3s-sysctl.conf.j2` with the content:
```
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
```

2. Deploy to `/etc/sysctl.d/99-k3s.conf`

3. Apply:
```
sysctl --system
```

---