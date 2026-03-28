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

> ⚠️ **Note:** Verify metrics-server is running before you begin.

---

## Environment Setup

```bash
export STUDENT_NAME=<your-name>
echo "Student: $STUDENT_NAME"
```

> ⚠️ **Important:** Your `STUDENT_NAME` ensures your resources don't conflict with other students on this shared cluster.

---

## Step 1: Explore Container Logs with kubectl

Create a namespace and deploy a log-generating pod:

```bash
kubectl create namespace obs-lab-$STUDENT_NAME
kubectl config set-context --current --namespace=obs-lab-$STUDENT_NAME
```

```bash
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

kubectl wait --for=condition=Ready pod/log-generator --timeout=30s
```

### Explore kubectl logs Flags

```bash
kubectl logs log-generator --tail=20
kubectl logs log-generator -f
kubectl logs log-generator --since=5m
kubectl logs log-generator --timestamps
```

> 💡 **Key Flags:** `-f` to follow, `--previous` for crashed containers, `-c <name>` for multi-container pods, `--tail=N` and `--since=duration` to filter.

### Multi-Container Pod Logs

```yaml
cat <<EOF | kubectl apply -f -
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

```bash
kubectl logs multi-container-app -c app
kubectl logs multi-container-app -c sidecar
kubectl logs multi-container-app --all-containers=true
```

---

## Step 2: Structured JSON Logging

```yaml
cat <<EOF | kubectl apply -f -
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

### View and Filter JSON Logs

```bash
kubectl logs deployment/json-logger --all-containers=true --tail=5
kubectl logs deployment/json-logger -f --max-log-requests=5
kubectl logs -l app=json-logger --tail=10
```

> 💡 **Tip:** Pipe JSON logs through `jq` for local filtering:
> ```bash
> kubectl logs -l app=json-logger --tail=20 | jq 'select(.status != 200)'
> ```

---

## Step 3: Examine Metrics Server Data

```bash
kubectl get deployment metrics-server -n kube-system
kubectl get apiservice v1beta1.metrics.k8s.io
```

> 💡 If not installed: `kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml`

### kubectl top: Node and Pod Metrics

```bash
kubectl top nodes
kubectl top pods
kubectl top pods --sort-by=cpu
kubectl top pods --sort-by=memory
kubectl top pods --containers
```

### Deploy a Resource-Intensive Workload

```yaml
cat <<EOF | kubectl apply -f -
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

```bash
sleep 30
kubectl top pods -l app=stress-test --containers
```

> ✅ **Checkpoint:** You can view logs with `-f`, `--tail`, `--since`, target containers with `-c`, and `kubectl top` returns data for nodes and pods.

---

## Step 4: Verify the Prometheus Stack

The monitoring stack (Prometheus, Grafana, Alertmanager) has been pre-installed. Verify it is running:

```bash
kubectl get pods -n monitoring
kubectl get svc -n monitoring
```

> ⚠️ **Important:** Do not reinstall the monitoring stack.

---

## Step 5: Query Prometheus Metrics

```bash
kubectl port-forward -n monitoring \
  svc/monitoring-kube-prometheus-prometheus 9090:9090 &

echo "Prometheus UI: http://localhost:9090"
```

### Run PromQL Queries

Navigate to the **Graph** tab and run these queries (replace `$STUDENT_NAME` with your actual name in the browser):

```promql
# Total CPU usage per node
sum(rate(node_cpu_seconds_total{mode!="idle"}[5m])) by (instance)

# Memory usage percentage per node
100 * (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))

# Pod CPU usage in your namespace
sum(rate(container_cpu_usage_seconds_total{
  namespace="obs-lab-$STUDENT_NAME"
}[5m])) by (pod)

# Container restart count
sum(kube_pod_container_status_restarts_total) by (namespace, pod)
```

### Useful Cluster Queries

```promql
# Pod count per namespace
count(kube_pod_info) by (namespace)

# Pods in CrashLoopBackOff
kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}

# Top 5 memory consumers
topk(5, container_memory_working_set_bytes{
  container!="", container!="POD"
})
```

---

## Step 6: Explore Grafana Dashboards

```bash
kubectl port-forward -n monitoring \
  svc/monitoring-grafana 3000:80 &

echo "Grafana UI: http://localhost:3000"
echo "Username: admin / Password: admin123"
```

In Grafana, go to **Dashboards > Browse** and explore:

- **Kubernetes / Compute Resources / Cluster** — Overall cluster CPU and memory
- **Kubernetes / Compute Resources / Namespace (Pods)** — Pod metrics by namespace
- **Kubernetes / Compute Resources / Pod** — Individual pod details

### Exercise: Investigate the stress-test Workload

1. Open **Kubernetes / Compute Resources / Namespace (Pods)**
2. Select namespace: `obs-lab-$STUDENT_NAME`
3. Locate the `stress-test` pods and note their CPU usage
4. Click a pod name to drill into the per-pod dashboard

---

## Step 7: Create a Custom PrometheusRule Alert

```yaml
cat <<EOF | kubectl apply -f -
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

> 💡 The `labels.release` must match the Helm release name for the Prometheus operator to pick up this rule.

```bash
kubectl get prometheusrules -n monitoring
# Verify in Prometheus UI: Status -> Rules -> look for "pod-restarts"
```

> ✅ **Checkpoint:** The `pod-restart-alert` rule appears in the Prometheus Rules page. Rules may take up to 60 seconds to load.

---

## Step 8: CloudWatch Container Insights (Optional)

```bash
kubectl get daemonset -n amazon-cloudwatch
kubectl get pods -n amazon-cloudwatch
```

> 📝 If not enabled on your cluster, continue to the next step.

---

## Step 9: Debug a Failing Application

```yaml
cat <<EOF | kubectl apply -f -
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

### Systematic Debugging

```bash
# Events
kubectl get pods -l app=buggy-app
kubectl get events --sort-by='.lastTimestamp' \
  -n obs-lab-$STUDENT_NAME | tail -20
kubectl describe pod -l app=buggy-app | grep -A 10 "State:"

# Logs (use --previous for crashed containers)
kubectl logs -l app=buggy-app --tail=20
kubectl logs -l app=buggy-app --previous --tail=20

# Metrics
kubectl top pods -l app=buggy-app
```

In Prometheus, query restart count and OOMKilled status:

```promql
increase(kube_pod_container_status_restarts_total{
  namespace="obs-lab-$STUDENT_NAME", pod=~"buggy-app.*"
}[30m])

kube_pod_container_status_last_terminated_reason{
  namespace="obs-lab-$STUDENT_NAME",
  reason="OOMKilled"
}
```

> ✅ **Checkpoint:** Exit code 137 = SIGKILL (typically OOM). The `--previous` flag shows logs from before the crash.

---

## Step 10: Clean Up

```bash
kubectl delete namespace obs-lab-$STUDENT_NAME
kubectl delete prometheusrule pod-restart-alert-$STUDENT_NAME -n monitoring --ignore-not-found
pkill -f "port-forward.*9090" 2>/dev/null
pkill -f "port-forward.*3000" 2>/dev/null
```

> 📝 Keep the monitoring namespace installed -- it will be useful in subsequent labs.

---

## Summary

- **Logging:** Log to stdout/stderr in structured JSON; use `--previous` for crashed containers
- **Metrics:** Metrics Server powers `kubectl top`; Prometheus provides deep metric collection
- **PromQL:** Master `rate()`, `sum() by`, and range vectors for effective monitoring
- **Grafana:** Pre-built dashboards provide immediate cluster visibility
- **Alerting:** PrometheusRule CRDs define alerting conditions
- **Debugging:** Follow Events > Logs > Metrics > Describe

---

**Lab 9 Complete!** Next: Lab 10 — Health Checks and Probes
