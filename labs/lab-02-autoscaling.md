# Lab 2: Configuring Autoscaling
### HPA, VPA, and Cluster Autoscaler in Practice
**Intermediate Kubernetes — Module 2 of 13**

---

## Lab Overview

### Objectives

- Verify metrics-server and configure a Horizontal Pod Autoscaler (HPA)
- Generate load and observe automatic scaling in real time
- Create an HPA with custom metrics using the v2 API
- Explore Vertical Pod Autoscaler (VPA) and Cluster Autoscaler behavior

### Prerequisites

- Completed Lab 1 with `kubectl` and cluster access configured
- metrics-server installed in the cluster

> ⏱ **Duration:** ~45 minutes

---

## Autoscaling in Kubernetes

Kubernetes provides three complementary autoscaling mechanisms:

| Autoscaler | What It Scales | How It Works |
|---|---|---|
| **HPA** (Horizontal Pod Autoscaler) | Number of **pods** | Scales based on CPU, memory, or custom metrics |
| **VPA** (Vertical Pod Autoscaler) | **Resource requests/limits** per container | Adjusts pod size based on observed usage |
| **Cluster Autoscaler** | Number of **nodes** | Adds/removes nodes when pods cannot be scheduled |

> 💡 **Key Point:** These three autoscalers work at different layers and can be used together. HPA adjusts pod count, VPA adjusts pod size, and Cluster Autoscaler adjusts infrastructure capacity.

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

## Step 1: Verify Metrics Server

HPA requires metrics-server to collect resource usage data.

```bash
# Check if metrics-server is running
kubectl get pods -n kube-system | grep metrics-server

# Verify the metrics API is available
kubectl get apiservices | grep metrics

# Test that metrics are being collected
kubectl top nodes
kubectl top pods -A
```

> ✅ **Expected Output:** The metrics-server pod should be `Running` with `1/1` ready. The apiservice `v1beta1.metrics.k8s.io` should show `True` in the AVAILABLE column. `kubectl top` should return CPU and memory data.

> ⚠️ **Troubleshooting:** If metrics-server is not installed, run:
> ```bash
> kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
> kubectl wait --for=condition=ready pod -l k8s-app=metrics-server -n kube-system --timeout=120s
> ```
> It may take 1-2 minutes for metrics to start populating after installation.

---

## Step 2: Deploy a CPU-Intensive Application

Create a namespace and deploy an application with resource requests.

```bash
# Create lab namespace
kubectl create namespace lab02-$STUDENT_NAME
kubectl config set-context --current --namespace=lab02-$STUDENT_NAME
```

Create the deployment manifest:

```yaml
# Save as php-apache-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: php-apache
  namespace: lab02-$STUDENT_NAME
spec:
  replicas: 1
  selector:
    matchLabels:
      app: php-apache
  template:
    metadata:
      labels:
        app: php-apache
    spec:
      containers:
      - name: php-apache
        image: registry.k8s.io/hpa-example
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 200m
            memory: 64Mi
          limits:
            cpu: 500m
            memory: 128Mi
```

Apply and expose the application:

```bash
# Apply the deployment
kubectl apply -f php-apache-deployment.yaml

# Expose it as a service
kubectl expose deployment php-apache --port=80 --target-port=80

# Verify everything is running
kubectl get all -n lab02-$STUDENT_NAME
```

> ✅ **Expected Output:** One pod in `Running` state, one deployment with `1/1` ready, and a ClusterIP service on port 80.

> 📝 **Important:** The `resources.requests.cpu: 200m` field is critical. HPA calculates utilization as `current_usage / request`. Without a CPU request, HPA cannot determine the scaling target percentage.

---

## Step 3: Create a Horizontal Pod Autoscaler

Create an HPA targeting 50% average CPU utilization:

```bash
# Create HPA using imperative command
kubectl autoscale deployment php-apache \
  --cpu-percent=50 \
  --min=1 \
  --max=10 \
  -n lab02-$STUDENT_NAME

# Examine the HPA
kubectl get hpa -n lab02-$STUDENT_NAME

# View detailed HPA information
kubectl describe hpa php-apache -n lab02-$STUDENT_NAME
```

> ✅ **Expected Output:** The HPA should show `TARGETS: <current>/50%`, `MINPODS: 1`, `MAXPODS: 10`, and `REPLICAS: 1`. The current value may show `<unknown>/50%` for the first 15-30 seconds while metrics are collected.

> ⚠️ **Common Mistake:** If TARGETS shows `<unknown>` for more than 60 seconds, check that metrics-server is running and that the deployment has CPU resource requests defined.

---

## Step 4: Generate Load

Run a load generator in a separate pod:

```bash
# Start a load generator pod (run in Terminal 1)
kubectl run load-generator \
  --image=busybox:1.36 \
  --restart=Never \
  -n lab02-$STUDENT_NAME \
  -- /bin/sh -c "while sleep 0.01; do wget -q -O- http://php-apache; done"
```

> ⚠️ **Important:** Open a **second terminal** for the next step. Keep the load generator running in this terminal. You will need to monitor the HPA from the second terminal.

> 💡 **How This Works:** The busybox pod sends continuous HTTP requests to the php-apache service. Each request triggers PHP computation, driving CPU usage above the 50% target threshold, which signals the HPA to scale up.

---

## Step 5: Observe Horizontal Scaling

In your **second terminal**, watch the HPA and pods respond:

```bash
# Watch HPA status (updates every 15 seconds)
kubectl get hpa php-apache -n lab02-$STUDENT_NAME --watch

# In yet another terminal, watch pods scale up
kubectl get pods -n lab02-$STUDENT_NAME --watch
```

> ✅ **Expected Output:** Within 1-3 minutes you should see:
> - TARGETS increasing above 50% (e.g., `250%/50%`)
> - REPLICAS increasing from 1 to multiple pods (up to 10)
> - New pods appearing in `Pending` then `Running` state

> 💡 **Key Point:** The HPA evaluates metrics every 15 seconds by default. It uses the formula: `desiredReplicas = ceil(currentReplicas * (currentMetric / targetMetric))`. Scaling up happens quickly, but scale-down has a default stabilization window of 5 minutes to prevent flapping.

---

## Step 6: Examine HPA Events and Status

Inspect the HPA decision-making process:

```bash
# Detailed HPA description with events
kubectl describe hpa php-apache -n lab02-$STUDENT_NAME

# View HPA in YAML format for full status
kubectl get hpa php-apache -n lab02-$STUDENT_NAME -o yaml
```

> 💡 **Key Fields in HPA Status:**
> - **Events** -- shows each scaling decision with reason and timestamp
> - **currentMetrics** -- actual resource utilization observed
> - **desiredReplicas** -- what HPA wants to scale to
> - **conditions** -- AbleToScale, ScalingActive, ScalingLimited

> ✅ **Checkpoint:** In the Events section, you should see messages like: `New size: X; reason: cpu resource utilization (percentage of request) above target`. This confirms HPA is actively scaling based on CPU metrics.

---

## Step 7: Stop Load and Observe Scale-Down

Stop the load generator and watch the HPA scale down:

```bash
# Delete the load generator pod
kubectl delete pod load-generator -n lab02-$STUDENT_NAME

# Watch the HPA scale down (this takes ~5 minutes)
kubectl get hpa php-apache -n lab02-$STUDENT_NAME --watch

# In another terminal, watch pods terminate
kubectl get pods -n lab02-$STUDENT_NAME --watch
```

> ✅ **Expected Output:** After approximately 5 minutes, you should see:
> - TARGETS dropping below 50% (eventually to `0%/50%`)
> - REPLICAS gradually decreasing back to `1`
> - Pods entering `Terminating` state

> 📝 **Why So Slow?** The default `--horizontal-pod-autoscaler-downscale-stabilization` window is 5 minutes. This prevents rapid scale-down/scale-up oscillation (thrashing) during variable load patterns.

---

## Step 8: HPA with Custom Metrics (v2 API)

Delete the existing HPA and create a more advanced one:

```bash
# Remove the existing HPA
kubectl delete hpa php-apache -n lab02-$STUDENT_NAME
```

Create the v2 HPA manifest:

```yaml
# Save as hpa-v2.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: php-apache-v2
  namespace: lab02-$STUDENT_NAME
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: php-apache
  minReplicas: 1
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
      - type: Percent
        value: 100
        periodSeconds: 15
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 50
        periodSeconds: 60
      selectPolicy: Max
```

Apply and examine the v2 HPA:

```bash
# Apply the v2 HPA
kubectl apply -f hpa-v2.yaml

# Examine the HPA
kubectl get hpa php-apache-v2 -n lab02-$STUDENT_NAME

# View the full spec
kubectl describe hpa php-apache-v2 -n lab02-$STUDENT_NAME
```

> ✅ **Expected Output:** The HPA should show two metrics targets: `cpu: <current>/50%` and `memory: <current>/80%`. The REFERENCE should point to `Deployment/php-apache`.

> 💡 **v2 API Advantages:**
> - **Multiple metrics** -- scale on CPU *and* memory simultaneously
> - **Scaling behavior** -- control scale-up/down speed and stabilization
> - **Custom metrics** -- scale on application-specific metrics (requests/sec, queue depth)
> - **External metrics** -- scale on metrics from outside the cluster (SQS queue length, etc.)

---

## Step 9: Vertical Pod Autoscaler (VPA)

First, check if VPA is available in your cluster:

```bash
# Check for VPA CRDs
kubectl get crd | grep verticalpodautoscaler

# Check for VPA components
kubectl get pods -n kube-system | grep vpa
```

> 📝 **Note:** VPA is an optional component. If the CRDs are not installed, review the manifest below as a reference but skip the apply step.

Create a VPA resource in `Off` mode (recommendation only):

```yaml
# Save as vpa.yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: php-apache-vpa
  namespace: lab02-$STUDENT_NAME
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: php-apache
  updatePolicy:
    updateMode: "Off"
  resourcePolicy:
    containerPolicies:
    - containerName: php-apache
      minAllowed:
        cpu: 100m
        memory: 50Mi
      maxAllowed:
        cpu: 1
        memory: 500Mi
      controlledResources: ["cpu", "memory"]
```

Examine VPA recommendations:

```bash
# Apply the VPA (only if CRDs are installed)
kubectl apply -f vpa.yaml

# Check VPA recommendations (may take a few minutes to populate)
kubectl describe vpa php-apache-vpa -n lab02-$STUDENT_NAME

# View recommendations in JSON
kubectl get vpa php-apache-vpa -n lab02-$STUDENT_NAME \
  -o jsonpath='{.status.recommendation}' | python3 -m json.tool
```

> ✅ **Expected Output:** The VPA status should show three recommendation levels:
> - **lowerBound** -- minimum recommended resources
> - **target** -- optimal recommended resources
> - **upperBound** -- maximum recommended resources

> ⚠️ **Warning:** Do not use VPA in `Auto` mode with HPA on the same CPU/memory metrics. VPA will resize pods while HPA tries to change pod count, creating conflicts. Use VPA for right-sizing resource requests, and HPA for scaling replicas.

---

## Step 10: Cluster Autoscaler Behavior

> ⚠️ **Instructor Demo:** In a shared cluster, only run this step when directed by the instructor. Creating 20 replicas per student would overwhelm the cluster.

Deploy a workload that requests more resources than currently available:

```yaml
# Save as inflate-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inflate
  namespace: lab02-$STUDENT_NAME
spec:
  replicas: 5
  selector:
    matchLabels:
      app: inflate
  template:
    metadata:
      labels:
        app: inflate
    spec:
      containers:
      - name: inflate
        image: registry.k8s.io/pause:3.9
        resources:
          requests:
            cpu: 250m
            memory: 256Mi
```

```bash
kubectl apply -f inflate-deployment.yaml
```

Monitor Cluster Autoscaler activity:

```bash
# Watch pods - some should be Pending if cluster is at capacity
kubectl get pods -n lab02-$STUDENT_NAME -l app=inflate --watch

# Check for Pending pods
kubectl get pods -n lab02-$STUDENT_NAME -l app=inflate --field-selector=status.phase=Pending

# Examine why pods are pending
kubectl describe pod <PENDING_POD_NAME> -n lab02-$STUDENT_NAME | grep -A 5 "Events:"

# Check Cluster Autoscaler logs (if available)
kubectl logs -n kube-system -l app=cluster-autoscaler --tail=50
```

> ✅ **Expected Output:** Some pods will show `Pending` status with events showing `FailedScheduling: 0/X nodes are available: insufficient cpu`. If Cluster Autoscaler is active, you may see new nodes joining within 2-5 minutes.

> 💡 **Cluster Autoscaler Logic:**
> - **Scale Up** -- triggered when pods are `Pending` due to insufficient resources
> - **Scale Down** -- triggered when nodes are underutilized for 10+ minutes
> - **EKS Integration** -- modifies the ASG desired count for the managed node group

---

## Step 11: Clean Up All Resources

Remove everything created during this lab:

```bash
# Reset namespace context
kubectl config set-context --current --namespace=default

# Delete the entire lab namespace
kubectl delete namespace lab02-$STUDENT_NAME

# Verify cleanup
kubectl get namespaces
kubectl get hpa -A | grep lab02-$STUDENT_NAME
```

> ✅ **Checkpoint:** The `lab02-$STUDENT_NAME` namespace should be gone. No HPA resources should reference `lab02-$STUDENT_NAME`. If Cluster Autoscaler added nodes, they will scale down automatically after the workloads are removed (this may take 10+ minutes).

> 📝 **Note:** Also delete any YAML files you created locally if you no longer need them, or keep them as reference material.

---

## Autoscaling Best Practices

| Practice | Recommendation |
|---|---|
| Always set resource requests | HPA cannot calculate utilization without them |
| Use v2 HPA API | Supports multiple metrics and scaling behavior control |
| Start with conservative targets | 50-70% CPU utilization is a good starting point |
| Set realistic min/max replicas | Min handles baseline load; max prevents runaway scaling |
| Use VPA in Off mode first | Gather recommendations before enabling auto-adjustment |
| Do not mix HPA + VPA on same metric | They will conflict; use HPA for scaling, VPA for right-sizing |
| Configure scaling behavior | Fast scale-up, slow scale-down prevents thrashing |
| Monitor HPA events | Use `kubectl describe hpa` to debug scaling decisions |

---

## Key Takeaways

- HPA scales pod count based on CPU, memory, or custom metrics
- Resource requests are mandatory for HPA to function correctly
- The v2 API provides fine-grained control over scaling behavior
- Scale-up is fast; scale-down is deliberately slow to prevent thrashing
- VPA right-sizes resource requests; use Off mode to gather data first
- Cluster Autoscaler adds nodes when pods cannot be scheduled
- All three autoscalers work at different layers and complement each other

---

**Lab 2 Complete** — Configuring Autoscaling | Up Next: Lab 3
