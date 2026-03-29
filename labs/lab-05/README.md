# Lab 5: ConfigMaps and Secrets
### Externalizing Configuration and Managing Sensitive Data
**Intermediate Kubernetes — Module 5 of 13**

---

## Lab Overview

### What You Will Do

- Create ConfigMaps from literals and files; consume as env vars and volume mounts
- Create Secrets (Opaque, TLS) and consume as env vars and volume mounts

### Prerequisites

- Completion of Labs 1–4 with `kubectl` access  |  **Duration:** ~30 minutes

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

Now create configuration files and load them into a ConfigMap. The `nginx.conf` file is static, while `app.properties` contains your student name:

```bash
cp nginx.conf /tmp/nginx.conf
envsubst < app.properties > /tmp/app.properties

kubectl create configmap app-files \
    --from-file=nginx.conf=/tmp/nginx.conf \
    --from-file=app.properties=/tmp/app.properties \
    -n lab05-$STUDENT_NAME
```

---

## Step 2: Consume ConfigMap as Environment Variables

### Using envFrom (inject all keys)

<!-- Creates a pod that imports all ConfigMap keys as env vars -->

Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < pod-envfrom.yaml | kubectl apply -f -
kubectl logs env-from-demo -n lab05-$STUDENT_NAME | grep APP_
```

### Using valueFrom (inject specific keys with renaming)

<!-- Creates a pod that selectively maps ConfigMap keys to different env var names -->

Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < pod-valuefrom.yaml | kubectl apply -f -
kubectl logs value-from-demo -n lab05-$STUDENT_NAME
```

> ✅ **Checkpoint:** Output is `Env=production Log=info`.

---

## Step 3: Consume ConfigMap as Volume Mounts

Mount the configuration files into an nginx container:

<!-- Creates a pod with ConfigMap data mounted as files -->

Apply the manifest:

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

<!-- Creates a pod that reads Secret keys into env vars -->

Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < pod-secret-env.yaml | kubectl apply -f -
kubectl logs secret-env-demo -n lab05-$STUDENT_NAME
```

### Secret as Volume Mount

<!-- Creates a pod that mounts a Secret as files with restricted permissions -->

Apply the manifest:

```bash
envsubst '$STUDENT_NAME' < pod-secret-volume.yaml | kubectl apply -f -
kubectl logs secret-vol-demo -n lab05-$STUDENT_NAME
kubectl exec secret-vol-demo -n lab05-$STUDENT_NAME -- cat /etc/db-creds/DB_USERNAME
```

> ✅ **Checkpoint:** Secret files are mounted with `0400` permissions.

---

## Step 6: Clean Up

```bash
kubectl delete namespace lab05-$STUDENT_NAME
rm -f tls.key tls.crt /tmp/nginx.conf /tmp/app.properties
```

---

## Summary

- **ConfigMaps:** Created from literals and files; consumed via `envFrom`, `valueFrom`, and volume mounts
- **Secrets:** Same consumption patterns as ConfigMaps; base64-encoded, not encrypted by default; use RBAC to restrict access and enable KMS encryption at rest

---

*Lab 5 Complete — Up Next: Lab 6 — Ingress and Gateway API*
