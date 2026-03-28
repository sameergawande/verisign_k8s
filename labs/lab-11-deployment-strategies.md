# Lab 11: Deployment Strategies
### Rolling Updates, Blue-Green, Canary and Disruption Budgets
**Intermediate Kubernetes — Module 11 of 13**

---

## Lab Overview

### Objectives

- Perform rolling updates and rollbacks
- Implement blue-green and canary deployment patterns
- Configure Pod Disruption Budgets
- Detect stuck rollouts with progress deadlines

### Prerequisites

- kubectl installed and configured
- Access to a Kubernetes cluster (EKS)
- Completed Labs 1--10

> **Duration:** ~45 minutes

---

## Step 1: Deploy v1 of the Application

```bash
export STUDENT_NAME=<your-name>
echo "Student: $STUDENT_NAME"
```

> ⚠️ **Important:** Your `$STUDENT_NAME` ensures your resources don't conflict with other students.

```bash
kubectl create namespace deploy-lab-$STUDENT_NAME

kubectl create configmap app-v1-page \
  --from-literal=index.html='<h1 \
    style="color:blue">Application v1</h1><p>Version: 1.0.0</p>' \
  -n deploy-lab-$STUDENT_NAME
```

Save the following as `app-deploy-v1.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: webapp, namespace: deploy-lab-$STUDENT_NAME }
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxSurge: 1, maxUnavailable: 1 }
  selector: { matchLabels: { app: webapp } }
  template:
    metadata: { labels: { app: webapp, version: v1 } }
    spec:
      containers:
      - name: nginx
        image: nginx:1.24
        ports: [{containerPort: 80}]
        volumeMounts: [{ name: html, mountPath: /usr/share/nginx/html }]
      volumes: [{ name: html, configMap: { name: app-v1-page } }]
```

Apply and expose:

```bash
envsubst < app-deploy-v1.yaml | kubectl apply -f -

kubectl expose deployment webapp \
  --port=80 --target-port=80 \
  --name=webapp-svc \
  -n deploy-lab-$STUDENT_NAME

kubectl get pods -n deploy-lab-$STUDENT_NAME -l app=webapp
```

Verify v1 is serving traffic:

```bash
kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never \
  -n deploy-lab-$STUDENT_NAME -- curl -s webapp-svc
```

> ✅ **Checkpoint:** All pods should be Running. The curl response should show **Application v1**.

---

## Step 2: Perform a Rolling Update to v2

```bash
kubectl create configmap app-v2-page \
  --from-literal=index.html='<h1 \
    style="color:green">Application v2</h1><p>Version: 2.0.0</p>' \
  -n deploy-lab-$STUDENT_NAME

kubectl set image deployment/webapp nginx=nginx:1.25 \
  -n deploy-lab-$STUDENT_NAME

kubectl patch deployment webapp -n deploy-lab-$STUDENT_NAME --type=json \
  -p='[{"op":"replace",
  "path":"/spec/template/spec/volumes/0/configMap/name",
  "value":"app-v2-page"}]'
```

---

## Step 3: Monitor the Rolling Update

```bash
kubectl rollout status deployment/webapp -n deploy-lab-$STUDENT_NAME

kubectl rollout history deployment/webapp -n deploy-lab-$STUDENT_NAME
```

Verify v2 is serving:

```bash
kubectl run curl-test2 --image=curlimages/curl --rm -it --restart=Never \
  -n deploy-lab-$STUDENT_NAME -- curl -s webapp-svc

kubectl get replicasets -n deploy-lab-$STUDENT_NAME -l app=webapp
```

> ✅ The curl response should show **Application v2**. The old ReplicaSet should have 0 replicas.

---

## Step 4: Rollback to v1

```bash
kubectl rollout undo deployment/webapp -n deploy-lab-$STUDENT_NAME

kubectl rollout status deployment/webapp -n deploy-lab-$STUDENT_NAME

kubectl run curl-test3 --image=curlimages/curl --rm -it --restart=Never \
  -n deploy-lab-$STUDENT_NAME -- curl -s webapp-svc

kubectl rollout history deployment/webapp -n deploy-lab-$STUDENT_NAME
```

> ✅ The curl response should show **Application v1** again. To target a specific revision: `kubectl rollout undo deployment/webapp --to-revision=1`.

---

## Step 5: Implement Blue-Green Deployment

Save as `blue-deploy.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: webapp-blue, namespace: deploy-lab-$STUDENT_NAME }
spec:
  replicas: 2
  selector:
    matchLabels: { app: webapp-bg, version: blue }
  template:
    metadata: { labels: { app: webapp-bg, version: blue } }
    spec:
      containers:
      - name: nginx
        image: nginx:1.24
        ports: [{containerPort: 80}]
        command: ["/bin/sh", "-c"]
        args: ["echo '<h1 style=\"color:blue\">BLUE</h1>' \
          > /usr/share/nginx/html/index.html; nginx -g 'daemon off;'"]
```

Save as `green-deploy.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: webapp-green, namespace: deploy-lab-$STUDENT_NAME }
spec:
  replicas: 2
  selector:
    matchLabels: { app: webapp-bg, version: green }
  template:
    metadata: { labels: { app: webapp-bg, version: green } }
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
        ports: [{containerPort: 80}]
        command: ["/bin/sh", "-c"]
        args: ["echo '<h1 style=\"color:green\">GREEN</h1>' \
          > /usr/share/nginx/html/index.html; nginx -g 'daemon off;'"]
```

Save as `bg-service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: webapp-bg-svc
  namespace: deploy-lab-$STUDENT_NAME
spec:
  selector:
    app: webapp-bg
    version: blue
  ports:
  - port: 80
    targetPort: 80
```

Apply and switch traffic:

```bash
envsubst < blue-deploy.yaml | kubectl apply -f -
envsubst < green-deploy.yaml | kubectl apply -f -
envsubst < bg-service.yaml | kubectl apply -f -

kubectl run bg-test1 --image=curlimages/curl --rm -it --restart=Never \
  -n deploy-lab-$STUDENT_NAME -- curl -s webapp-bg-svc

# Switch traffic to green
kubectl patch service webapp-bg-svc -n deploy-lab-$STUDENT_NAME \
  -p '{"spec":{"selector":{"version":"green"}}}'

kubectl run bg-test2 --image=curlimages/curl --rm -it --restart=Never \
  -n deploy-lab-$STUDENT_NAME -- curl -s webapp-bg-svc
```

> ✅ First curl shows **BLUE**, second curl shows **GREEN**. The switch is instantaneous.

---

## Step 6: Implement Canary Deployment

Save as `canary-stable.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: webapp-stable, namespace: deploy-lab-$STUDENT_NAME }
spec:
  replicas: 2
  selector:
    matchLabels: { app: webapp-canary, track: stable }
  template:
    metadata: { labels: { app: webapp-canary, track: stable } }
    spec:
      containers:
      - name: nginx
        image: nginx:1.24
        ports: [{containerPort: 80}]
        command: ["/bin/sh", "-c"]
        args:
        - "echo 'STABLE-v1' > \
          /usr/share/nginx/html/index.html; \
          nginx -g 'daemon off;'"
```

Save as `canary-new.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: webapp-canary, namespace: deploy-lab-$STUDENT_NAME }
spec:
  replicas: 1
  selector:
    matchLabels: { app: webapp-canary, track: canary }
  template:
    metadata: { labels: { app: webapp-canary, track: canary } }
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
        ports: [{containerPort: 80}]
        command: ["/bin/sh", "-c"]
        args:
        - "echo 'CANARY-v2' > \
          /usr/share/nginx/html/index.html; \
          nginx -g 'daemon off;'"
```

Save as `canary-service.yaml` (selects both stable and canary via the shared `app` label):

```yaml
apiVersion: v1
kind: Service
metadata: { name: webapp-canary-svc, namespace: deploy-lab-$STUDENT_NAME }
spec:
  selector:
    app: webapp-canary
  ports: [{ port: 80, targetPort: 80 }]
```

```bash
envsubst < canary-stable.yaml | kubectl apply -f -
envsubst < canary-new.yaml | kubectl apply -f -
envsubst < canary-service.yaml | kubectl apply -f -
kubectl get pods -n deploy-lab-$STUDENT_NAME -l app=webapp-canary --show-labels
```

> ✅ 3 pods total -- 2 with `track=stable` and 1 with `track=canary` (~33% canary traffic).

---

## Step 7: Verify Canary Traffic Distribution

```bash
kubectl run traffic-test --image=curlimages/curl --rm -it --restart=Never \
  -n deploy-lab-$STUDENT_NAME -- sh -c '
  STABLE=0; CANARY=0
  for i in $(seq 1 20); do
    RESPONSE=$(curl -s webapp-canary-svc)
    if echo "$RESPONSE" | grep -q "STABLE"; then
      STABLE=$((STABLE+1))
    else
      CANARY=$((CANARY+1))
    fi
  done
  echo "Stable: $STABLE / Canary: $CANARY out of 20 requests"
'
```

> ✅ Approximately `Stable: 14 / Canary: 6` (roughly 67/33 split). Results will vary.

---

## Step 8: Pod Disruption Budgets

Save as `pdb.yaml`:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: { name: webapp-pdb, namespace: deploy-lab-$STUDENT_NAME }
spec:
  minAvailable: 2
  selector:
    matchLabels: { app: webapp }
```

```bash
envsubst < pdb.yaml | kubectl apply -f -
kubectl get pdb -n deploy-lab-$STUDENT_NAME
```

Test with a dry-run drain:

```bash
kubectl get pods -n deploy-lab-$STUDENT_NAME -l app=webapp -o wide

# Get a node name from the output above, then dry-run drain
NODE_NAME=$(kubectl get pods -n deploy-lab-$STUDENT_NAME -l app=webapp \
  -o jsonpath='{.items[0].spec.nodeName}')

# Dry-run only -- NEVER drain without --dry-run in a shared cluster
kubectl drain $NODE_NAME --ignore-daemonsets \
  --delete-emptydir-data --dry-run=client
```

---

## Step 9: Configure Progress Deadline

Trigger a stuck rollout with a non-existent image:

```bash
kubectl patch deployment webapp -n deploy-lab-$STUDENT_NAME \
  -p '{"spec":{"progressDeadlineSeconds":60}}'

kubectl set image deployment/webapp nginx=nginx:nonexistent-tag \
  -n deploy-lab-$STUDENT_NAME

# Will report "exceeded its progress deadline" after 60s
kubectl rollout status deployment/webapp -n deploy-lab-$STUDENT_NAME --timeout=90s
```

Recover:

```bash
kubectl rollout undo deployment/webapp -n deploy-lab-$STUDENT_NAME
kubectl rollout status deployment/webapp -n deploy-lab-$STUDENT_NAME
```

> ✅ After rollback, all pods should be Running and Ready.

---

## Step 10: Clean Up

```bash
kubectl delete namespace deploy-lab-$STUDENT_NAME
```

---

## Key Takeaways

- **Rolling Updates** -- gradual replacement with `maxSurge`/`maxUnavailable` control
- **Blue-Green** -- instant traffic switch via service selector, requires double resources
- **Canary** -- gradual traffic shift using replica ratios
- **Pod Disruption Budgets** -- protects availability during voluntary disruptions
- **Progress Deadline** -- detects stuck rollouts automatically
