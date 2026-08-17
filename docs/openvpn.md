# OpenVPN and Firewall setup guide

## Goal

- automate OpenVPN and firewalld installation and configuration on the host;
- extend the existing OpenVPN installation so that a VPN-connected workstation can securely access resources running on the private VirtualBox network:

```text
Home workstation
      │
      │ OpenVPN
      ▼
Hetzner host
10.8.0.1
      │
      │ routing + controlled SNAT
      ▼
192.168.56.0/24
      │
      ├── dns01.lab.internal
      │     192.168.56.2
      │
      ├── gitlab01.lab.internal
      │
      └── k3s01
            ├── k3s01-ctrl01
            ├── k3s01-wrk01
            └── k3s01-wrk02
```

The VPN remains **split tunnel**:
```text
192.168.56.0/24 → VPN
normal Internet traffic → local Internet connection
```
We deliberately do not push a default route through the VPN.

At the end of this stage, a connected workstation should be able to reach private infrastructure such as:
```text
dns01.lab.internal
k3s01-ctrl01.lab.internal

and later:

argocd.lab.internal
grafana.lab.internal
rollouts.lab.internal
demo.lab.internal
```
without exposing these resources to the Internet.

---

## Design principles

The automation is divided into separate responsibilities:

```text
OpenVPN PKI
    ↓
OpenVPN server
    ↓
Host firewall/routing
```

Client lifecycle is handled separately:

```text
OpenVPN infrastructure
        │
        └── ready to issue clients
                  │
                  ▼
          openvpn-clients.yml
```

The rules of the main infrastructure playbook:

* if OpenVPN is not installed, install it;
* if PKI does not exist, initialize it;
* if PKI already exists, preserve it;
* if server credentials are missing, create only the missing server credentials;
* if existing client certificates are present, leave them untouched;
* do not automatically create new VPN clients;
* do not regenerate an existing CA;
* do not revoke clients automatically;
* ensure the server is ready for issuing clients after configuration.

A separate client-management playbook ensures explicitly requested client identities exist.

---

## Firewall policy and design

| Zone              | Selection               | Access               |
| ----------------- | ----------------------- | -------------------- |
| public            | enp4s0                  | HTTP, HTTPS, OpenVPN |
| vpn               | tun0                    | SSH                  |
| lab               | vboxnet0                | Private VM network   |
| admin-fallback    | configured source CIDRs | SSH only             |
| vpn-to-lab policy | VPN → lab               | Forwarding to VMs    |

- Public access is open only for HTTP/HTTPS and OpenVPN
- SSH is accessible only through VPN tunnel and optionally for admins as a fallback method in case OpenVPN access is not working
- private network with local services accessible for remote users through OpenVPN

The initial design intentionally uses Source Network Address Translation (SNAT).

Without SNAT, each VM would require:

```text
10.8.0.0/24 via 192.168.56.1
```

With SNAT, VMs see traffic as coming from:

```text
192.168.56.1
```

which they can already reach directly.

Proper routed client addresses can be introduced later as an advanced networking improvement.

---

## New roles

```text
host_openvpn_pki
    initializes PKI when absent
    preserves existing CA
    creates missing server credentials

host_openvpn
    installs/configures OpenVPN
    enables IP forwarding
    manages server.conf
    manages service lifecycle

host_openvpn_clients
    creates explicitly requested clients
    preserves existing clients
    generates .ovpn profiles

host_firewall
    manages VPN port
    forwarding
    firewalld zones
    VPN → lab SNAT
```

---

## `ansible.cfg` updates

The host role directory added (host):

```ini
[defaults]
inventory = ./inventory.yml
roles_path = ./roles/common:./roles/dns:./roles/host:./roles/k3s:./roles/platform
host_key_checking = False
localhost_warning = False
```

---

## Ansible collection requirements

Created:

```text
lab-infra/requirements.yml
```

```yaml
---
collections:
  - name: ansible.posix
```

Install:

```bash
cd lab-infra
ansible-galaxy collection install -r requirements.yml
```

We will use:

```text
ansible.posix.sysctl
ansible.posix.firewalld
```

---

## Changes in the vars files

Updated:
- Shared platform network variables added to [`lab-infra/group_vars/all.yml`](../lab-infra/group_vars/all.yml)
- OpenVPN-specific variables added to [`lab-infra/group_vars/local.yml`](../lab-infra/group_vars/local.yml)

---

## Sensitive variables available through environment

Updated:
```text
lab-infra/.env
```

```bash
export NONE_ROOT_USER="my-none-root-user"
export OPENVPN_PUBLIC_INTERFACE=enp4s0
export OPENVPN_TUNNEL_INTERFACE=tun0
export LAB_INTERFACE=vboxnet0

export OPENVPN_SUBNET=10.8.0.0/24
export LAB_SUBNET=192.168.56.0/24

export SUPERADMIN_FALLBACK_ENABLED=true
export SUPERADMIN_FALLBACK_CIDRS='["203.0.113.10/32","198.51.100.25/32"]'
```
> Use your own values
> Check [dotenv.example](../lab-infra/dotenv.example) file to see all currently available settings

For VPN-only administration without fallback access:
```bash
export SUPERADMIN_FALLBACK_ENABLED=false
export SUPERADMIN_FALLBACK_CIDRS='[]'
```

Identify interfaces before deployment:

```bash
ip -br addr
```

Example:

```text
enp41s0    UP    <public-IP>
vboxnet0   UP    192.168.56.1/24
tun0       UP    10.8.0.1/24
```
In this example you take `enp41s0` for `openvpn_public_interface`, `tun0` for `openvpn_tunnel_interface` and `vboxnet0` for `lab_interface`

Then set the actual values in the lab-infra/.env and export environment variables.
```bash
cd lab-infra
source .env
```

---

## PKI role

> **PKI**: Public Key Infrastructure

---

### PKI role behavior

The role should independently determine the state of each PKI asset.

The intended convergence logic is:

```text
PKI directory missing
    → initialize Easy-RSA PKI

CA missing
    → create CA

CA exists
    → preserve CA

server key/certificate missing
    → create using existing CA

DH parameters missing
    → generate

tls-crypt key missing
    → generate

existing client certificates
    → leave untouched
```

There is one important broken-state condition:

```text
ca.crt exists
but
private/ca.key is missing
```

Existing clients may continue working, but new certificates cannot safely be issued.

The playbook must **not create another CA automatically** in this situation.

It should fail with an explanation that the original CA key must be restored before issuing new certificates.

---

### PKI role code

Created:
- [`lab-infra/roles/host/host_openvpn_pki/defaults/main.yml`](../lab-infra/roles/host/host_openvpn_pki/defaults/main.yml)
- [`lab-infra/roles/host/host_openvpn_pki/tasks/main.yml`](../lab-infra/roles/host/host_openvpn_pki/tasks/main.yml)

---

## OpenVPN server role

Created:
- [`lab-infra/roles/host/host_openvpn/defaults/main.yml`](../lab-infra/roles/host/host_openvpn/defaults/main.yml)
- [`lab-infra/roles/host/host_openvpn/templates/server.conf.j2`](../lab-infra/roles/host/host_openvpn/templates/server.conf.j2)
- [`lab-infra/roles/host/host_openvpn/tasks/main.yml`](../lab-infra/roles/host/host_openvpn/tasks/main.yml)
- [`lab-infra/roles/host/host_openvpn/handlers/main.yml`](../lab-infra/roles/host/host_openvpn/handlers/main.yml)

---

## Firewall role

### Role structure

```text
roles/host_firewall/
├── defaults/
│   └── main.yml
├── handlers/
│   └── main.yml
├── tasks/
│   └── main.yml
└── templates/
    ├── firewalld-init.sh.j2
    └── firewalld-init.service.j2
```

The firewall service does not have to depend on OpenVPN being fully started. It installs the permanent policy and allows the public OpenVPN port. OpenVPN can then create tun0

---

### Firewall role code

Created:
- [`lab-infra/roles/host/host_firewall/defaults/main.yml`](../lab-infra/roles/host/host_firewall/defaults/main.yml)
- [`lab-infra/roles/host/host_firewall/tasks/main.yml`](../lab-infra/roles/host/host_firewall/tasks/main.yml)
- [`lab-infra/roles/host/host_firewall/handlers/main.yml`](../lab-infra/roles/host/host_firewall/handlers/main.yml)
- [`lab-infra/roles/host/host_firewall/templates/firewalld-init.sh.j2`](../lab-infra/roles/host/host_firewall/templates/firewalld-init.sh.j2)
- [`lab-infra/roles/host/host_firewall/templates/firewalld-init.service.j2`](../lab-infra/roles/host/host_firewall/templates/firewalld-init.service.j2)

---

## Infrastructure playbook

Creaded:
- [`lab-infra/playbooks/host-openvpn.yml`]
---

After this playbook finishes expected:

```text
OpenVPN installed
PKI ready
server identity ready
existing clients preserved
routing configured
firewall configured
server running
ready to add new clients
```

No new client is created.

---

## Installation and verification

on the host from the project's root
```bash
cd lab-infra

source .env
ansible-playbook playbooks/host-openvpn.yml
```

Verify
``` bash
sudo firewall-cmd --get-active-zones
sudo firewall-cmd --zone=public --list-all
sudo firewall-cmd --zone=vpn --list-all
sudo firewall-cmd --zone=lab --list-all
sudo firewall-cmd --zone=admin-fallback --list-all
sudo firewall-cmd --policy=vpn-to-lab --list-all
```

Expected result:
- public SSH is closed;
- VPN SSH works;
- fallback SSH works only from configured source IPs;
- xRDP is unavailable;
- VPN clients can route toward 192.168.56.0/24;
- unrelated public clients cannot access the lab network.

---