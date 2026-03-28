# Lab 5: Configuration, Secrets, and Vault
### Externalizing Configuration, Managing Sensitive Data, and External Secrets
**Intermediate Kubernetes — Module 5 of 13**

---

## Lab Overview

### What You Will Do

- Create ConfigMaps from literals and files; consume as env vars and volume mounts
- Create Secrets (Opaque, TLS), use immutable resources, and projected volumes
- Observe ConfigMap update propagation
- Store secrets in HashiCorp Vault and sync via External Secrets Operator

### Prerequisites

- Completion of Labs 1–4 with `kubectl` access  |  **Duration:** 45–60 minutes

---

## Environment Setup

```bash
export STUDENT_NAME=<your-name>
echo "Student: $STUDENT_NAME"
```

---

## Step 1: Create ConfigMaps from Literals and Files

Create a namespace and a ConfigMap using literal key-value pairs:

```bash
kubectl create namespace lab05-$STUDENT_NAME

kubectl create configmap app-config \
    --from-literal=APP_ENV=production \
    --from-literal=APP_LOG_LEVEL=info \
    --from-literal=APP_MAX_CONNECTIONS=100 \
    --from-literal=APP_CACHE_TTL=3600 \
    -n lab05-$STUDENT_NAME

kubectl get configmap app-config -n lab05-$STUDENT_NAME -o yaml
```

Now create configuration files and load them into a ConfigMap:

```bash
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

cat <<EOF > app.properties
db.host=postgres-svc.lab05-$STUDENT_NAME.svc.cluster.local
db.port=5432
db.name=appdb
cache.ttl=3600
cache.max_size=256
EOF
```

```bash
kubectl create configmap app-files \
    --from-file=nginx.conf \
    --from-file=app.properties \
    -n lab05-$STUDENT_NAME
```

---

## Step 2: Consume ConfigMap as Environment Variables

### Using envFrom (inject all keys)

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
envsubst '$STUDENT_NAME' < pod-envfrom.yaml | kubectl apply -f -
kubectl logs env-from-demo -n lab05-$STUDENT_NAME | grep APP_
```

### Using valueFrom (inject specific keys with renaming)

```yaml
# Save as pod-valuefrom.yaml
apiVersion: v1
kind: Pod
metadata: { name: value-from-demo, namespace: lab05-$STUDENT_NAME }
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "echo Env=$ENVIRONMENT Log=$LOG_LEVEL && sleep 3600"]
      env:
        - name: ENVIRONMENT
          valueFrom: { configMapKeyRef: { name: app-config, key: APP_ENV } }
        - name: LOG_LEVEL
          valueFrom: { configMapKeyRef: { name: app-config, key: APP_LOG_LEVEL } }
  restartPolicy: Never
```

```bash
envsubst '$STUDENT_NAME' < pod-valuefrom.yaml | kubectl apply -f -
kubectl logs value-from-demo -n lab05-$STUDENT_NAME
```

> ✅ **Checkpoint:** Output is `Env=production Log=info`.

---

## Step 3: Consume ConfigMap as Volume Mounts

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

```bash
envsubst '$STUDENT_NAME' < pod-volume-mount.yaml | kubectl apply -f -
kubectl wait --for=condition=Ready pod/volume-mount-demo \
    -n lab05-$STUDENT_NAME --timeout=60s

kubectl exec volume-mount-demo -n lab05-$STUDENT_NAME -- \
    cat /etc/nginx/conf.d/default.conf
kubectl exec volume-mount-demo -n lab05-$STUDENT_NAME -- \
    cat /etc/app/app.properties
kubectl exec volume-mount-demo -n lab05-$STUDENT_NAME -- \
    curl -s http://localhost/health
```

> ✅ **Checkpoint:** The health endpoint returns `OK`.

---

## Step 4: Create Secrets

### Create an Opaque Secret

```bash
kubectl create secret generic db-credentials \
    --from-literal=DB_USERNAME=app_user \
    --from-literal=DB_PASSWORD='S3cur3P@ssw0rd!' \
    --from-literal=DB_HOST=postgres-svc.lab05-$STUDENT_NAME.svc.cluster.local \
    -n lab05-$STUDENT_NAME

kubectl get secret db-credentials -n lab05-$STUDENT_NAME \
    -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
```

### Create a TLS Secret

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout tls.key -out tls.crt \
    -subj "/CN=app.lab05-$STUDENT_NAME.local/O=Verisign Lab"

kubectl create secret tls app-tls \
    --cert=tls.crt \
    --key=tls.key \
    -n lab05-$STUDENT_NAME
```

---

## Step 5: Consume Secrets as Env Vars and Volume Mounts

### Secret as Environment Variables

```yaml
# Save as pod-secret-env.yaml
apiVersion: v1
kind: Pod
metadata: { name: secret-env-demo, namespace: lab05-$STUDENT_NAME }
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "echo Host=$DB_HOST User=$DB_USER && sleep 3600"]
      env:
        - name: DB_HOST
          valueFrom: { secretKeyRef: { name: db-credentials, key: DB_HOST } }
        - name: DB_USER
          valueFrom: { secretKeyRef: { name: db-credentials, key: DB_USERNAME } }
  restartPolicy: Never
```

```bash
envsubst '$STUDENT_NAME' < pod-secret-env.yaml | kubectl apply -f -
kubectl logs secret-env-demo -n lab05-$STUDENT_NAME
```

### Secret as Volume Mount

```yaml
# Save as pod-secret-volume.yaml
apiVersion: v1
kind: Pod
metadata: { name: secret-vol-demo, namespace: lab05-$STUDENT_NAME }
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "ls -la /etc/db-creds/ && sleep 3600"]
      volumeMounts:
        - { name: db-creds, mountPath: /etc/db-creds, readOnly: true }
  volumes:
    - name: db-creds
      secret: { secretName: db-credentials, defaultMode: 0400 }
  restartPolicy: Never
```

```bash
envsubst '$STUDENT_NAME' < pod-secret-volume.yaml | kubectl apply -f -
kubectl logs secret-vol-demo -n lab05-$STUDENT_NAME
kubectl exec secret-vol-demo -n lab05-$STUDENT_NAME -- cat /etc/db-creds/DB_USERNAME
```

> ✅ **Checkpoint:** Secret files are mounted with `0400` permissions.

---

## Step 6: Immutable ConfigMaps and Secrets

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
immutable: true
```

```bash
envsubst '$STUDENT_NAME' < immutable-config.yaml | kubectl apply -f -

# Try to update it (this will fail)
kubectl patch configmap immutable-app-config \
    -n lab05-$STUDENT_NAME \
    --type merge \
    -p '{"data":{"APP_VERSION":"2.2.0"}}'
```

> ✅ **Checkpoint:** The patch fails with `configmaps "immutable-app-config" is immutable`.

---

## Step 7: Projected Volumes

Combine ConfigMap, Secret, and Downward API into a single mount:

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
        - { name: all-config, mountPath: /etc/projected, readOnly: true }
  volumes:
    - name: all-config
      projected:
        sources:
          - configMap:
              name: app-config
              items: [{ key: APP_ENV, path: APP_ENV }]
          - secret:
              name: db-credentials
              items: [{ key: DB_USERNAME, path: DB_USERNAME }]
          - downwardAPI:
              items:
                - { path: labels, fieldRef: { fieldPath: metadata.labels } }
                - { path: namespace, fieldRef: { fieldPath: metadata.namespace } }
  restartPolicy: Never
```

```bash
envsubst '$STUDENT_NAME' < pod-projected.yaml | kubectl apply -f -
kubectl wait --for=condition=Ready pod/projected-demo \
    -n lab05-$STUDENT_NAME --timeout=60s
kubectl exec projected-demo -n lab05-$STUDENT_NAME -- ls -la /etc/projected
kubectl exec projected-demo -n lab05-$STUDENT_NAME -- cat /etc/projected/labels
```

> ✅ **Checkpoint:** `/etc/projected` contains `APP_ENV`, `DB_USERNAME`, `labels`, and `namespace`.

---

## Step 8: ConfigMap Update Propagation

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
envsubst '$STUDENT_NAME' < pod-update-test.yaml | kubectl apply -f -
kubectl wait --for=condition=Ready pod/update-test \
    -n lab05-$STUDENT_NAME --timeout=60s
kubectl logs update-test -n lab05-$STUDENT_NAME --tail=1
```

Update the ConfigMap and observe:

```bash
kubectl patch configmap app-config -n lab05-$STUDENT_NAME \
    --type merge \
    -p '{"data":{"APP_LOG_LEVEL":"debug"}}'

# Wait 30-60 seconds for kubelet sync, then check logs
sleep 60
kubectl logs update-test -n lab05-$STUDENT_NAME --tail=3
```

> ✅ **Checkpoint:** Output shows `ENV: info | FILE: debug` -- volume mounts update automatically (~60s) but environment variables do **NOT** update until pod restart.

---

## Part 3: Vault & External Secrets

---

## Step 9: Connect to Vault and Write Secrets

```bash
kubectl exec -it vault-0 -n vault -- /bin/sh

vault kv put secret/lab05-$STUDENT_NAME/database \
  username=admin \
  password=s3cureP@ss \
  host=postgres.lab05-$STUDENT_NAME.svc.cluster.local \
  port=5432

vault kv get secret/lab05-$STUDENT_NAME/database
```

### Create a Vault Policy and Auth Role

```bash
# Still inside the Vault pod shell
vault policy write lab05-readonly-$STUDENT_NAME - <<EOF
path "secret/data/lab05-$STUDENT_NAME/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/lab05-$STUDENT_NAME/*" {
  capabilities = ["read", "list"]
}
EOF

vault write auth/kubernetes/role/lab05-role-$STUDENT_NAME \
  bound_service_account_names=lab05-sa \
  bound_service_account_namespaces=lab05-$STUDENT_NAME \
  policies=lab05-readonly-$STUDENT_NAME \
  ttl=1h

vault policy read lab05-readonly-$STUDENT_NAME
exit
```

---

## Step 10: Create an ExternalSecret to Sync from Vault

```bash
kubectl create serviceaccount lab05-sa -n lab05-$STUDENT_NAME
kubectl get clustersecretstore vault-backend
```

Create the ExternalSecret:

```yaml
cat <<EOF | kubectl apply -f -
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

---

## Step 11: Verify the Synced Kubernetes Secret

```bash
kubectl get externalsecret -n lab05-$STUDENT_NAME
kubectl get secret vault-db-credentials -n lab05-$STUDENT_NAME \
  -o jsonpath='{.data.username}' | base64 -d && echo
```

> ✅ **Checkpoint:** Decoded values match what you stored in Vault: `admin` and `s3cureP@ss`.

> ⚠️ **Troubleshooting:** If status shows an error, use `kubectl describe externalsecret` to check for policy path or ServiceAccount name mismatches.

---

## Step 12: Clean Up

```bash
kubectl delete namespace lab05-$STUDENT_NAME

kubectl exec -it vault-0 -n vault -- /bin/sh -c "
  vault kv metadata delete secret/lab05-$STUDENT_NAME/database
  vault delete auth/kubernetes/role/lab05-role-$STUDENT_NAME
  vault policy delete lab05-readonly-$STUDENT_NAME
"
```

---

## Summary

- **ConfigMaps:** Created from literals and files; consumed via `envFrom`, `valueFrom`, and volume mounts; volume mounts auto-update but env vars do not
- **Secrets:** Same consumption patterns as ConfigMaps; base64-encoded, not encrypted by default; use RBAC to restrict access and enable KMS encryption at rest
- **Vault + ESO:** Syncs external secrets into K8s Secrets automatically; applications consume standard K8s Secrets with no Vault awareness
