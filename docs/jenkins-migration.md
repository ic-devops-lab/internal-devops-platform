# Jenkins Controller Migration

## Prerequisites

- Old Jenkins server should be added to `jenkins_old` group in [inventory.yaml](../lab-infra/inventory.yml)
- Configuration as Code plugin on both instances

---

## Prepare the migration directory

On the host
```bash
cd lab-infra

mkdir -p .migration
```
> **Note**: this directory should be added to the project's `.gitignore` file.

---

## Migration

### Migration playbook

Check [`playbooks/jenkins-migrate.yml`](../lab-infra/playbooks/jenkins-migrate.yml)

The playbook supports two modes:
- **Default**: collect job configurations and plugin inventory without changing either controller.
- **Restore**: additionally copy missing jobs to `jenkins01` and restart Jenkins there.

> A note about nested folders

> The playbook preserves relative paths such as:
> - `jobs/team-a/config.xml`
> - `jobs/team-a/jobs/build-app/config.xml`

Jenkins folders require the corresponding folder plugin to be installed. They also need valid parent folder definitions, which is why we collect every `config.xml`, not just Pipeline jobs.

This approach is intended for a small, controlled migration. It doesn't perform compatibility conversion of job XML between plugin versions.

---

#### 1. First run: inventory only

```bash
ansible-playbook playbooks/jenkins-migrate.yml
```

This will:
- Read the old controller.
- Copy its job definitions into .migration/jobs/.
- Create .migration/plugins.txt.
- Leave the new controller unchanged.

Check the results:
```bash
find .migration/jobs -name config.xml
cat .migration/plugins.txt
```

---

#### 2. Export configuration from the old instance

On old Jenkins

- Go to 'http://<old-jenkins-url>:8080/manage/configuration-as-code/viewExport'
- click "Retry with POST" button
- save displayed config to a file (`.migration/jenkins-old-export.yaml`)

---

#### 3. Generate a credentials inventory

Check: [`scripts/jenkins-credentials-inventory.py`](../lab-infra/scripts/jenkins-credentials-inventory.py)

Run:
```bash
python3 scripts/jenkins-credentials-inventory.py \
  .migration/jenkins-old-export.yaml \
  .migration/credentials.csv
```

Expected output for the credential you've shown:
```
id,kind,description,scope
k3s-kubeconfig,file,k3s-kubeconfig,GLOBAL
```

This extracts metadata only, not secret values. It covers credentials represented in the exported credentials.system.domainCredentials structure; credentials stored elsewhere may need separate inspection.

Please restore the required secrets manually in the UI of the new Jenkins instance.

---


#### 4. Restore the jobs

Once you've reviewed the collected job configurations:
``` bash
ansible-playbook playbooks/jenkins-migrate.yml \
  -e jenkins_migrate_restore=true
```

The playbook will copy only missing `config.xml` files and restart only `jenkins01`, if something was copied.

The old controller remains untouched.

> **Important**: Before restoring, review the job definitions for embedded credentials and automatic triggers. Keep webhook and scheduled builds disabled on the new controller until we're ready to test them. Copying job XML can carry triggers over, so the safest approach is to temporarily disable those triggers in the staged XML or keep the new controller isolated from external events.

---

#### 5. Automatically extract the settings

Check: [`scripts/jenkins-filter-casc.py`](../lab-infra/scripts/jenkins-filter-casc.py)

It automatically transfers:
- Kubernetes cloud configuration, including pod templates.
- Global Shared Library definitions, including their SCM configuration.
- Global tool settings.

It deliberately excludes credentials, users, authorization, and security settings.

> **One caveat**: Some Shared Library SCM definitions may reference credential IDs. Those credentials must exist on the new controller.

```bash
python3 scripts/jenkins-filter-casc.py \
  .migration/jenkins-old-export.yaml \
  .migration/jenkins-settings.yaml \
  --jenkins-url http://192.168.56.23:8080
```

---

#### 6. Deploy automatically with Ansible

```bash
ansible-playbook playbooks/jenkins-migrate.yml \
  -e jenkins_migrate_settings=true
```

---