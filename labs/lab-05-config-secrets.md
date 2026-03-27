# Lab 5: Configuration, Secrets, and Vault
### Externalizing Configuration, Managing Sensitive Data, and External Secrets
**Intermediate Kubernetes — Module 5 of 13**

---

## Lab Overview

### What You Will Do

- Create ConfigMaps from literals and files
- Consume ConfigMaps and Secrets as env vars and volume mounts
- Create Secrets (Opaque, TLS) and use immutable resources
- Combine resources with projected volumes
- Observe ConfigMap update propagation
- Store secrets in HashiCorp Vault and sync them via External Secrets Operator

### Prerequisites

- Completion of Labs 1–4 with `kubectl` access
- Familiarity with pods, deployments, and services

> ⚠️ **Note:** Secrets in Kubernetes are base64-encoded, not encrypted at rest by default. In production, use envelope encryption or an external secrets manager.

### Duration

Approximately 45–60 minutes

---

## Environment Setup

Set your student identifier (use your first name or assigned number):

```bash
# Set your unique student name
export STUDENT_NAME=<your-name>
echo "Student: $STUDENT_NAME"
```

> ⚠️ **Important:** This shared cluster is used by all 22 students. Your `$STUDENT_NAME` ensures your resources don't conflict with others.

---

## Step 1: Create ConfigMaps from Literals

Create a namespace and a ConfigMap using literal key-value pairs:

```bash
# Create the lab namespace
kubectl create namespace lab05-$STUDENT_NAME

# Create a ConfigMap from literal values
kubectl create configmap app-config \
    --from-literal=APP_ENV=production \
    --from-literal=APP_LOG_LEVEL=info \
    --from-literal=APP_MAX_CONNECTIONS=100 \
    --from-literal=APP_CACHE_TTL=3600 \
    -n lab05-$STUDENT_NAME
```

```bash
# Inspect the ConfigMap
kubectl get configmap app-config -n lab05-$STUDENT_NAME -o yaml
```

> ✅ **Expected Output:** The ConfigMap shows a `data` section with four key-value pairs. Each literal becomes a separate key in the map.

Use `describe` for a human-readable view:

```bash
kubectl describe configmap app-config -n lab05-$STUDENT_NAME
```

> ✅ **Expected Output:**
>
> ```
> Name:         app-config
> Namespace:    lab05-$STUDENT_NAME
> Data
> ====
> APP_CACHE_TTL:
> ----
> 3600
> APP_ENV:
> ----
> production
> APP_LOG_LEVEL:
> ----
> info
> APP_MAX_CONNECTIONS:
> ----
> 100
> ```

> 📝 **Note:** All values are stored as strings, even numeric values like `3600`. The data keys are sorted alphabetically in the describe output.

---

## Step 2: Create ConfigMaps from Files

Create local configuration files, then load them into a ConfigMap:

```bash
# Create an nginx configuration file
cat <<'EOF' > nginx.conf
server {
    listen 80;
    server_name localhost;
    location / { root /usr/share/nginx/html; index index.html; }
    location /health { access_log off; return 200 "OK\n"; }
    location /api {
        proxy_pass http://backend-svc:8080;
        proxy_set_header Host $host;
    }
}
EOF
```

```bash
# Create an application properties file
cat <<'EOF' > app.properties
db.host=postgres-svc.lab05-$STUDENT_NAME.svc.cluster.local
db.port=5432
db.name=appdb
cache.ttl=3600
cache.max_size=256
EOF
```

Create a ConfigMap from the files:

```bash
# Create ConfigMap from files
kubectl create configmap app-files \
    --from-file=nginx.conf \
    --from-file=app.properties \
    -n lab05-$STUDENT_NAME

# Verify the ConfigMap
kubectl get configmap app-files -n lab05-$STUDENT_NAME -o yaml
```

> ✅ **Expected Output:** The ConfigMap `data` section contains two keys (`nginx.conf` and `app.properties`), each with the full file content as the value.

> 💡 **Tip:** Use `--from-file=custom-key=filename` to override the default key name. For example: `--from-file=my-nginx=nginx.conf`

---

## Step 3: Consume ConfigMap as Environment Variables

### Using envFrom

Inject all ConfigMap keys as environment variables:

```yaml
# Save as pod-envfrom.yaml
apiVersion: v1
kind: Pod
metadata: { name: env-from-demo, namespace: lab05-$STUDENT_NAME }
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "env | sort && sleep 3600"]
      envFrom:
        - configMapRef: { name: app-config }
  restartPolicy: Never
```

```bash
kubectl apply -f pod-envfrom.yaml
kubectl logs env-from-demo -n lab05-$STUDENT_NAME | grep APP_
```

> ✅ **Expected Output:**
>
> ```
> APP_CACHE_TTL=3600
> APP_ENV=production
> APP_LOG_LEVEL=info
> APP_MAX_CONNECTIONS=100
> ```

> 📝 **Note:** `envFrom` injects all keys from the ConfigMap as environment variables. Keys with invalid environment variable characters (like dots or hyphens) will be skipped with a warning event on the pod.

### Using valueFrom for Selective Injection

Inject specific keys with optional renaming:

```yaml
# Save as pod-valuefrom.yaml
apiVersion: v1
kind: Pod
metadata:
  name: value-from-demo
  namespace: lab05-$STUDENT_NAME
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "echo Env=$ENVIRONMENT Log=$LOG_LEVEL && sleep 3600"]
      env:
        - name: ENVIRONMENT
          valueFrom:
            configMapKeyRef:
              name: app-config
              key: APP_ENV
        - name: LOG_LEVEL
          valueFrom:
            configMapKeyRef:
              name: app-config
              key: APP_LOG_LEVEL
  restartPolicy: Never
```

```bash
kubectl apply -f pod-valuefrom.yaml
kubectl logs value-from-demo -n lab05-$STUDENT_NAME
```

> ✅ **Expected Output:** `Env=production Log=info`

> 💡 **Key Concept:** `valueFrom` is the preferred approach when you only need specific values or when ConfigMap keys do not match the expected environment variable names.

---

## Step 4: Consume ConfigMap as Volume Mounts

Mount the configuration files into an nginx container:

```yaml
# Save as pod-volume-mount.yaml
apiVersion: v1
kind: Pod
metadata:
  name: volume-mount-demo
  namespace: lab05-$STUDENT_NAME
spec:
  containers:
    - name: nginx
      image: nginx:1.25
      volumeMounts:
        - name: nginx-config
          mountPath: /etc/nginx/conf.d
          readOnly: true
        - name: app-config
          mountPath: /etc/app
          readOnly: true
  volumes:
    - name: nginx-config
      configMap:
        name: app-files
        items:
          - key: nginx.conf
            path: default.conf
    - name: app-config
      configMap:
        name: app-files
        items:
          - key: app.properties
            path: app.properties
```

> 📝 **Note:** The `items` field allows mapping specific keys to specific file paths within the mount. Without `items`, all keys are mounted as files. The `readOnly` flag is a best practice for configuration volumes.

### Verify the Mounted Files

```bash
kubectl apply -f pod-volume-mount.yaml

# Wait for the pod to be running
kubectl wait --for=condition=Ready pod/volume-mount-demo \
    -n lab05-$STUDENT_NAME --timeout=60s

# Verify the nginx config is mounted
kubectl exec volume-mount-demo -n lab05-$STUDENT_NAME -- \
    cat /etc/nginx/conf.d/default.conf

# Verify the app properties are mounted
kubectl exec volume-mount-demo -n lab05-$STUDENT_NAME -- \
    cat /etc/app/app.properties

# Test the health endpoint
kubectl exec volume-mount-demo -n lab05-$STUDENT_NAME -- \
    curl -s http://localhost/health
```

> ✅ **Expected Output:** The nginx.conf and app.properties contents are displayed. The health endpoint returns `OK`.

---

## Step 5: Create Secrets

### Create an Opaque Secret

Create a generic (Opaque) Secret for database credentials:

```bash
# Create a Secret from literal values
kubectl create secret generic db-credentials \
    --from-literal=DB_USERNAME=app_user \
    --from-literal=DB_PASSWORD='S3cur3P@ssw0rd!' \
    --from-literal=DB_HOST=postgres-svc.lab05-$STUDENT_NAME.svc.cluster.local \
    -n lab05-$STUDENT_NAME

# Inspect the Secret
kubectl get secret db-credentials -n lab05-$STUDENT_NAME -o yaml
```

```bash
# Decode a secret value
kubectl get secret db-credentials -n lab05-$STUDENT_NAME \
    -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
```

> ⚠️ **Security Note:** Base64 is encoding, not encryption. Always use RBAC to restrict Secret access and enable encryption at rest via AWS KMS.

### Create a TLS Secret

Generate a self-signed certificate and create a TLS Secret:

```bash
# Generate a self-signed certificate (for lab purposes only)
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout tls.key -out tls.crt \
    -subj "/CN=app.lab05-$STUDENT_NAME.local/O=Verisign Lab"

# Create a TLS Secret
kubectl create secret tls app-tls \
    --cert=tls.crt \
    --key=tls.key \
    -n lab05-$STUDENT_NAME

# Verify the TLS Secret
kubectl get secret app-tls -n lab05-$STUDENT_NAME -o yaml
```

> ✅ **Expected Output:** The Secret type is `kubernetes.io/tls` with keys `tls.crt` and `tls.key` in the data section.

> 💡 **Key Concept:** TLS Secrets are a specific Secret type that Kubernetes validates for proper certificate and key format. The keys must be named `tls.crt` and `tls.key`. This type is commonly used with Ingress controllers for TLS termination.

---

## Step 6: Consume Secrets as Env Vars and Volume Mounts

### Secret as Environment Variables

```yaml
# Save as pod-secret-env.yaml
apiVersion: v1
kind: Pod
metadata:
  name: secret-env-demo
  namespace: lab05-$STUDENT_NAME
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "echo Host=$DB_HOST User=$DB_USER && sleep 3600"]
      env:
        - name: DB_HOST
          valueFrom:
            secretKeyRef:
              name: db-credentials
              key: DB_HOST
        - name: DB_USER
          valueFrom:
            secretKeyRef:
              name: db-credentials
              key: DB_USERNAME
  restartPolicy: Never
```

```bash
kubectl apply -f pod-secret-env.yaml
kubectl logs secret-env-demo -n lab05-$STUDENT_NAME
```

> ✅ **Expected Output:** `Host=postgres-svc.lab05-$STUDENT_NAME.svc.cluster.local User=app_user`

> 📝 **Note:** The `secretKeyRef` works identically to `configMapKeyRef`. Avoid logging sensitive environment variables like passwords in production.

### Secret as Volume Mount

```yaml
# Save as pod-secret-volume.yaml
apiVersion: v1
kind: Pod
metadata:
  name: secret-vol-demo
  namespace: lab05-$STUDENT_NAME
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "ls -la /etc/db-creds/ && sleep 3600"]
      volumeMounts:
        - name: db-creds
          mountPath: /etc/db-creds
          readOnly: true
  volumes:
    - name: db-creds
      secret:
        secretName: db-credentials
        defaultMode: 0400
  restartPolicy: Never
```

```bash
kubectl apply -f pod-secret-volume.yaml
kubectl logs secret-vol-demo -n lab05-$STUDENT_NAME

# Read a specific secret file
kubectl exec secret-vol-demo -n lab05-$STUDENT_NAME -- cat /etc/db-creds/DB_USERNAME
```

> 💡 **Best Practice:** Use `defaultMode: 0400` for Secrets to restrict file permissions (read-only by owner). Volume-mounted Secrets are stored in tmpfs (memory-backed), never written to disk on the node. This is more secure than environment variables, which can be exposed via `/proc` or process listing.

---

## Step 7: Immutable ConfigMaps and Secrets

```yaml
# Save as immutable-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: immutable-app-config
  namespace: lab05-$STUDENT_NAME
data:
  APP_VERSION: "2.1.0"
  FEATURE_FLAGS: "dark-mode=true,beta-api=false"
  RELEASE_DATE: "2026-03-13"
immutable: true
```

```bash
kubectl apply -f immutable-config.yaml

# Try to update it (this will fail)
kubectl patch configmap immutable-app-config \
    -n lab05-$STUDENT_NAME \
    --type merge \
    -p '{"data":{"APP_VERSION":"2.2.0"}}'
```

> ⚠️ **Expected Error:** `Error: configmaps "immutable-app-config" is immutable`

> 💡 **Key Concept:** To update an immutable ConfigMap, you must delete and recreate it. Use a naming convention with version suffixes (e.g., `app-config-v2`) for safe rollouts. At scale, immutable ConfigMaps significantly reduce apiserver load since no watches are needed.

---

## Step 8: Projected Volumes

Projected volumes allow combining multiple volume sources into a single mount point.

### Combine ConfigMap, Secret, and Downward API

```yaml
# Save as pod-projected.yaml
apiVersion: v1
kind: Pod
metadata:
  name: projected-demo
  namespace: lab05-$STUDENT_NAME
  labels: { app: projected-demo, version: v1 }
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "ls -la /etc/projected && sleep 3600"]
      volumeMounts:
        - name: all-config
          mountPath: /etc/projected
          readOnly: true
  volumes:
    - name: all-config
      projected:
        sources:
          - configMap:
              name: app-config
              items:
                - key: APP_ENV
                  path: APP_ENV
                - key: APP_LOG_LEVEL
                  path: APP_LOG_LEVEL
          - secret:
              name: db-credentials
              items:
                - key: DB_USERNAME
                  path: DB_USERNAME
          - downwardAPI:
              items:
                - path: labels
                  fieldRef:
                    fieldPath: metadata.labels
                - path: namespace
                  fieldRef:
                    fieldPath: metadata.namespace
  restartPolicy: Never
```

### Verify Projected Volume

```bash
kubectl apply -f pod-projected.yaml

# Wait for the pod to be running
kubectl wait --for=condition=Ready pod/projected-demo \
    -n lab05-$STUDENT_NAME --timeout=60s

# Check all projected files
kubectl exec projected-demo -n lab05-$STUDENT_NAME -- ls -la /etc/projected

# View the downward API labels
kubectl exec projected-demo -n lab05-$STUDENT_NAME -- cat /etc/projected/labels

# View the namespace
kubectl exec projected-demo -n lab05-$STUDENT_NAME -- cat /etc/projected/namespace
```

> ✅ **Expected Output:** The `/etc/projected` directory contains files from all three sources: `APP_ENV`, `APP_LOG_LEVEL` (ConfigMap), `DB_USERNAME` (Secret), `labels`, and `namespace` (downward API). The labels file contains `app="projected-demo"` and `version="v1"`. The namespace file contains `lab05-$STUDENT_NAME`.

> 💡 **Key Concept:** Projected volumes merge multiple sources into a single directory. This is powerful when applications expect all configuration in one location. The downward API injects pod metadata like labels, annotations, namespace, and resource limits as files.

---

## Step 9: ConfigMap Update Propagation

This step demonstrates a critical behavioral difference between environment variables and volume mounts when a ConfigMap is updated.

### Deploy a Pod with Both Consumption Methods

```yaml
# Save as pod-update-test.yaml
apiVersion: v1
kind: Pod
metadata:
  name: update-test
  namespace: lab05-$STUDENT_NAME
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "while true; do echo \"ENV: $APP_LOG_LEVEL | FILE: $(cat /etc/config/APP_LOG_LEVEL)\"; sleep 10; done"]
    envFrom:
      - configMapRef: { name: app-config }
    volumeMounts:
      - name: config-vol
        mountPath: /etc/config
        readOnly: true
  volumes:
    - name: config-vol
      configMap:
        name: app-config
  restartPolicy: Never
```

```bash
kubectl apply -f pod-update-test.yaml
kubectl wait --for=condition=Ready pod/update-test \
    -n lab05-$STUDENT_NAME --timeout=60s

# Check initial values
kubectl logs update-test -n lab05-$STUDENT_NAME --tail=1
```

> ✅ **Initial Output:** `ENV: info | FILE: info`

### Update the ConfigMap and Observe

```bash
# Update the ConfigMap
kubectl patch configmap app-config -n lab05-$STUDENT_NAME \
    --type merge \
    -p '{"data":{"APP_LOG_LEVEL":"debug"}}'

# Wait 30-60 seconds for kubelet sync, then check logs
sleep 60
kubectl logs update-test -n lab05-$STUDENT_NAME --tail=3
```

> ✅ **Expected Output (after ~60 seconds):** `ENV: info | FILE: debug`

> 💡 **Key Point:** Volume mounts update automatically (~60s); environment variables do **NOT** update until pod restart. Use volume mounts with a file watcher for live config reload. For env var changes, a rolling restart is required: `kubectl rollout restart deployment/<name>`.

---

## Part 3: Vault & External Secrets

**Syncing Secrets from HashiCorp Vault via ESO**

---

## Step 10: Connect to Vault and Write Secrets

### Store Secrets in Vault

Write database credentials to your Vault path:

```bash
# Exec into the Vault pod
kubectl exec -it vault-0 -n vault -- /bin/sh

# Store database credentials at your unique path
vault kv put secret/lab05-$STUDENT_NAME/database \
  username=admin \
  password=s3cureP@ss \
  host=postgres.lab05-$STUDENT_NAME.svc.cluster.local \
  port=5432
```

Verify the secret was stored:

```bash
# Read the secret back
vault kv get secret/lab05-$STUDENT_NAME/database

# Read as JSON for structured output
vault kv get -format=json secret/lab05-$STUDENT_NAME/database
```

> ✅ **Checkpoint:** You should see all four key-value pairs (username, password, host, port). The version should be 1.

### Create a Vault Policy and Auth Role

Grant read-only access to your secrets path:

```bash
# Still inside the Vault pod shell — write a read-only policy
vault policy write lab05-readonly-$STUDENT_NAME - <<EOF
path "secret/data/lab05-$STUDENT_NAME/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/lab05-$STUDENT_NAME/*" {
  capabilities = ["read", "list"]
}
EOF

# Create a K8s auth role bound to your namespace
vault write auth/kubernetes/role/lab05-role-$STUDENT_NAME \
  bound_service_account_names=lab05-sa \
  bound_service_account_namespaces=lab05-$STUDENT_NAME \
  policies=lab05-readonly-$STUDENT_NAME \
  ttl=1h

# Verify, then exit the Vault pod
vault policy read lab05-readonly-$STUDENT_NAME
vault read auth/kubernetes/role/lab05-role-$STUDENT_NAME
exit
```

> ⚠️ **Note:** KV v2 policies require the `/data/` prefix in paths (e.g., `secret/data/lab05-...`) even though the CLI uses `secret/lab05-...`. This is the most common policy mistake.

---

## Step 11: Create an ExternalSecret to Sync from Vault

Set up the identity chain and sync definition:

```bash
# Create the ServiceAccount that matches the Vault role
kubectl create serviceaccount lab05-sa -n lab05-$STUDENT_NAME

# Verify the ClusterSecretStore is ready
kubectl get clustersecretstore vault-backend
```

Create the ExternalSecret:

```yaml
# Apply directly with kubectl
cat <<'EOF' | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: vault-db-credentials
  namespace: lab05-$STUDENT_NAME
spec:
  refreshInterval: "1m"
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: vault-db-credentials
    creationPolicy: Owner
  data:
    - secretKey: username
      remoteRef:
        key: secret/lab05-$STUDENT_NAME/database
        property: username
    - secretKey: password
      remoteRef:
        key: secret/lab05-$STUDENT_NAME/database
        property: password
EOF
```

> 💡 **Identity chain:** Pod runs as `lab05-sa` in `lab05-$STUDENT_NAME` → Vault validates against the auth role → policy grants read access to the secret path.

---

## Step 12: Verify the Synced Kubernetes Secret

```bash
# Check ExternalSecret status (look for SecretSynced)
kubectl get externalsecret -n lab05-$STUDENT_NAME
kubectl describe externalsecret vault-db-credentials -n lab05-$STUDENT_NAME
```

Decode the synced secret values:

```bash
# Verify the K8s Secret was created and decode values
kubectl get secret vault-db-credentials -n lab05-$STUDENT_NAME -o yaml

kubectl get secret vault-db-credentials -n lab05-$STUDENT_NAME \
  -o jsonpath='{.data.username}' | base64 -d && echo
kubectl get secret vault-db-credentials -n lab05-$STUDENT_NAME \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

> ✅ **Expected:** Decoded values should match what you stored in Vault: `admin` and `s3cureP@ss`.

> 💡 **The complete chain:** Vault KV → ESO (ClusterSecretStore + ExternalSecret) → K8s Secret. The application consumes a standard K8s Secret and has no awareness of Vault.

> ⚠️ **Troubleshooting:** If the ExternalSecret status shows an error, use `describe` to see the message. Common issues are policy path mismatches or ServiceAccount name mismatches.

---

## Step 13: Clean Up

Remove all resources created during this lab:

```bash
# Delete the entire namespace (removes all resources within it)
kubectl delete namespace lab05-$STUDENT_NAME

# Verify the namespace is gone
kubectl get namespace lab05-$STUDENT_NAME

# Clean up Vault resources (exec into Vault pod)
kubectl exec -it vault-0 -n vault -- /bin/sh -c '
  vault kv metadata delete secret/lab05-$STUDENT_NAME/database
  vault delete auth/kubernetes/role/lab05-role-$STUDENT_NAME
  vault policy delete lab05-readonly-$STUDENT_NAME
'

# Clean up local files
rm -f nginx.conf app.properties tls.key tls.crt \
    pod-envfrom.yaml pod-valuefrom.yaml pod-volume-mount.yaml \
    pod-secret-env.yaml pod-secret-volume.yaml immutable-config.yaml \
    pod-projected.yaml pod-update-test.yaml
```

> ✅ **Expected Output:** `namespace "lab05-$STUDENT_NAME" deleted` followed by `Error from server (NotFound): namespaces "lab05-$STUDENT_NAME" not found` confirming deletion.

> ⚠️ **Troubleshooting:** Namespace deletion can take a minute or more while Kubernetes finalizes all resources. If it hangs, check for resources with finalizers using:
> ```bash
> kubectl api-resources --verbs=list --namespaced -o name | \
>   xargs -n 1 kubectl get -n lab05-$STUDENT_NAME
> ```

---

## Summary and Key Takeaways

### ConfigMaps

- Created from literals and files
- Consumed via `envFrom`, `valueFrom`, and volume mounts
- Volume mounts auto-update; env vars do not
- Immutable ConfigMaps prevent accidental changes

### Secrets & Vault

- Same consumption patterns as ConfigMaps
- Base64-encoded, not encrypted by default
- TLS type validates cert/key format
- Vault + ESO syncs external secrets into K8s Secrets automatically

### ConfigMap vs Secret Comparison

| Feature | ConfigMap | Secret |
|---------|-----------|--------|
| Data encoding | Plain text | Base64-encoded |
| Size limit | 1 MiB | 1 MiB |
| Volume storage | Node filesystem | tmpfs (in-memory) |
| RBAC | Standard | Restricted recommended |
| Use case | Non-sensitive config | Passwords, tokens, certs |
| Immutable support | Yes | Yes |

> 💡 **Production Best Practices:** Use volume mounts for live-reloadable config. Enable KMS encryption for Secrets at rest. Use immutable resources where possible. Store sensitive data in Vault and sync via External Secrets Operator. For data larger than 1 MiB, consider using init containers to fetch configuration from an external store like AWS Systems Manager Parameter Store or HashiCorp Vault.
