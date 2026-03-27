# Lab 10: Health Checks and Probes
### Liveness, Readiness, and Startup Probes for Resilient Workloads
**Intermediate Kubernetes — Module 10 of 13**

---

## Lab Overview

### What You'll Learn

- HTTP, TCP, and exec liveness probes
- Readiness probes and endpoint management
- Startup probes for slow-starting apps
- Graceful shutdown and Pod Disruption Budgets

### Lab Details

- **Duration:** ~40 minutes
- **Difficulty:** Intermediate
- **Prerequisites:** Labs 1–9

> 💡 **Context:** Probes tie directly into the observability skills from Lab 9 — they generate events and metrics you can monitor.

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

## Three Types of Probes

| Probe | Question It Answers | On Failure |
|-------|-------------------|------------|
| 💚 **Liveness** | Is the container **alive**? | Kubernetes **restarts** the container |
| 💙 **Readiness** | Can it **serve traffic**? | Removed from **Service endpoints** |
| 💛 **Startup** | Has it **finished starting**? | Container is **killed** (liveness/readiness paused until success) |

> 📝 **Key Concept:** Liveness and readiness probes are disabled until the startup probe succeeds. This prevents premature kills during slow initialization.

---

## Step 1: Deploy an App Without Probes

### Set Up the Lab Namespace

```bash
# Create the lab namespace
kubectl create namespace probes-lab-$STUDENT_NAME

# Set as the current context
kubectl config set-context --current --namespace=probes-lab-$STUDENT_NAME
```

### Deploy App Without Probes

```yaml
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: no-probes-app
  namespace: probes-lab-$STUDENT_NAME
spec:
  replicas: 2
  selector:
    matchLabels: { app: no-probes-app }
  template:
    metadata:
      labels: { app: no-probes-app }
    spec:
      containers:
      - name: server
        image: nginx:1.25
        ports:
        - containerPort: 80
---
EOF
```

### Simulate a Failure

```bash
# Verify the app is running and serving traffic
kubectl get pods -l app=no-probes-app
curl_pod=$(kubectl get pod -l app=no-probes-app -o \
  jsonpath='{.items[0].metadata.name}')

# Simulate nginx becoming unresponsive (delete the config)
kubectl exec $curl_pod -- sh -c "rm \
  /etc/nginx/conf.d/default.conf && nginx -s reload"

# Try to access the service — it will fail but the pod stays "Running"
kubectl exec $curl_pod -- curl -s -o /dev/null -w "%{http_code}" localhost:80
```

> ⚠️ **Problem:** The pod shows `Running` and `1/1 Ready` even though it is returning errors. Kubernetes has no way to detect this failure without probes!

> 📝 **Key Insight:** Without probes, a pod remains in the Service endpoint list even when it cannot serve traffic, causing client-facing errors.

---

## Step 2: Add an HTTP Liveness Probe

### Deploy with Liveness Probe

```yaml
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: { name: liveness-http, namespace: probes-lab-$STUDENT_NAME }
spec:
  replicas: 2
  selector:
    matchLabels: { app: liveness-http }
  template:
    metadata: { labels: { app: liveness-http } }
    spec:
      containers:
      - name: server
        image: nginx:1.25
        ports: [{containerPort: 80}]
        livenessProbe:
          httpGet: { path: /, port: 80 }
          initialDelaySeconds: 5
          periodSeconds: 10
EOF
```

> 💡 **Probe parameters:** Defaults are `failureThreshold: 3`, `timeoutSeconds: 1`, `periodSeconds: 10`. Any HTTP status 200-399 counts as success.

### Test the Liveness Probe

```bash
# Get a pod name
LIVE_POD=$(kubectl get pod -l app=liveness-http \
  -o jsonpath='{.items[0].metadata.name}')

# Make the app unhealthy by deleting the index page
kubectl exec $LIVE_POD -- rm /usr/share/nginx/html/index.html

# Watch the pod — it will be restarted after ~30 seconds
# (3 failures x 10 second period)
kubectl get pods -l app=liveness-http -w
```

> ✅ **Expected Behavior:**
> ```
> NAME                    READY   STATUS    RESTARTS
> liveness-http-xxx       1/1     Running   0
> liveness-http-xxx       1/1     Running   1        ← restarted!
> ```

Then check the events to see probe failure details:

```bash
# Check the events to see probe failure details
kubectl describe pod $LIVE_POD | grep -A 5 "Liveness"
```

> 💡 The restart count increments because Kubernetes detected the liveness failure and killed the container. After restart, nginx comes back with the default index page intact.

---

## Step 3: Add a Readiness Probe

### Deploy with Readiness Probe

```yaml
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: readiness-app
  namespace: probes-lab-$STUDENT_NAME
spec:
  replicas: 3
  selector:
    matchLabels: { app: readiness-app }
  template:
    metadata:
      labels: { app: readiness-app }
    spec:
      containers:
      - name: server
        image: nginx:1.25
        ports: [{containerPort: 80}]
        readinessProbe:
          httpGet: { path: /ready, port: 80 }
          initialDelaySeconds: 3
          periodSeconds: 5
          failureThreshold: 2
          successThreshold: 2
        livenessProbe:
          httpGet: { path: /, port: 80 }
---
apiVersion: v1
kind: Service
metadata:
  name: readiness-svc
  namespace: probes-lab-$STUDENT_NAME
spec:
  selector: { app: readiness-app }
  ports:
  - port: 80
EOF
```

> 💡 Note the readiness probe uses a different path (`/ready`) than the liveness probe (`/`). The `successThreshold` of 2 means the pod must pass two consecutive checks before being added back to the endpoint list.

### Configure the Ready Endpoint

```bash
# Create the /ready endpoint on all pods
for pod in $(kubectl get pods -l app=readiness-app \
  -o jsonpath='{.items[*].metadata.name}'); do
  kubectl exec $pod -- sh -c \
    "mkdir -p /usr/share/nginx/html && echo 'OK' > /usr/share/nginx/html/ready"
done

# Verify pods become ready
kubectl get pods -l app=readiness-app

# Verify endpoints are populated
kubectl get endpoints readiness-svc
```

> ✅ **Expected:** All 3 pods show `1/1 Ready` and the endpoints list shows 3 IP addresses.

### Test Readiness Failure

```bash
# Make one pod unready by removing the /ready file
READY_POD=$(kubectl get pod -l app=readiness-app \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec $READY_POD -- rm /usr/share/nginx/html/ready

# Watch the pod become NotReady
kubectl get pods -l app=readiness-app -w

# Check endpoints — the unready pod is REMOVED
kubectl get endpoints readiness-svc
```

> ✅ **Expected:**
> ```
> readiness-app-xxx   0/1   Running   0    ← Not ready, but NOT restarted
> ```
> Endpoints now show only 2 IP addresses instead of 3.

### Restore Readiness

```bash
# Restore the /ready endpoint
kubectl exec $READY_POD -- sh -c \
  "echo 'OK' > /usr/share/nginx/html/ready"

# Watch it become Ready again (requires 2 successes due to successThreshold)
kubectl get pods -l app=readiness-app -w

# Verify endpoints are restored
kubectl get endpoints readiness-svc
```

> ✅ **Expected:** After ~10 seconds (2 successful checks at 5s intervals), the pod returns to `1/1 Ready` and its IP reappears in the endpoints list.

> 💡 The `successThreshold` of 2 provides hysteresis — it prevents a pod from flapping between ready and not-ready too quickly.

---

## Step 4: Startup Probes for Slow-Starting Apps

### Deploy with a Startup Probe

```yaml
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: slow-start-app
  namespace: probes-lab-$STUDENT_NAME
spec:
  replicas: 1
  selector:
    matchLabels: { app: slow-start-app }
  template:
    metadata:
      labels: { app: slow-start-app }
    spec:
      containers:
      - name: server
        image: nginx:1.25
        ports: [{containerPort: 80}]
        command: ['sh', '-c', 'sleep 30; nginx -g "daemon off;"']
        startupProbe:
          httpGet: { path: /, port: 80 }
          failureThreshold: 12
          periodSeconds: 5
        livenessProbe:
          httpGet: { path: /, port: 80 }
        readinessProbe:
          httpGet: { path: /, port: 80 }
EOF
```

> 💡 The startup probe allows up to 60 seconds (12 failures x 5 seconds) for the application to start. During this time, liveness and readiness probes are disabled.

### Observe Startup Behavior

```bash
# Watch the pod start up
kubectl get pods -l app=slow-start-app -w

# In another terminal, watch events
kubectl get events --field-selector reason=Unhealthy \
  -n probes-lab-$STUDENT_NAME -w
```

> ✅ **Expected Timeline:**
> - **0–5s:** Container starting, startup probe not yet active
> - **5–30s:** Startup probe fails (app still initializing) — this is OK
> - **~35s:** App becomes responsive, startup probe passes
> - **~35s+:** Liveness and readiness probes begin

> ⚠️ **Without a Startup Probe:** The liveness probe would kill the container after 3 failures (30 seconds), before the app even finishes initializing!

---

## Step 5: Configure Probe Parameters

### Probe Parameter Reference

| Parameter | Default | Description |
|-----------|---------|-------------|
| `initialDelaySeconds` | 0 | Seconds to wait before first probe |
| `periodSeconds` | 10 | How often to perform the probe |
| `timeoutSeconds` | 1 | Seconds before probe times out |
| `failureThreshold` | 3 | Consecutive failures to declare unhealthy |
| `successThreshold` | 1 | Consecutive successes to declare healthy |

> 📝 **Detection Time Formula:** Time to detect failure = `periodSeconds x failureThreshold`. With defaults: 10 x 3 = **30 seconds**.

> 💡 `successThreshold` must be 1 for liveness and startup probes. It can be higher for readiness probes to prevent flapping.

### Tuning Exercise

```yaml
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tuned-probes
  namespace: probes-lab-$STUDENT_NAME
spec:
  replicas: 1
  selector:
    matchLabels: { app: tuned-probes }
  template:
    metadata:
      labels: { app: tuned-probes }
    spec:
      containers:
      - name: server
        image: nginx:1.25
        ports: [{containerPort: 80}]
        livenessProbe:
          httpGet: { path: /, port: 80 }
          initialDelaySeconds: 10
          periodSeconds: 5       # Faster than default 10s
          failureThreshold: 2    # Fewer failures needed
        readinessProbe:
          httpGet: { path: /, port: 80 }
          initialDelaySeconds: 5
          periodSeconds: 3
          failureThreshold: 2
          successThreshold: 3    # Must pass 3x to be ready
EOF
```

> 💡 **Analysis:**
> - Liveness detection time: 5s x 2 = **10 seconds**
> - Readiness detection time: 3s x 2 = **6 seconds**
> - Readiness recovery time: 3s x 3 = **9 seconds** (higher successThreshold)
>
> Faster probes catch failures quicker but increase kubelet overhead. For most workloads, checking every 5–10 seconds is sufficient.

---

## Step 6: TCP Socket Liveness Probe

### Deploy with TCP Probe

```yaml
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tcp-probe-app
  namespace: probes-lab-$STUDENT_NAME
spec:
  replicas: 1
  selector:
    matchLabels: { app: tcp-probe-app }
  template:
    metadata:
      labels: { app: tcp-probe-app }
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        ports: [{containerPort: 6379}]
        livenessProbe:
          tcpSocket: { port: 6379 }
          initialDelaySeconds: 5
          periodSeconds: 10
        readinessProbe:
          tcpSocket: { port: 6379 }
          initialDelaySeconds: 3
EOF
```

> 💡 **When to Use TCP Probes:** Use for non-HTTP services (Redis, PostgreSQL, MQTT) where you only need to verify the port is accepting connections.

### Test the TCP Probe

```bash
# Verify the pod is running and ready
kubectl get pods -l app=tcp-probe-app

# Verify Redis is responding
TCP_POD=$(kubectl get pod -l app=tcp-probe-app \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec $TCP_POD -- redis-cli ping
```

> ✅ **Expected Output:** `PONG`

```bash
# View probe-related events
kubectl describe pod $TCP_POD | grep -A 3 "Liveness\|Readiness"
```

> 💡 For deeper health checking of Redis, you would use an exec probe with `redis-cli ping` instead of a TCP probe.

---

## Step 7: Exec Command Liveness Probe

### Deploy with Exec Probe (File-Based Health Check)

```yaml
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: { name: exec-probe-app, namespace: probes-lab-$STUDENT_NAME }
spec:
  replicas: 1
  selector:
    matchLabels: { app: exec-probe-app }
  template:
    metadata: { labels: { app: exec-probe-app } }
    spec:
      containers:
      - name: app
        image: busybox
        command: ['sh', '-c', 'touch /tmp/healthy; while true; do \
          sleep 5; done']
        livenessProbe:
          exec: { command: [cat, /tmp/healthy] }
          initialDelaySeconds: 5
          periodSeconds: 5
EOF
```

> 💡 **How It Works:** The probe runs `cat /tmp/healthy` inside the container — exit code 0 = success, non-zero = failure. File-based health checks are a simple sentinel pattern.

### Test the Exec Probe

```bash
EXEC_POD=$(kubectl get pod -l app=exec-probe-app \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec $EXEC_POD -- cat /tmp/healthy
echo "Exit code: $?"

kubectl exec $EXEC_POD -- rm /tmp/healthy

kubectl get pods -l app=exec-probe-app -w
```

> ✅ **Expected:** The restart count increases after approximately 15–20 seconds. After restart, the container re-creates `/tmp/healthy` and becomes stable again.

> 💡 Exec probes are powerful because you can run any command. Common uses include checking if a lock file exists, verifying database connectivity with a CLI client, or running a custom health-check script.

---

## Step 8: Graceful Shutdown with preStop Hook

### Deploy with Graceful Shutdown Configuration

```yaml
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: graceful-app
  namespace: probes-lab-$STUDENT_NAME
spec:
  replicas: 2
  selector:
    matchLabels: { app: graceful-app }
  template:
    metadata:
      labels: { app: graceful-app }
    spec:
      terminationGracePeriodSeconds: 45
      containers:
      - name: server
        image: nginx:1.25
        ports: [{containerPort: 80}]
        lifecycle:
          preStop:
            exec:
              command: ['sh', '-c', 'sleep 10; nginx -s quit']
        livenessProbe:
          httpGet: { path: /, port: 80 }
        readinessProbe:
          httpGet: { path: /, port: 80 }
EOF
```

> 💡 The `preStop` hook runs BEFORE the SIGTERM signal. The `terminationGracePeriodSeconds` defines the maximum time for graceful shutdown (preStop + SIGTERM handling). After this period, SIGKILL is sent.

### Observe Graceful Shutdown

```bash
# Delete a pod and observe the shutdown process
GRACEFUL_POD=$(kubectl get pod -l app=graceful-app \
  -o jsonpath='{.items[0].metadata.name}')

# Watch events during deletion
kubectl get events -w --field-selector involvedObject.name=$GRACEFUL_POD &

# Delete the pod
kubectl delete pod $GRACEFUL_POD

# Note the time between the delete command and actual termination
```

> 📝 **Shutdown Sequence:** Pod is marked Terminating (removed from endpoints immediately), preStop hook executes, SIGTERM is sent, then SIGKILL after `terminationGracePeriodSeconds`. The pod should take ~10+ seconds to terminate due to the `sleep 10` in the preStop hook.

---

## Step 9: Clean Up

```bash
# Delete the lab namespace (removes all resources)
kubectl delete namespace probes-lab-$STUDENT_NAME

# Verify cleanup
kubectl get namespace probes-lab-$STUDENT_NAME
```

> ✅ **Expected:** `Error from server (NotFound): namespaces "probes-lab-<your-name>" not found`

---

## Key Takeaways

- **No Probes = No Protection:** Without probes, broken pods continue receiving traffic silently
- **Liveness:** Detects deadlocked or stuck containers and triggers restarts
- **Readiness:** Controls traffic routing — only healthy pods serve requests
- **Startup:** Protects slow-starting containers from premature liveness kills
- **Tuning:** Balance detection speed against probe overhead and false positives
- **Graceful Shutdown:** preStop hooks and `terminationGracePeriodSeconds` ensure clean termination
