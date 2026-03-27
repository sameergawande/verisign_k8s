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

### Create the v1 Application

First, create a namespace and a ConfigMap for our v1 index page:

```bash
# Set your unique student name
export STUDENT_NAME=<your-name>
echo "Student: $STUDENT_NAME"
```

> ⚠️ **Important:** This shared cluster is used by all 22 students. Your `$STUDENT_NAME` ensures your resources don't conflict with others.

```bash
# Create a dedicated namespace
kubectl create namespace deploy-lab-$STUDENT_NAME

# Create a ConfigMap with v1 index page
kubectl create configmap app-v1-page \
  --from-literal=index.html='<h1 \
    style="color:blue">Application v1</h1><p>Version: 1.0.0</p>' \
  -n deploy-lab-$STUDENT_NAME
```

> ✅ **Expected Output:**
> ```
> namespace/deploy-lab-$STUDENT_NAME created
> configmap/app-v1-page created
> ```

### Deploy v1 with Rolling Update Strategy

Create the Deployment manifest and apply it. Save the following as `app-deploy-v1.yaml`:

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

> 💡 **Key Concept:** `maxSurge: 1` means at most 3 pods can exist during an update. `maxUnavailable: 1` means at least 1 pod must remain available. These settings control the pace of the rolling update.

### Apply and Expose the Deployment

Apply the manifest and create a Service:

```bash
# Apply the deployment
kubectl apply -f app-deploy-v1.yaml

# Expose the deployment with a ClusterIP service
kubectl expose deployment webapp \
  --port=80 --target-port=80 \
  --name=webapp-svc \
  -n deploy-lab-$STUDENT_NAME

# Verify the deployment
kubectl get deployment webapp -n deploy-lab-$STUDENT_NAME
kubectl get pods -n deploy-lab-$STUDENT_NAME -l app=webapp
```

Verify v1 is serving traffic:

```bash
kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never \
  -n deploy-lab-$STUDENT_NAME -- curl -s webapp-svc
```

> ✅ **Checkpoint:** All pods should be Running with READY 1/1. The curl response should show **Application v1**.

---

## Step 2: Perform a Rolling Update to v2

Create a v2 ConfigMap and update the Deployment:

```bash
kubectl create configmap app-v2-page \
  --from-literal=index.html='<h1 \
    style="color:green">Application v2</h1><p>Version: 2.0.0</p>' \
  -n deploy-lab-$STUDENT_NAME

kubectl set image deployment/webapp nginx=nginx:1.25 \
  -n deploy-lab-$STUDENT_NAME --record

kubectl patch deployment webapp -n deploy-lab-$STUDENT_NAME --type=json \
  -p='[{"op":"replace",
  "path":"/spec/template/spec/volumes/0/configMap/name",
  "value":"app-v2-page"}]'
```

> 📝 **Note:** The `--record` flag is deprecated but still functional. It records the command in the rollout history for reference. In production, use annotations instead.

---

## Step 3: Monitor the Rolling Update

### Watch Rollout Progress

Use multiple commands to observe the rolling update:

```bash
# Watch the rollout status (blocks until complete)
kubectl rollout status deployment/webapp -n deploy-lab-$STUDENT_NAME

# View rollout history
kubectl rollout history deployment/webapp -n deploy-lab-$STUDENT_NAME

# Describe the deployment to see events
kubectl describe deployment webapp -n deploy-lab-$STUDENT_NAME | tail -20
```

> ✅ **Expected Output:**
> ```
> deployment "webapp" successfully rolled out
> ```
> The rollout history should show at least 2 revisions. The `describe` output shows ReplicaSet scaling events -- old ReplicaSets are scaled down while new ones are scaled up.

### Verify the Update

Confirm v2 is now serving traffic:

```bash
# Check pods are running the new image
kubectl get pods -n deploy-lab-$STUDENT_NAME -l app=webapp -o wide

# Verify the response
kubectl run curl-test2 --image=curlimages/curl --rm -it --restart=Never \
  -n deploy-lab-$STUDENT_NAME -- curl -s webapp-svc

# Check the ReplicaSets
kubectl get replicasets -n deploy-lab-$STUDENT_NAME -l app=webapp
```

> ✅ **Expected Output:** The curl response should show **Application v2**. The old ReplicaSet should have 0 desired/current pods, while the new one has the full replica count.

> 💡 **Key Concept:** Kubernetes keeps the old ReplicaSet around with 0 replicas. This is what enables rollback. The `revisionHistoryLimit` setting controls how many old ReplicaSets are retained.

---

## Step 4: Rollback to v1

Undo the rollout to return to v1:

```bash
# Rollback to the previous revision
kubectl rollout undo deployment/webapp -n deploy-lab-$STUDENT_NAME

# Watch the rollback progress
kubectl rollout status deployment/webapp -n deploy-lab-$STUDENT_NAME

# Verify we are back to v1
kubectl run curl-test3 --image=curlimages/curl --rm -it --restart=Never \
  -n deploy-lab-$STUDENT_NAME -- curl -s webapp-svc

# Check rollout history (notice the revision numbers)
kubectl rollout history deployment/webapp -n deploy-lab-$STUDENT_NAME
```

> ✅ **Expected Output:** The curl response should show **Application v1** again. The rollout history will show a new revision number for the rollback.

> 💡 **Rollback to a Specific Revision:** You can also target a specific revision:
> ```bash
> kubectl rollout undo deployment/webapp --to-revision=1 -n deploy-lab-$STUDENT_NAME
> ```

> 📝 **Note:** A rollback reuses the old ReplicaSet. It is essentially another rolling update, just to a previously known-good state. The revision numbers never decrease.

---

## Step 5: Implement Blue-Green Deployment

### Deploy the Blue Version

Create a blue deployment with its own version label. Save as `blue-deploy.yaml`:

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

### Deploy the Green Version

Create a green deployment alongside blue. Save as `green-deploy.yaml`:

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

### Create the Blue-Green Service

Create a Service that initially points to blue. Save as `bg-service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: webapp-bg-svc
  namespace: deploy-lab-$STUDENT_NAME
spec:
  selector:
    app: webapp-bg
    version: blue          # Currently routing to blue
  ports:
  - port: 80
    targetPort: 80
```

Apply both deployments and the service:

```bash
# Apply both deployments
kubectl apply -f blue-deploy.yaml
kubectl apply -f green-deploy.yaml

# Apply the service
kubectl apply -f bg-service.yaml
```

### Switch Traffic: Blue to Green

Perform the blue-green switch by changing the service selector:

```bash
# Verify blue is serving
kubectl run bg-test1 --image=curlimages/curl --rm -it --restart=Never \
  -n deploy-lab-$STUDENT_NAME -- curl -s webapp-bg-svc

# Switch traffic to green
kubectl patch service webapp-bg-svc -n deploy-lab-$STUDENT_NAME \
  -p '{"spec":{"selector":{"version":"green"}}}'

# Verify green is now serving
kubectl run bg-test2 --image=curlimages/curl --rm -it --restart=Never \
  -n deploy-lab-$STUDENT_NAME -- curl -s webapp-bg-svc
```

> ✅ **Expected Output:** First curl shows **BLUE**, second curl shows **GREEN**. The switch is instantaneous.

> 💡 **Production Tip:** Keep the blue deployment running until green is validated. If issues arise, switch back immediately by patching the selector to `version: blue`.

> 📝 **Note:** Unlike rolling updates, blue-green switches 100% of traffic at once. The rollback is equally fast. The trade-off is that you need double the resources during deployment.

---

## Step 6: Implement Canary Deployment

### Deploy the Stable Version

Create the stable deployment with 2 replicas. Save as `canary-stable.yaml`:

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

### Deploy the Canary Version

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

> 💡 **Traffic Ratio:** With 2 stable + 1 canary = 3 total pods, approximately 33% of traffic goes to the canary version. Adjust replica counts to control the ratio.

### Create the Canary Service

Create a Service that selects both stable and canary pods. Save as `canary-service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata: { name: webapp-canary-svc, namespace: deploy-lab-$STUDENT_NAME }
spec:
  selector:
    app: webapp-canary    # Matches BOTH stable and canary pods
  ports: [{ port: 80, targetPort: 80 }]
```

```bash
# Apply all canary resources and verify
kubectl apply -f canary-stable.yaml
kubectl apply -f canary-new.yaml
kubectl apply -f canary-service.yaml
kubectl get pods -n deploy-lab-$STUDENT_NAME -l app=webapp-canary --show-labels
```

> ✅ **Expected Output:** 3 pods total -- 2 with `track=stable` and 1 with `track=canary`.

> 📝 **Note:** The service selector uses only the shared `app` label. Both deployments have their own `track` label for management, but the service does not filter on `track`. Kubernetes round-robins across all matching endpoints.

---

## Step 7: Verify Canary Traffic Distribution

Run a loop to observe the traffic split between stable and canary:

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

> ✅ **Expected Output:** Approximately `Stable: 14 / Canary: 6` (roughly 67/33 split with 2 stable + 1 canary). Results will vary due to round-robin distribution.

> 💡 **Promoting the Canary:** Once validated, promote by scaling stable to use the new image and scaling canary to 0, or scale canary up and stable down gradually. For precise traffic splitting, a service mesh like Istio is needed.

---

## Step 8: Pod Disruption Budgets

### Create a Pod Disruption Budget

Create a PDB that ensures minimum availability during disruptions. Save as `pdb.yaml`:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: { name: webapp-pdb, namespace: deploy-lab-$STUDENT_NAME }
spec:
  minAvailable: 2          # At least 2 pods must remain available
  selector:
    matchLabels: { app: webapp }
```

```bash
# Apply the PDB
kubectl apply -f pdb.yaml

# Inspect the PDB
kubectl get pdb -n deploy-lab-$STUDENT_NAME
kubectl describe pdb webapp-pdb -n deploy-lab-$STUDENT_NAME
```

> ✅ **Expected Output:** PDB shows `ALLOWED-DISRUPTIONS: 0` (2 replicas - 2 minAvailable = 0 allowed disruptions).

> 💡 **Key Concept:** `minAvailable` specifies the minimum number of pods that must remain available. `maxUnavailable` specifies the maximum number that can be down at once. Both achieve similar results from different perspectives.

### Test the PDB with Node Drain

Simulate a voluntary disruption by draining a node:

```bash
# Identify which nodes our pods are running on
kubectl get pods -n deploy-lab-$STUDENT_NAME -l app=webapp -o wide

# Attempt to drain a node (use one that hosts webapp pods)
# The PDB will prevent draining if it would violate minAvailable
kubectl drain <NODE_NAME> --ignore-daemonsets \
  --delete-emptydir-data --dry-run=client

# Observe the PDB status during operations
kubectl get pdb webapp-pdb -n deploy-lab-$STUDENT_NAME -w
```

> ⚠️ **Shared Cluster Warning:** NEVER run `kubectl drain` without `--dry-run=client` in a shared cluster. A real drain would evict all students' workloads from the node.

> 💡 **PDB Use Cases:**
> - **Cluster upgrades** -- ensures availability during node rolling updates
> - **Cluster autoscaler** -- prevents scaling down nodes that would violate the budget
> - **Maintenance windows** -- safe node cordoning and draining
>
> PDBs only protect against **voluntary** disruptions. Involuntary disruptions like node crashes, OOM kills, or hardware failures are not governed by PDBs.

---

## Step 9: Configure Progress Deadline

### Detect Stuck Rollouts

Configure a progress deadline and trigger a stuck rollout:

```bash
# Set a short progress deadline (60 seconds) for testing
kubectl patch deployment webapp -n deploy-lab-$STUDENT_NAME \
  -p '{"spec":{"progressDeadlineSeconds":60}}'

# Trigger a rollout with a non-existent image (simulates failure)
kubectl set image deployment/webapp nginx=nginx:nonexistent-tag \
  -n deploy-lab-$STUDENT_NAME

# Watch the rollout (it will eventually fail)
kubectl rollout status deployment/webapp -n deploy-lab-$STUDENT_NAME --timeout=90s
```

> ✅ **Expected Output:** After 60 seconds, the rollout status will report:
> ```
> error: deployment "webapp" exceeded its progress deadline
> ```

> 📝 **Note:** The default `progressDeadlineSeconds` is 600 (10 minutes). We set it to 60 for faster demonstration. In production, choose a value that gives your containers enough time to start but detects genuine failures quickly.

### Inspect and Recover from Stuck Rollout

Examine the deployment conditions and recover:

```bash
# Check the deployment conditions
kubectl get deployment webapp -n deploy-lab-$STUDENT_NAME \
  -o jsonpath='{.status.conditions[*].message}' | tr ',' '\n'

# View the failing pods
kubectl get pods -n deploy-lab-$STUDENT_NAME -l app=webapp

# Rollback to the last working version
kubectl rollout undo deployment/webapp -n deploy-lab-$STUDENT_NAME

# Verify recovery
kubectl rollout status deployment/webapp -n deploy-lab-$STUDENT_NAME
kubectl get pods -n deploy-lab-$STUDENT_NAME -l app=webapp
```

> ✅ **Checkpoint:** After the rollback, all pods should be Running and Ready. The deployment condition should show `Available: True`.

> 💡 **Key Concept:** When the deadline is exceeded, the `Progressing` condition reason changes to `ProgressDeadlineExceeded`. This can be used for alerting in monitoring systems.

---

## Step 10: Clean Up

Remove all resources created during this lab:

```bash
# Delete the entire namespace (removes all resources within it)
kubectl delete namespace deploy-lab-$STUDENT_NAME

# Verify cleanup
kubectl get namespace deploy-lab-$STUDENT_NAME
```

> ✅ **Expected Output:**
> ```
> namespace "deploy-lab-$STUDENT_NAME" deleted
> Error from server (NotFound): namespaces "deploy-lab-$STUDENT_NAME" not found
> ```

> ⚠️ **Note:** If you drained a node earlier (without `--dry-run`), remember to uncordon it:
> ```bash
> kubectl uncordon <NODE_NAME>
> ```

---

## Summary & Strategy Comparison

| Strategy | Downtime | Resource Cost | Rollback Speed | Risk |
|---|---|---|---|---|
| **Rolling Update** | None | Low (+maxSurge) | Minutes | Medium |
| **Blue-Green** | None | High (2x) | Instant | Low |
| **Canary** | None | Medium (+canary) | Fast | Low |

> 💡 **Key Takeaway:** Choose your strategy based on your risk tolerance, resource budget, and the criticality of the workload. Many organizations use rolling updates by default and canary or blue-green for critical services. Service meshes like Istio enable more sophisticated traffic management for canary deployments with weighted routing instead of replica-based splitting.

---

## Key Takeaways

- **Rolling Updates** -- built-in, gradual replacement with `maxSurge`/`maxUnavailable` control
- **Blue-Green** -- instant traffic switch via service selector, requires double resources
- **Canary** -- gradual traffic shift using replica ratios, validates new versions with real traffic
- **Pod Disruption Budgets** -- protects application availability during voluntary disruptions
- **Progress Deadline** -- detects stuck rollouts automatically
