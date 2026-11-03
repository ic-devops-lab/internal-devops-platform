# DevOps Lab: HashiCorp Vault with k3s (Manual Setup)

## Objectives

By the end, you should understand how to:

1. Deploy Vault using Helm.
2. Store and retrieve secrets using the KV v2 secrets engine.
3. Create policies implementing least-privilege access.
4. Authenticate Kubernetes workloads using ServiceAccount tokens.
5. Authenticate applications running outside Kubernetes using AppRole.
6. Explain how Vault tokens, policies, and secret leases work.

We'll use Vault development mode, with dummy secrets only. This avoids initialization, unsealing, and storage configuration during our first exercise.

Development mode is not suitable for production: it uses an in-memory store, starts unsealed, and has a predefined root token. We'll cover production differences after the hands-on exercises.

---

## Step 1 — Deploy Vault into k3s

For now, let's complete only the installation and connectivity checks.

### 1.1 Add the Helm repository

On the k3s cluster control plane VM (for ex. 'k3s01-ctrl01'):
```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Check the chart
helm search repo hashicorp/vault
```

---

### 1.2 Install Vault

We'll use a dedicated namespace:
```bash
kubectl create namespace vault
```

Install the chart:
```bash
helm install vault hashicorp/vault \
  --namespace vault \
  --set "server.dev.enabled=true" \
  --set "server.dev.devRootToken=dev-root-token" \
  --set "injector.enabled=false"
```

We're disabling the Vault Agent Injector initially because we'll first learn how authentication and secret retrieval work directly. We can introduce automatic secret injection later.

The root token is intentionally fixed for this disposable lab. Never use this pattern in a real environment.

---

### 1.3 Verify the deployment

```bash
helm -n vault list
helm -n vault get manifest vault

kubectl get pods -n vault
kubectl get svc -n vault
```

Expected resources include a Vault server pod and a ClusterIP service.

Check Vault's status:
```bash
kubectl exec -n vault vault-0 -- vault status

# Expected key fields:
Initialized    true
Sealed         false
Storage Type   inmem
```

The exact output may vary slightly with the Vault version.

---

### 1.4 Test access to Vault

```bash
# Open a terminal in the Vault container:
kubectl exec -n vault -it vault-0 -- sh

# Inside the container:
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=dev-root-token

vault status
vault secrets list

# You should see the default secrets engines, including secret/.

# Exit the container:
exit
```

At this point, we have a functioning Vault server inside Kubernetes.

---

## Step 2: KV v2 secrets, policies, and access control

### 2.1 Create a secret using KV v2

We'll execute commands directly inside the Vault pod for now.

```bash
kubectl exec -n vault -it vault-0 -- sh

## Set the connection details:
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=dev-root-token

# First, inspect the available secrets engines:
vault secrets list -detailed
vault secrets list

# In development mode, Vault normally enables a KV v2 engine at secret/.
# You should see something similar to:
Path       Type       Options
----       ----       -------
secret/    kv         map[version:2]
```

If `secret/` already exists with `version:2`, we don't need to enable anything.

Now store a test secret:
```bash
vault kv put secret/demo \
  username=demo-user \
  password=demo-passwd123

# Retrieve it:
vault kv get secret/demo

# Expected output:
====== Data ======
Key         Value
---         -----
password    demo-passwd123
username    demo-user
```

You should also see metadata such as the secret version and creation timestamp.

---

### Why KV v2?

`KV v2` supports secret versioning.

Try updating the password:
```bash
vault kv put secret/demo \
  username=demo-user \
  password=updated-passwd123

# Then inspect the versions:
vault kv metadata get secret/demo

# Retrieve version 1:
vault kv get -version=1 secret/demo

# And version 2:
vault kv get -version=2 secret/demo
```

**Takeaway**: `KV v2` stores multiple versions of a secret. It supports soft deletion, recovery of deleted versions, and permanent destruction of specified versions.

---

### 2.2 Create a read-only policy

Vault uses policies to determine which operations a token can perform.

Let's create a policy allowing an application to read only our demo secret.

Inside the Vault pod:
```bash
cat > /tmp/demo-read.hcl <<'EOF'
path "secret/data/demo" {
  capabilities = ["read"]
}
EOF

# Apply the policy:
vault policy write demo-read /tmp/demo-read.hcl

# Verify it:
vault policy read demo-read

# Expected:
path "secret/data/demo" {
  capabilities = ["read"]
}
```

> **Important**: `KV v2` API paths

Notice the difference:

| Vault CLI command | Internal API path |
|---|---|
| `vault kv get secret/demo` | `secret/data/demo` |
| `vault kv metadata get secret/demo` | `secret/metadata/demo` |


`KV v2` uses separate API paths for secret data and metadata.

This distinction is particularly important when writing Vault policies.

Our policy grants access to `secret/data/demo` but not to the entire `secret/ mount`.

---

### 2.3 Create a restricted token

So far, we've been using the development root token, which has unrestricted access.

Now we'll create a token with our new policy:
```bash
vault token create \
  -policy=demo-read \
  -no-default-policy \
  -ttl=30m

# Vault will print something like:
Key                  Value
---                  -----
token                hvs.CAESI...
token_duration       30m
token_policies       [demo-read]

# Switch to the restricted token:
export VAULT_TOKEN='<restricted-token>'
```

---

### Tests

```bash
# Test 1 — Reading the secret should succeed
vault kv get secret/demo
# Expected: the secret is returned

# Test 2 — Modifying the secret should fail
vault kv put secret/demo \
  username=hacker \
  password=changed
# Expected:
Error writing data to secret/data/demo:
Code: 403
permission denied

# Test 3 — Accessing a different secret should fail
vault kv get secret/another-secret
# Expected: 403 permission denied, because the policy doesn't authorize that path.

# Test 4 — Inspect the strict token
vault token lookup
# Expected: 403 permission denied, because we used `-no-default-policy

# # Test 5 — Inspect the normal token
export VAULT_TOKEN=dev-root-token
vault token create \
  -policy=demo-read \
  -ttl=30m
export VAULT_TOKEN='<new-restricted-token>'

vault token lookup
# Look for:
policies          [demo-read]
ttl               ...
```

This demonstrates the principle of least privilege: an application receives only the permissions it actually needs.

---

### 2.4 A useful extra test: inspect permissions directly

Vault can show the capabilities associated with the current token:
```bash
vault token capabilities secret/data/demo

# Expected:
read

# For another secret:
vault token capabilities secret/data/another-secret
# Expected:
deny
```

This is useful when troubleshooting Vault authorization issues.

## What we've learned

The essential relationship is:
```txt
Secret
  secret/data/demo
        ▲
        │ read permission
        │
Policy: demo-read
        ▲
        │ assigned to
        │
Vault Token
        ▲
        │ used by
        │
Application
```

A token doesn't automatically grant access to every secret. Its effective policies determine what it can do. HashiCorp Developer

In the next exercise, we'll replace manually issued tokens with Kubernetes authentication, allowing a pod to authenticate using its ServiceAccount identity.

For further reading, the official documentation covers [KV v2 versioning](https://developer.hashicorp.com/vault/docs/secrets/kv/kv-v2?utm_source=chatgpt.com) and [Vault policy configuration](https://developer.hashicorp.com/vault/docs/secrets/kv/kv-v2/setup?utm_source=chatgpt.com).

---

## Step 3 — Kubernetes authentication using ServiceAccounts.

### 3.1 What we're going to build

Our test application will run in a Kubernetes pod and retrieve the secret we created earlier:

```bash
Kubernetes Pod
     |
     | ServiceAccount JWT
     v
HashiCorp Vault
     |
     | Validate identity through Kubernetes API
     v
Vault Kubernetes Auth
     |
     | Apply demo-read policy
     v
Short-lived Vault token
     |
     | Read secret/data/demo
     v
username = demo-user
password = updated-password
```

The pod won't need a manually configured Vault token.

We'll use the existing Vault development deployment and create a dedicated Kubernetes ServiceAccount.

---

### 3.2 Create a namespace and ServiceAccount

Run these commands from a machine with kubectl access:
```bash
kubectl create namespace vault-demo

kubectl create serviceaccount vault-demo-sa \
  -n vault-demo

# Verify:
kubectl get serviceaccounts -n vault-demo

# Expected:
NAME            SECRETS   AGE
default         0         ...
vault-demo-sa   0         ...
```

It's normal for modern Kubernetes ServiceAccounts to show zero associated Secrets. Kubernetes uses projected, short-lived ServiceAccount tokens.

---

### 3.3 Configure Vault Kubernetes authentication

First, enter the Vault pod:
```bash
kubectl exec -n vault -it vault-0 -- sh

#Set the root token:
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=dev-root-token

#Enable Kubernetes authentication:
vault auth enable kubernetes
```

Vault needs to know how to contact the Kubernetes API server.

Since Vault itself runs inside Kubernetes, we can use the in-cluster API address.

```bash
# Configure the authentication backend:
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
```

Vault will use its pod's ServiceAccount identity to validate application tokens through Kubernetes's TokenReview API.

**Important: TokenReview permissions**

The Vault server's ServiceAccount must have permission to create TokenReview requests.

Check its ServiceAccount:
```bash
# Exit the Vault pod:
exit

kubectl get pod vault-0 -n vault \
  -o jsonpath='{.spec.serviceAccountName}'

# If it is vault, we can grant it the required permissions.

# Create a ClusterRoleBinding:
kubectl create clusterrolebinding vault-tokenreview \
  --clusterrole=system:auth-delegator \
  --serviceaccount=vault:vault
```

This grants Vault permission to validate ServiceAccount tokens.

For a lab, this is sufficient. In production, we'd manage the binding declaratively through Helm or Terraform.

---

### 3.4 Create a Vault role for the Kubernetes application

```bash
# Enter the Vault pod again:
kubectl exec -n vault -it vault-0 -- sh

# Set the environment:
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=dev-root-token

# Create a Kubernetes authentication role:
vault write auth/kubernetes/role/vault-demo \
  bound_service_account_names=vault-demo-sa \
  bound_service_account_namespaces=vault-demo \
  policies=demo-read \
  ttl=1h
```

This role defines the relationship between Kubernetes identity and Vault authorization.

| Parameter | Meaning |
|---|---|
| `bound_service_account_names` | Only `vault-demo-sa` can use this role |
| `bound_service_account_namespaces` | ServiceAccount must belong to `vault-demo` |
| `policies` | Vault token receives `demo-read` |
| `ttl` | Vault token expires after one hour |

Notice that Kubernetes RBAC and Vault policies are separate systems.

Kubernetes verifies the workload's identity. Vault determines which secrets that identity may access.

Exit the Vault pod.

---

### 3.5 Deploy a test pod

We'll use the official Vault image because it already includes the Vault CLI.

Create vault-demo-pod.yaml:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: vault-demo
  namespace: vault-demo
spec:
  serviceAccountName: vault-demo-sa
  containers:
    - name: vault
      image: hashicorp/vault:1.21
      command:
        - sh
        - -c
        - sleep 3600
```

Deploy:
```bash
kubectl apply -f vault-demo-pod.yaml

# Wait for the pod:
kubectl wait --for=condition=Ready \
  pod/vault-demo \
  -n vault-demo \
  --timeout=120s
```

---

### 3.6 Authenticate from the pod

```bash
kubectl exec -n vault-demo -it vault-demo -- sh

# Set the Vault address:
export VAULT_ADDR=http://vault.vault.svc.cluster.local:8200

The pod has a projected Kubernetes ServiceAccount token at:
/var/run/secrets/kubernetes.io/serviceaccount/token

# Use it to authenticate:
vault write auth/kubernetes/login \
  role=vault-demo \
  jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"

# Expected output includes:
token_policies    ["default" "demo-read"]
token_duration    1h
```

Vault returns a Vault token, which is different from the Kubernetes ServiceAccount JWT.

For the next step, we can avoid manually copying the token by using the API and jq, if available.

Alternatively, copy the Vault token from the login output into an environment variable inside the test pod:
```bash
export VAULT_TOKEN='<vault-token>'

# Then retrieve the secret:
vault kv get secret/demo

# Expected: the stored username and password are returned.

# Test that writing is prohibited:
vault kv put secret/demo password=unauthorized

# Expected:
Code: 403
permission denied
```

> **Security note**: This lab uses HTTP because Vault is running in development mode. The ServiceAccount JWT and Vault token are transmitted without transport encryption. Keep this test within your isolated lab network; production deployments must use TLS.

---

### Troubleshooting commands

```bash
# If authentication fails, start with:
kubectl logs -n vault vault-0

# Check the authentication backend:
vault read auth/kubernetes/config

# Check the role:
vault read auth/kubernetes/role/vault-demo

# For TokenReview permissions:
kubectl auth can-i create tokenreviews.authentication.k8s.io \
  --as=system:serviceaccount:vault:vault

# Expected:
yes
```

---

## Step 4 — AppRole authentication from a separate Linux VM.

This will demonstrate that Vault can serve applications outside the Kubernetes cluster.

### 4.1 Configure AppRole in Vault

Enter the Vault pod:
```bash
kubectl exec -n vault -it vault-0 -- sh

# Set the root token:
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=dev-root-token

# Enable AppRole authentication:
vault auth enable approle

# Create a role for our external application:
vault write auth/approle/role/demo-vm \
  token_policies=demo-read \
  token_ttl=30m \
  token_max_ttl=1h \
  secret_id_ttl=1h \
  secret_id_num_uses=5
```

This role allows an application to authenticate using a role_id and secret_id, receiving a Vault token with the demo-read policy.

```bash
# Retrieve the Role ID:
vault read -field=role_id auth/approle/role/demo-vm/role-id

# Generate a Secret ID:
vault write -f -field=secret_id auth/approle/role/demo-vm/secret-id
```

Save both values securely for the next exercise. Don't commit them to Git.

Exit the Vault pod.

---

### 4.2 Make Vault accessible from the VM

### 4.2.a via port forwarding

For our lab, we can expose Vault temporarily through a port-forward.

On your machine with kubectl access:
```bash
kubectl port-forward -n vault svc/vault 8200:8200
```

This listens on `127.0.0.1:8200` on the machine running kubectl.

If you run the VM application on that same machine, it can access Vault directly.

For a separate VM, we need a network path to that listener. Rather than expose Vault's development-mode HTTP service across the lab network, we may use an SSH tunnel.

For example, if the port-forward runs on your lab host, from the VM:
```bash
ssh -N -L 8200:127.0.0.1:8200 <user>@<lab-host>
```

This makes Vault available at `127.0.0.1:8200` on the VM through an encrypted SSH connection.

---

### 4.2.b via DNS record

As far as we have internal DNS service, we could use it to configure accessibility to Hashicorp Vault service deployed on k3s cluster.

1. Create Ingress service for Hashicorp Vault

On the machine with access to the k3s:
```bash
cat > vault-demo-ingress.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vault-ingress
  namespace: vault
spec:
  ingressClassName: traefik
  rules:
    - host: vault.lab.internal
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: vault
                port:
                  number: 8200
EOF

kubrctl apply -f vault-demo-ingress.yaml
kubectl -n vault get ingress
# expected smth like this
NAME            CLASS     HOSTS                ADDRESS                                     PORTS   AGE
vault-ingress   traefik   vault.lab.internal   192.168.56.11,192.168.56.12,192.168.56.13   80      44h

rm -f vault-demo-ingress.yaml
```

2. Add temporary DNS record for vault

We don't have a Load Balancer for accessing apps on our k3s cluster. So we'll configure this record to look stright to a control plane VM.

on DNS VM:
```bash
# add a record
echo "address=/vault.lab.internal/192.168.56.11" \
  | sudo tee -a /etc/dnsmasq.d/lab.conf

# restart dns service
sudo systemctl restart dnsmasq

# verify loaclly
dig @127.0.0.1 vault.lab.internal
# expected 192.168.56.11 in the output
```

3. Configure remote VM

If during provisioning of this VM DNS was already configured, it should have access to our valt already.
On the VM
```bash
# verify DNS config
dig @192.168.56.2 vault.lab.internal

# if there's no 192.168.56.11 in the output, just add a record to the hosts file for now
echo "192.168.56.11 vault.lab.internal" \
  | sudo tee -a /etc/hosts

# that should do the trick. verify
ping -c 3 vault.lab.internal
```

>> **Security warning**: This configuration exposes a development-mode Vault instance over HTTP on the internal lab network. Authentication credentials and Vault tokens can be intercepted by anyone able to observe that traffic. Use only dummy credentials in an isolated environment. Production deployments must use TLS and appropriate network access controls.

---

### 4.3 Authenticate from the VM

On the VM:
```bash
# set:
export VAULT_ADDR=http://127.0.0.1:8200
# or vault.lab.internal depending on which method you have chosen in the 4.2

# You don't need the Vault CLI for this exercise; curl is enough.

# Set the credentials:
read -r -p "Role ID: " ROLE_ID
read -r -s -p "Secret ID: " SECRET_ID
echo

Authenticate:
curl -sS \
  --request POST \
  --data "$(jq -n \
    --arg role_id "$ROLE_ID" \
    --arg secret_id "$SECRET_ID" \
    '{role_id: $role_id, secret_id: $secret_id}')" \
  "$VAULT_ADDR/v1/auth/approle/login" \
  | jq '{auth: {policies: .auth.policies, lease_duration: .auth.lease_duration}}'

# This displays the policies and token lifetime without printing the token.

# To capture the token for subsequent requests:
VAULT_TOKEN=$(
  curl -fsS \
    --request POST \
    --data "$(jq -n \
      --arg role_id "$ROLE_ID" \
      --arg secret_id "$SECRET_ID" \
      '{role_id: $role_id, secret_id: $secret_id}')" \
    "$VAULT_ADDR/v1/auth/approle/login" \
    | jq -r '.auth.client_token'
)

export VAULT_TOKEN
```

Each login consumes one allowed Secret ID use, so our two login requests use two of the five permitted uses.

---

### 4.4 Retrieve the secret

```bash
curl -fsS \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/secret/data/demo" \
  | jq '.data.data'

# Expected:
{
  "username": "demo-user",
  "password": "updated-password"
}

# Test that the token cannot modify the secret:
curl -sS -w '\nHTTP %{http_code}\n' \
  -X POST \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"data":{"password":"unauthorized"}}' \
  "$VAULT_ADDR/v1/secret/data/demo"

# Expected: HTTP 403 — permission denied.
```

---

### 4.5 Clean up

After testing:
```bash
unset VAULT_TOKEN ROLE_ID SECRET_ID
```
Stop the temporary SSH tunnel and port-forward.

For production, we would replace this arrangement with a TLS-enabled Vault endpoint and a secure method of delivering AppRole credentials.

**What this exercise demonstrates**

You have now worked with two authentication approaches:
| | Kubernetes Auth | AppRole |
|---|---|---|
| Client | Kubernetes pod | Application on VM |
| Initial identity | ServiceAccount JWT | Role ID + Secret ID |
| Vault authorization | Policy | Policy |
| Result | Short-lived Vault token | Short-lived Vault token |
| Main advantage | Native workload identity | Works outside Kubernetes |


> **The key takeaway**: Vault is infrastructure-independent. It can manage secrets for Kubernetes workloads, VMs, CI/CD systems, and other applications, provided they can authenticate and reach the Vault API.

---

## Production Considerations

| Lab implementation | Production consideration |
|---|---|
| Vault development mode | Persistent storage, initialization, and unsealing |
| Fixed root token | Controlled administrative access |
| HTTP | TLS |
| Manually configured policies | Declarative policy management |
| AppRole Secret ID entered manually | Secure bootstrap and credential rotation |
| Single Vault instance | High availability and recovery planning |
| No audit configuration | Enable Vault audit logging |

---
