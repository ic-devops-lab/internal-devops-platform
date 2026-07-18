# DNS Service Guide

## DNS server(s) setup

On the host:
```bash
cd lab-infra

# deploy VM(s)
vagrant up dns01

# check connectivity of the dns group and a single DNS server
ansible dns -m ping -o
ansible dns01 -m ping -o

# provision DNS server
ansible-playbook playbooks/dns.yml

# Verify from the host (manual checks)
dig +short @192.168.56.2 dns01.lab.internal
dig +short @192.168.56.2 gitlab01.lab.internal
dig +short @192.168.56.2 example.com

# expected in output for internal domain names
dns01.lab.internal.    ...    A    192.168.56.2
# the external query should return one or more public IP addresses.

# verify listening sockets. DNS uses both UDP and TCP port 53.
vagrant ssh dns01 -c \
  "sudo ss -lntup | grep ':53'"

# expected result: dnsmasq listens on:
127.0.0.1:53
192.168.56.2:53
# It should not listen on every interface.
```

---

## DNS Ansible role

The plabook with DNS role:
- installs dnsmasq and dnsutils;
- deploys the Ansible-managed dnsmasq configuration;
- validates the complete dnsmasq configuration;
- restarts dnsmasq if the configuration changed;
- ensures the service starts automatically after reboot;
- verifies an internal DNS record;
- verifies external DNS forwarding.

A successful playbook run means that both internal and external DNS resolution have passed automated checks on the DNS VM.

**Why is dnsmasq --test useful?**

The current role deploys the template and schedules an immediate restart, but it does not validate the generated configuration first.

A typo such as:
```ini
listen-adress=192.168.56.2
```
could cause the restart to fail.

With:
```yaml
cmd: dnsmasq --test
```
Ansible stops before restarting the service.

**Limitation of this implementation**

The template has already replaced /etc/dnsmasq.d/lab.conf when validation runs. If validation fails:
- the running process usually continues with the previous in-memory configuration;
- the invalid file remains on disk;
- a future reboot could still cause a problem.

For this lab, the current validation is a reasonable improvement. A more robust production role would render
to a temporary file, validate a complete candidate configuration, and only then replace the live file.

---

## Current limitation

Other VMs and VPN clients are not yet configured to use this DNS server
automatically.

At this stage, clients must explicitly specify the server:
```bash
dig @192.168.56.2 gitlab01.lab.internal
```

Automatic name resolution will be introduced in the next phase through:
- an Ansible dns_client role;
- OpenVPN DNS configuration;
- split DNS for the lab.internal domain.

---

## Network exposure in case of infrastructure provider

If the host is provided by a service like Hetzner you should be careful configuring networks for your VMs.

The DNS VM has two network paths:

- a VirtualBox NAT interface used for outbound package installation and
  upstream DNS queries;
- a host-only interface using `192.168.56.2` for internal DNS clients.

dnsmasq is configured to listen only on:
```text
127.0.0.1
192.168.56.2
```

It must not listen on the NAT-facing interface or on `0.0.0.0`.

No bridged VirtualBox adapter should be configured on the Hetzner host.
Bridged mode could expose the VM directly to the provider network and may
introduce unauthorized MAC addresses.

DNS requires both:
```text
UDP/53
TCP/53
```

If a host firewall is introduced on the DNS VM, these ports should be allowed
only from approved private networks, such as:
```
192.168.56.0/24
<OpenVPN client subnet>
```

The key point is that DNS uses both UDP and TCP. Many ordinary queries use UDP, but TCP is also part of correct DNS operation.

---
