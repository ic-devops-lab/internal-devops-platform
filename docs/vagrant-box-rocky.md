# Download and register a native RockyLinux Vagrant box

```bash
sudo mkdir -p /home/shared/vagrant-boxes && cd $_
sudo chmod 1777 /home/shared/vagrant-boxes

# download
curl -fL \
  -o rocky9-9.8-virtualbox.box \
  "https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-Vagrant-Vbox-9.8-20260525.0.x86_64.vagrant.virtualbox.box"
#  -f, --fail                  Fail fast with no output on HTTP errors
#  -L, --location              Follow redirection if present

# register
vagrant box add \
  --name rocky9-official \
  --provider virtualbox \
  ./rocky9-9.8-virtualbox.box

# verify
vagrant box list

# save disk space afterward
rm ~/vagrant-boxes/rocky9-9.8-virtualbox.box
```

Use in Vagranfile:
```ruby
config.vm.box = "rocky9-official"
```

Verify the OS on VM:
```bash
cat /etc/os-release
df -h /
free -h
getenforce
```

---