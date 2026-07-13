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

# Verify from the host
dig @192.168.56.2 dns01.lab.internal
dig @192.168.56.2 gitlab01.lab.internal

# expected in output
dns01.lab.internal.    ...    A    192.168.56.2
```

---