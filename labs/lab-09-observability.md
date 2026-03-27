# Lab 9: Observability
### Monitoring, Logging, and Debugging Kubernetes Workloads
**Intermediate Kubernetes — Module 9 of 13**

---

## Lab Overview

### What You'll Learn

- Container log collection and analysis
- Prometheus metrics and PromQL queries
- Grafana dashboards for visualization
- Custom alerting rules

### Lab Details

- **Duration:** ~45 minutes
- **Difficulty:** Intermediate
- **Prerequisites:** Labs 1-8

> ⚠️ **Note:** Some steps require metrics-server. Verify it is running before you begin.

---

## Environment Setup

Set your student identifier (use your first name or assigned number):

```bash
# Set your unique student name
export STUDENT_NAME=<your-name>
echo "Student: $STUDENT_NAME"
```

> ⚠️ **Important:** This shared cluster is used by all 22 students. Your `STUDENT_NAME` ensures your resources don't conflict with others.

---

## Step 1: Explore Container Logs with kubectl

### Set Up the Lab Namespace

Create a dedicated namespace for this lab:

```bash
# Create the lab namespace
kubectl create namespace obs-lab-$STUDENT_NAME

# Set as the current context
kubectl config set-context --current --namespace=obs-lab-$STUDENT_NAME
```

> ✅ **Expected Output:** `namespace/obs-lab-$STUDENT_NAME created` and `Context modified.`

### Deploy a Simple Pod for Log Exploration

```bash
# Deploy a pod that generates log output
kubectl run log-generator --image=busybox \
  --restart=Never -- \
  sh -c 'i=0; while true; do
    echo "$(date +%Y-%m-%dT%H:%M:%S) INFO  request_id=$i \
      status=200 path=/api/health duration=12ms";
    echo "$(date +%Y-%m-%dT%H:%M:%S) DEBUG request_id=$i cache_hit=true";
    if [ $((i % 10)) -eq 0 ]; then
      echo "$(date +%Y-%m-%dT%H:%M:%S) WARN  request_id=$i \
        high_latency=true duration=1500ms";
    fi;
    i=$((i+1)); sleep 2;
  done'
```

Wait for the pod to be running:

```bash
kubectl wait --for=condition=Ready pod/log-generator --timeout=30s
```

> 📝 **Note:** This creates a pod that produces structured log output at different levels. Every 10th entry includes a WARN line to simulate latency spikes.

### Explore kubectl logs Flags

```bash
# View last 20 lines of logs
kubectl logs log-generator --tail=20

# Follow logs in real time (Ctrl+C to stop)
kubectl logs log-generator -f

# View logs from the last 5 minutes
kubectl logs log-generator --since=5m

# View logs with timestamps
kubectl logs log-generator --timestamps
```

> 💡 **Key Flags:**
> - `-f` — Follow (stream) logs in real time
> - `--previous` — Show logs from a previous container instance
> - `-c <name>` — Select a specific container in multi-container pods
> - `--tail=N` — Show only the last N lines
> - `--since=duration` — Show logs newer than a relative duration

### Multi-Container Pod Logs

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: { name: multi-container-app, namespace: obs-lab-$STUDENT_NAME }
spec:
  containers:
  - name: app
    image: busybox
    command: ['sh', '-c',
      'while true; do echo "APP: req"; sleep 3; done']
  - name: sidecar
    image: busybox
    command: ['sh', '-c',
      'while true; do echo "SIDECAR: metrics"; sleep 5; done']
EOF
```

View logs from specific containers:

```bash
# View logs from a specific container
kubectl logs multi-container-app -c app
kubectl logs multi-container-app -c sidecar

# View logs from ALL containers
kubectl logs multi-container-app --all-containers=true
```

> 📝 **Note:** Multi-container pods are common with sidecar patterns. Being able to target specific container logs is essential.

---

## Step 2: Structured JSON Logging

### Deploy an App with JSON Logs

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: { name: json-logger, namespace: obs-lab-$STUDENT_NAME }
spec:
  replicas: 2
  selector:
    matchLabels: { app: json-logger }
  template:
    metadata: { labels: { app: json-logger } }
    spec:
      containers:
      - name: logger
        image: busybox
        command: ['sh', '-c', 'i=0; while true; do
          printf "{\"timestamp\":\"%s\",\"level\":\"info\",
          \"service\":\"order-api\",\"request_id\":\"%d\",
          \"status\":200}\n"
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$i";
          sleep 1; i=$((i+1)); done']
EOF
```

> ✅ **Expected:** Deployment creates 2 replicas producing structured JSON log lines.

> 💡 **Key Concept:** JSON logging is the gold standard for production because it enables automated parsing, filtering, and aggregation. Tools like Fluentd, Fluent Bit, and Loki can ingest these directly.

### View and Filter JSON Logs

```bash
# View logs from all pods in the deployment
kubectl logs deployment/json-logger --all-containers=true --tail=5

# Follow logs from the deployment
kubectl logs deployment/json-logger -f --max-log-requests=5

# Use label selector to get logs from specific pods
kubectl logs -l app=json-logger --tail=10
```

> 💡 **Tip:** You can pipe JSON logs through `jq` for local filtering:
> ```bash
> kubectl logs -l app=json-logger --tail=20 | jq 'select(.status != 200)'
> ```
> The label selector approach is powerful because it works regardless of how many pod replicas exist.

---

## Step 3: Log Patterns and Best Practices

### Good Practices

- Structured JSON format
- Log to stdout/stderr
- Use consistent log levels
- Include correlation IDs and timestamps

### Anti-Patterns

- Writing logs to files inside containers
- Logging sensitive data (tokens, passwords)
- Excessive DEBUG logging in production

> 💡 **Key Concept:** Kubernetes captures stdout and stderr from containers. Writing to files inside the container bypasses the kubelet log collection pipeline entirely.

---

## Step 4: Examine Metrics Server Data

### Verify Metrics Server

```bash
# Check if metrics-server is running
kubectl get deployment metrics-server -n kube-system

# Verify the API is available
kubectl get apiservice v1beta1.metrics.k8s.io
```

> ✅ **Expected Output:**
> ```
> NAME             READY   UP-TO-DATE   AVAILABLE
> metrics-server   1/1     1            1
> ```

> ⚠️ **If Not Installed:** Install with:
> ```bash
> kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
> ```

> 💡 **Key Concept:** Metrics Server collects resource metrics from kubelets and exposes them via the Kubernetes Metrics API. It refreshes every 15 seconds by default.

### kubectl top: Node and Pod Metrics

```bash
kubectl top nodes

kubectl top pods

kubectl top pods -A

kubectl top pods --sort-by=cpu

kubectl top pods --sort-by=memory

kubectl top pods --containers
```

> ✅ **Sample Output:**
> ```
> NAME              CPU(cores)   MEMORY(bytes)
> ip-10-0-1-100     250m         1824Mi
> ip-10-0-2-101     180m         1456Mi
> ```

> 💡 **Tip:** `kubectl top` is the quickest way to spot resource pressure. The `--containers` flag is particularly useful for identifying which container in a multi-container pod is consuming the most resources.

### Deploy a Resource-Intensive Workload

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: { name: stress-test, namespace: obs-lab-$STUDENT_NAME }
spec:
  replicas: 2
  selector:
    matchLabels: { app: stress-test }
  template:
    metadata: { labels: { app: stress-test } }
    spec:
      containers:
      - name: stress
        image: busybox
        command: ['sh', '-c', 'while true; do dd if=/dev/urandom
          bs=1024 count=1024 of=/dev/null 2>/dev/null; done']
EOF
```

Wait 30 seconds, then observe resource consumption:

```bash
sleep 30
kubectl top pods -l app=stress-test --containers
```

> 📝 **Note:** This deployment creates CPU load so you can see real resource consumption in `kubectl top` and later in Prometheus/Grafana.

---

## Checkpoint: Logs and Metrics Basics

Verify your progress before continuing:

> ✅ **Checkpoint — confirm each item:**
> 1. You can view logs with `kubectl logs` using `-f`, `--tail`, and `--since`
> 2. You can target specific containers with `-c` in multi-container pods
> 3. You understand structured JSON logging patterns
> 4. `kubectl top nodes` and `kubectl top pods` return data

---

## Step 5: Deploy the Prometheus Stack

### Verify kube-prometheus-stack

The monitoring stack (Prometheus, Grafana, Alertmanager) has been pre-installed on the cluster by the instructor. Verify it is running:

```bash
# Prometheus stack is pre-installed by the instructor
# Verify it is running:
kubectl get pods -n monitoring
kubectl get svc -n monitoring
```

> ⚠️ **Important:** The monitoring stack has been pre-installed on the cluster. Do not reinstall it.

### Verify the Prometheus Stack

```bash
# Check all pods in the monitoring namespace
kubectl get pods -n monitoring

# Check the services
kubectl get svc -n monitoring
```

> ✅ **Expected Pods:**
> - `prometheus-monitoring-kube-prometheus-prometheus-0`
> - `monitoring-grafana-*`
> - `alertmanager-monitoring-kube-prometheus-alertmanager-0`
> - `monitoring-kube-state-metrics-*`
> - `monitoring-prometheus-node-exporter-*`

> 💡 **Key Concept:** The stack deploys many components. `kube-state-metrics` generates metrics about Kubernetes objects, while `node-exporter` provides host-level metrics.

---

## Step 6: Query Prometheus Metrics

### Access the Prometheus UI

```bash
# Port-forward to Prometheus
kubectl port-forward -n monitoring \
  svc/monitoring-kube-prometheus-prometheus 9090:9090 &

echo "Prometheus UI: http://localhost:9090"
```

> 💡 **Tip:** Open [http://localhost:9090](http://localhost:9090) in your browser. Navigate to **Status → Targets** to see all scrape targets. Green means healthy; red indicates a scrape failure that needs investigation.

### Run PromQL Queries

Navigate to the **Graph** tab and run these queries:

```promql
# Total CPU usage per node
sum(rate(node_cpu_seconds_total{mode!="idle"}[5m])) by (instance)

# Memory usage percentage per node
100 * (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))

# Pod CPU usage in the obs-lab-$STUDENT_NAME namespace
sum(rate(container_cpu_usage_seconds_total{
  namespace="obs-lab-$STUDENT_NAME"
}[5m])) by (pod)

# Container restart count
sum(kube_pod_container_status_restarts_total) by (namespace, pod)
```

> 💡 **Key PromQL Concepts:**
> - `rate()` — Per-second rate of increase for counters
> - `sum() by (label)` — Aggregate and group results
> - `[5m]` — Range vector selector (lookback window)
>
> Switch between the **Console** and **Graph** views to see both raw numbers and time-series visualizations. The `rate` function is essential because CPU counters are cumulative.

### Useful Cluster Queries

```promql
# Pod count per namespace
count(kube_pod_info) by (namespace)

# Pods in CrashLoopBackOff
kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}

# Deployment availability ratio
kube_deployment_status_replicas_available
  / kube_deployment_spec_replicas

# Top 5 memory consumers
topk(5, container_memory_working_set_bytes{
  container!="", container!="POD"
})
```

> 💡 **Key Point:** PromQL queries form the foundation of both dashboards and alerting rules. Master these patterns and you can monitor any aspect of your cluster.

---

## Step 7: Explore Grafana Dashboards

### Access Grafana

```bash
# Port-forward to Grafana
kubectl port-forward -n monitoring \
  svc/monitoring-grafana 3000:80 &

echo "Grafana UI: http://localhost:3000"
echo "Username: admin"
echo "Password: admin123"
```

> 📝 **Login Credentials:**
> - **Username:** `admin`
> - **Password:** `admin123`

### Navigate Kubernetes Dashboards

In Grafana, go to **Dashboards → Browse** and explore:

**Cluster-Level Dashboards:**

- **Kubernetes / Compute Resources / Cluster** — Overall cluster CPU and memory
- **Kubernetes / Compute Resources / Node** — Per-node breakdown
- **Node Exporter / Nodes** — Host-level metrics

**Workload-Level Dashboards:**

- **Kubernetes / Compute Resources / Namespace (Pods)** — Pod metrics by namespace
- **Kubernetes / Compute Resources / Pod** — Individual pod details
- **Kubernetes / Networking / Pod** — Network I/O per pod

### Exercise: Investigate the stress-test Workload

1. Open **Kubernetes / Compute Resources / Namespace (Pods)**
2. Select namespace: `obs-lab-$STUDENT_NAME`
3. Locate the `stress-test` pods — note their CPU usage
4. Click on a pod name to drill into the per-pod dashboard
5. Observe CPU throttling: compare *usage* vs *limit*

> 💡 **Tip:** Grafana dashboards are interactive. Change the time range, hover over graphs for details, and use the namespace/pod dropdowns to filter. CPU throttling is visible when usage approaches the CPU limit — this is a common production issue where pods have their CPU cycles restricted by CFS quotas.

---

## Step 8: Create a Custom PrometheusRule Alert

### Define a High Restart Count Alert

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: pod-restart-alert-$STUDENT_NAME
  namespace: monitoring
  labels: { release: monitoring }
spec:
  groups:
  - name: pod-restarts
    rules:
    - alert: HighPodRestartCount
      expr: increase(kube_pod_container_status_restarts_total[1h]) > 3
      for: 5m
      labels: { severity: warning }
      annotations:
        summary: >-
          Pod {{ $labels.pod }} restarted
          {{ $value }} times
    - alert: PodCrashLooping
      expr: rate(kube_pod_container_status_restarts_total[15m]) * 60 * 15 > 0
      labels: { severity: critical }
EOF
```

> 💡 **Tip:** The `labels.release` must match the Helm release name for the Prometheus operator to pick up this rule. The `for` clause prevents transient spikes from firing alerts.

### Verify the Alert Rule

```bash
# Check the PrometheusRule resource
kubectl get prometheusrules -n monitoring

# Verify in Prometheus UI: Status -> Rules
# Navigate to http://localhost:9090/rules
# Look for the "pod-restarts" group
```

> ✅ **Expected:** The `pod-restart-alert` rule appears in the Prometheus Rules page with state **inactive** (no pods are currently restarting excessively). Rules may take up to 60 seconds to be loaded by Prometheus after creation.

> ⚠️ **Troubleshooting:** If the rule does not appear, verify the `release: monitoring` label matches your Helm release name:
> ```bash
> helm list -n monitoring
> ```

---

## Step 9: CloudWatch Container Insights (Optional)

### Check if Enabled

```bash
# Check for CloudWatch agent
kubectl get daemonset -n amazon-cloudwatch

# Or check for the ADOT collector
kubectl get pods -n amazon-cloudwatch
```

### What It Provides

- Automatic metrics collection
- Pre-built CloudWatch dashboards
- Container-level performance data
- Integration with CloudWatch Alarms
- Log group: `/aws/containerinsights/CLUSTER_NAME`

> 📝 **Note:** Container Insights complements Prometheus. Use Prometheus for detailed application metrics and CloudWatch for AWS-native alerting and centralized logging across accounts. If Container Insights is not enabled on your cluster, review the concepts and continue to the next step.

---

## Step 10: Debug a Failing Application

### Deploy a Broken Application

```yaml
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: { name: buggy-app, namespace: obs-lab-$STUDENT_NAME }
spec:
  replicas: 3
  selector:
    matchLabels: { app: buggy-app }
  template:
    metadata: { labels: { app: buggy-app } }
    spec:
      containers:
      - name: app
        image: busybox
        command: ['sh', '-c', 'echo "Starting app..."; sleep \
          $((RANDOM % 10 + 5)); echo "ERROR: Out of memory"; exit 137']
EOF
```

> 📝 **Note:** This app will crash and enter CrashLoopBackOff after a few iterations. That is intentional! The app simulates an OOM-like crash.

### Systematic Debugging: Step 1 — Events

```bash
# Check pod status
kubectl get pods -l app=buggy-app

# Check events for the namespace
kubectl get events --sort-by='.lastTimestamp' \
  -n obs-lab-$STUDENT_NAME | tail -20

# Describe a specific crashing pod
kubectl describe pod -l app=buggy-app | grep -A 10 "State:"
```

> ✅ **What to Look For:**
> - Pod status: `CrashLoopBackOff`
> - Last State: Terminated with exit code 137
> - Restart count increasing

> 💡 **Key Concept:** Exit code 137 means the process received SIGKILL, which typically indicates an OOM kill. The `describe` command shows both current and last state.

### Systematic Debugging: Step 2 — Logs

```bash
# View current container logs
kubectl logs -l app=buggy-app --tail=20

# View PREVIOUS container logs (from before the crash)
kubectl logs -l app=buggy-app --previous --tail=20
```

> ✅ **Expected Output:**
> ```
> Starting app...
> ERROR: Out of memory
> ```

> 💡 **Key Insight:** The `--previous` flag is essential when a container has crashed and restarted. Without it, you only see the current (possibly empty) container's logs. This is the most common debugging mistake: forgetting `--previous`. When a pod is in CrashLoopBackOff, the current container may have just started and have no useful logs yet.

### Systematic Debugging: Step 3 — Metrics

```bash
# Check resource consumption
kubectl top pods -l app=buggy-app
```

In Prometheus, run these queries:

```promql
# Query restart count
increase(kube_pod_container_status_restarts_total{
  namespace="obs-lab-$STUDENT_NAME", pod=~"buggy-app.*"
}[30m])

# Check OOMKilled status
kube_pod_container_status_last_terminated_reason{
  namespace="obs-lab-$STUDENT_NAME",
  reason="OOMKilled"
}
```

> 💡 **Debugging Flowchart:**
> 1. **Events** — What happened? When?
> 2. **Logs** — What did the app report?
> 3. **Metrics** — What was the resource state?
> 4. **Describe** — What are the pod's current conditions?
>
> This systematic approach should become second nature and covers 90% of production debugging scenarios.

---

## Step 11: Clean Up

```bash
# Delete the lab namespace (removes all lab workloads)
kubectl delete namespace obs-lab-$STUDENT_NAME

# Kill port-forward processes
pkill -f "port-forward.*9090" 2>/dev/null
pkill -f "port-forward.*3000" 2>/dev/null

# OPTIONAL: Remove the Prometheus stack
# (Keep it if you plan to use it in later labs)
# helm uninstall monitoring -n monitoring
# kubectl delete namespace monitoring
```

> ✅ **Verify Cleanup:**
> ```bash
> kubectl get namespace obs-lab-$STUDENT_NAME
> ```
> Expected: `Error from server (NotFound): namespaces "obs-lab-$STUDENT_NAME" not found`

> 📝 **Recommendation:** Keep the monitoring namespace and Prometheus stack installed — it will be useful in subsequent labs for observing workload behavior.

---

## Step 12: Summary and Reference

### Observability Tools Reference

| Tool | Purpose | Key Command / URL |
|------|---------|-------------------|
| **kubectl logs** | Container log access | `kubectl logs -f --previous -c <container>` |
| **kubectl top** | Real-time resource usage | `kubectl top pods --sort-by=cpu` |
| **kubectl events** | Cluster event stream | `kubectl get events --sort-by='.lastTimestamp'` |
| **Prometheus** | Metrics collection and querying | `localhost:9090` + PromQL |
| **Grafana** | Metrics visualization | `localhost:3000` |
| **PrometheusRule** | Custom alerting | CRD: `monitoring.coreos.com/v1` |

### Key Takeaways

- **Logging:** Always log to stdout/stderr in structured JSON format; use `--previous` for crashed containers
- **Metrics:** Metrics Server powers `kubectl top` and HPA; Prometheus provides deep metric collection
- **PromQL:** Master `rate()`, `sum() by`, and range vectors for effective monitoring
- **Grafana:** Pre-built dashboards provide immediate cluster visibility
- **Alerting:** PrometheusRule CRDs define alerting conditions evaluated by Prometheus
- **Debugging:** Follow the systematic approach: Events → Logs → Metrics → Describe

---

**Lab 9 Complete!** You now have hands-on experience with Kubernetes observability.

**Next:** Lab 10 — Health Checks and Probes
