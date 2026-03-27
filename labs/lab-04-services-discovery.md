# Lab 4: Services and Service Discovery
### ClusterIP, NodePort, LoadBalancer, and DNS-Based Discovery
**Intermediate Kubernetes — Module 4 of 13**

---

## Lab Overview

### What You Will Do

- Deploy a multi-tier application
- Create ClusterIP, NodePort, and LoadBalancer Services
- Test DNS-based service discovery and examine Endpoints
- Configure headless Services, session affinity, and multi-port Services

### Prerequisites

- Completion of Labs 1-3 with `kubectl` access
- Familiarity with pods and deployments

> **Duration:** ~45-60 minutes

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

## Step 1: Deploy a Multi-Tier Application

### Create the Namespace and Backend

Set up the lab namespace and deploy the backend tier:

```bash
kubectl create namespace lab04-$STUDENT_NAME
```

Save the following as `backend-deployment.yaml`:

```yaml
# Save as backend-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: lab04-$STUDENT_NAME
spec:
  replicas: 3
  selector:
    matchLabels:
      app: backend
      tier: api
  template:
    metadata:
      labels:
        app: backend
        tier: api
    spec:
      containers:
        - name: httpbin
          image: kennethreitz/httpbin
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /get
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 10
```

Apply and verify:

```bash
kubectl apply -f backend-deployment.yaml
kubectl get pods -n lab04-$STUDENT_NAME -l tier=api -w
```

### Deploy the Frontend Tier

Deploy the frontend that will communicate with the backend. Save the following as `frontend-deployment.yaml`:

```yaml
# Save as frontend-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: lab04-$STUDENT_NAME
spec:
  replicas: 2
  selector:
    matchLabels:
      app: frontend
      tier: web
  template:
    metadata:
      labels:
        app: frontend
        tier: web
    spec:
      containers:
        - name: nginx
          image: nginx:1.25
          ports:
            - containerPort: 80
            - containerPort: 443
```

Apply and verify:

```bash
kubectl apply -f frontend-deployment.yaml

# Verify all pods are running
kubectl get pods -n lab04-$STUDENT_NAME -o wide
```

> ✅ **Checkpoint:** You should have 5 pods running -- 3 backend and 2 frontend. All should show 1/1 Ready. At this point, neither tier can communicate with the other because no Services exist yet.

---

## Step 2: Create a ClusterIP Service for the Backend

Create an internal Service for the backend. Save the following as `backend-svc.yaml`:

```yaml
# Save as backend-svc.yaml
apiVersion: v1
kind: Service
metadata:
  name: backend-svc
  namespace: lab04-$STUDENT_NAME
spec:
  type: ClusterIP
  selector:
    app: backend
    tier: api
  ports:
    - name: http
      port: 80
      targetPort: 80
```

Apply and examine:

```bash
kubectl apply -f backend-svc.yaml

# Examine the Service
kubectl get svc backend-svc -n lab04-$STUDENT_NAME
kubectl describe svc backend-svc -n lab04-$STUDENT_NAME
```

> ✅ **Expected Output:** NAME `backend-svc`, TYPE `ClusterIP`, CLUSTER-IP `10.100.x.x`, PORT(S) `80/TCP`. The `describe` output shows the Endpoints, which should list the IPs of all three backend pods. If Endpoints is empty, the selector labels do not match any pods.

> 💡 **Key Concept:** The ClusterIP (e.g., `10.100.45.120`) is a virtual IP managed by kube-proxy. It is only reachable from within the cluster. Traffic sent to this IP is load-balanced across all pods matching the selector.

---

## Step 3: Test DNS-Based Service Discovery

Exec into a frontend pod and discover the backend via DNS:

```bash
# Get a frontend pod name
FRONTEND_POD=$(kubectl get pod -n lab04-$STUDENT_NAME -l tier=web \
  -o jsonpath='{.items[0].metadata.name}')

# Install curl in the nginx container (for testing)
kubectl exec $FRONTEND_POD -n lab04-$STUDENT_NAME -- \
  apt-get update -qq && kubectl exec $FRONTEND_POD -n lab04-$STUDENT_NAME -- \
  apt-get install -y -qq curl dnsutils > /dev/null

# Test DNS resolution of the backend service
kubectl exec $FRONTEND_POD -n lab04-$STUDENT_NAME -- nslookup backend-svc
```

```bash
# Curl the backend through the Service
kubectl exec $FRONTEND_POD -n lab04-$STUDENT_NAME -- \
  curl -s backend-svc/ip
```

> ✅ **Expected Output:** `nslookup` returns `backend-svc.lab04-$STUDENT_NAME.svc.cluster.local` resolving to the ClusterIP (e.g., `10.100.45.120`).

> 💡 **Key Insight:** Inside the same namespace, you can reach the Service using just its name (`backend-svc`). Kubernetes DNS automatically resolves it to the ClusterIP address. Run `curl` multiple times to see that different backend pods may respond.

---

## Step 4: Examine DNS Records in Detail

Explore the DNS hierarchy for Services:

```bash
# Full FQDN lookup
kubectl exec $FRONTEND_POD -n lab04-$STUDENT_NAME -- \
  nslookup backend-svc.lab04-$STUDENT_NAME.svc.cluster.local

# Dig for detailed DNS record information
kubectl exec $FRONTEND_POD -n lab04-$STUDENT_NAME -- \
  dig backend-svc.lab04-$STUDENT_NAME.svc.cluster.local +short

# Verify the search domains configured in the pod
kubectl exec $FRONTEND_POD -n lab04-$STUDENT_NAME -- cat /etc/resolv.conf
```

### DNS Resolution Hierarchy

| Format | Example |
|--------|---------|
| `service-name` (same namespace) | `backend-svc` |
| `svc.namespace` (cross-namespace) | `backend-svc.lab04-$STUDENT_NAME` |
| FQDN | `backend-svc.lab04-$STUDENT_NAME.svc.cluster.local` |

> ✅ **Expected resolv.conf:** `nameserver 10.100.0.10`, search domains `lab04-$STUDENT_NAME.svc.cluster.local svc.cluster.local cluster.local`, options `ndots:5`.

> 📝 **Note:** The `resolv.conf` file shows the DNS search domains. Because of these search domains and the `ndots:5` setting, short names like `backend-svc` are resolved by appending each search domain in order. For cross-namespace communication, you must include at least the namespace in the DNS name. The FQDN ending with a dot (`cluster.local.`) avoids all search domain lookups and is the most efficient form for production configurations.

---

## Step 5: Create a NodePort Service

Expose the frontend externally via NodePort. Save the following as `frontend-nodeport.yaml`:

```yaml
# Save as frontend-nodeport.yaml
apiVersion: v1
kind: Service
metadata:
  name: frontend-nodeport
  namespace: lab04-$STUDENT_NAME
spec:
  type: NodePort
  selector:
    app: frontend
    tier: web
  ports:
    - name: http
      port: 80
      targetPort: 80
```

Apply and examine:

```bash
kubectl apply -f frontend-nodeport.yaml
kubectl get svc frontend-nodeport -n lab04-$STUDENT_NAME
kubectl get nodes -o wide
NODE_PORT=$(kubectl get svc frontend-nodeport -n lab04-$STUDENT_NAME -o jsonpath='{.spec.ports[0].nodePort}')
echo "NodePort assigned: $NODE_PORT"
curl http://<NODE-EXTERNAL-IP>:$NODE_PORT
```

> ⚠️ **Note:** Kubernetes will auto-assign an available NodePort in the 30000-32767 range. Find it with `kubectl get svc`. In EKS, node security groups may block NodePort traffic by default. NodePort is primarily useful for development and testing -- production workloads should use LoadBalancer or Ingress instead.

> 💡 **Key Concept:** NodePort also creates a ClusterIP, so the Service is accessible both internally (via ClusterIP) and externally (via any node's IP on the assigned port).

---

## Step 6: Create a LoadBalancer Service

> ⚠️ **Instructor Demo:** LoadBalancer services create real AWS NLBs (~$16/day each). In a shared cluster, observe the instructor's demo instead of creating your own. If directed to proceed, clean up immediately after testing.

Expose the frontend via an AWS Load Balancer. Save the following as `frontend-lb.yaml`:

```yaml
# Save as frontend-lb.yaml
apiVersion: v1
kind: Service
metadata:
  name: frontend-lb
  namespace: lab04-$STUDENT_NAME
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "external"
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
spec:
  type: LoadBalancer
  selector:
    app: frontend
    tier: web
  ports:
    - name: http
      port: 80
      targetPort: 80
```

Apply and watch:

```bash
kubectl apply -f frontend-lb.yaml

# Watch for the external hostname/IP to be assigned
kubectl get svc frontend-lb -n lab04-$STUDENT_NAME -w
```

> ✅ **Expected:** After 1-3 minutes, EXTERNAL-IP will show an AWS NLB hostname.

> ⚠️ **Troubleshooting:** If EXTERNAL-IP stays as `<pending>` for more than 5 minutes, check that the AWS Load Balancer Controller is installed: `kubectl get deployment -n kube-system aws-load-balancer-controller`.

### Test the Load Balancer

Verify the LoadBalancer is routing traffic:

```bash
# Get the LoadBalancer hostname
LB_HOST=$(kubectl get svc frontend-lb -n lab04-$STUDENT_NAME \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Test the endpoint
curl -s http://$LB_HOST

# Verify traffic is being distributed across pods
for i in $(seq 1 6); do
    curl -s http://$LB_HOST -o /dev/null -w "Response from: %{remote_ip}\n"
  done
```

> ✅ **Success:** You should see the nginx default page. The NLB distributes traffic across the frontend pods.

```bash
# Examine the Service details
kubectl describe svc frontend-lb -n lab04-$STUDENT_NAME
```

> 📝 **Note:** The `describe` output shows the LoadBalancer Ingress hostname and the events from the cloud provider. In production, the NLB hostname would be aliased to a friendly domain name via Route53.

---

## Step 7: Explore Endpoints and EndpointSlices

### Examine Endpoints

Inspect the Endpoints backing the backend Service:

```bash
# View the Endpoints resource
kubectl get endpoints backend-svc -n lab04-$STUDENT_NAME

# View EndpointSlices (the modern replacement)
kubectl get endpointslices -n lab04-$STUDENT_NAME \
  -l kubernetes.io/service-name=backend-svc

# Describe for full details
kubectl describe endpointslice -n lab04-$STUDENT_NAME \
  -l kubernetes.io/service-name=backend-svc
```

> ✅ **Expected Output:**
> ```
> NAME          ENDPOINTS                                 AGE
> backend-svc   10.0.1.15:80,10.0.2.22:80,10.0.3.18:80   10m
> ```

> 💡 **Endpoints vs EndpointSlices:**
> - **Endpoints** -- Legacy API, one resource per Service containing all pod IPs
> - **EndpointSlices** -- Modern API, sharded into smaller objects (max 100 endpoints each), more efficient for large Services

### Watch Endpoints Update in Real Time

Scale the backend and watch Endpoints change:

```bash
# In one terminal, watch endpoints
kubectl get endpoints backend-svc -n lab04-$STUDENT_NAME -w

# In another terminal, scale the backend down
kubectl scale deployment backend -n lab04-$STUDENT_NAME --replicas=1

# Observe endpoints reduce to 1 IP
# Then scale back up
kubectl scale deployment backend -n lab04-$STUDENT_NAME --replicas=3

# Observe endpoints grow back to 3 IPs
```

> 💡 **Key Insight:** Endpoints are dynamic. As pods come and go, the Endpoints resource is automatically updated. This is how Services provide seamless load balancing even during rolling updates and scaling events.

---

## Step 8: Create a Headless Service

Create a headless Service for direct pod access. Save the following as `backend-headless.yaml`:

```yaml
# Save as backend-headless.yaml
apiVersion: v1
kind: Service
metadata:
  name: backend-headless
  namespace: lab04-$STUDENT_NAME
spec:
  clusterIP: None
  selector:
    app: backend
    tier: api
  ports:
    - name: http
      port: 80
      targetPort: 80
```

```bash
kubectl apply -f backend-headless.yaml
kubectl get svc backend-headless -n lab04-$STUDENT_NAME
```

> ✅ **Expected:** The CLUSTER-IP column shows `None`.

### Test Headless Service DNS

Compare DNS responses between normal and headless Services:

```bash
# Normal ClusterIP Service - returns the virtual IP
kubectl exec $FRONTEND_POD -n lab04-$STUDENT_NAME -- \
  dig backend-svc.lab04-$STUDENT_NAME.svc.cluster.local +short

# Headless Service - returns individual pod IPs
kubectl exec $FRONTEND_POD -n lab04-$STUDENT_NAME -- \
  dig backend-headless.lab04-$STUDENT_NAME.svc.cluster.local +short
```

> ✅ **Expected:** ClusterIP Service returns 1 virtual IP (e.g., `10.100.45.120`). Headless Service returns all pod IPs (e.g., `10.0.1.15`, `10.0.2.22`, `10.0.3.18`).

> 💡 **Key Difference:** A ClusterIP Service returns one virtual IP (load balancing happens at the network layer). A headless Service returns all pod IPs (the client decides which pod to connect to). This is how database clients discover all replicas, how Kafka consumers find all brokers, and how custom service meshes enumerate backends.

---

## Step 9: Test Session Affinity

### Configure Session Affinity

Create a Service with session affinity enabled. Save the following as `backend-sticky.yaml`:

```yaml
# Save as backend-sticky.yaml
apiVersion: v1
kind: Service
metadata:
  name: backend-sticky
  namespace: lab04-$STUDENT_NAME
spec:
  type: ClusterIP
  selector:
    app: backend
    tier: api
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 10800
  ports:
    - name: http
      port: 80
      targetPort: 80
```

```bash
kubectl apply -f backend-sticky.yaml
kubectl describe svc backend-sticky -n lab04-$STUDENT_NAME | grep -A 2 \
  "Session Affinity"
```

> ✅ **Expected:** `Session Affinity: ClientIP`. The `timeoutSeconds` field controls how long the affinity persists (default is 10800 seconds / 3 hours).

### Verify Sticky Sessions

Send multiple requests and verify they all go to the same pod:

```bash
# Without session affinity - requests are distributed
for i in $(seq 1 6); do
    kubectl exec $FRONTEND_POD -n lab04-$STUDENT_NAME -- \
      curl -s backend-svc/headers | grep -o '"Host":.*'
  done

# With session affinity - all requests go to the same pod
for i in $(seq 1 6); do
    kubectl exec $FRONTEND_POD -n lab04-$STUDENT_NAME -- \
      curl -s backend-sticky/headers | grep -o '"Host":.*'
  done
```

> ✅ **Expected:** Requests to `backend-svc` may hit different pods. Requests to `backend-sticky` consistently hit the same pod (same response pattern).

> 📝 **Note:** Session affinity is based on the client's source IP. When traffic passes through a load balancer or proxy, all clients may appear to have the same IP, making session affinity ineffective. Kubernetes does not support cookie-based affinity at the Service level; that requires an Ingress controller. Use application-level session management for production workloads.

---

## Step 10: Multi-Port Service

### Create a Multi-Port Service

Expose both HTTP and HTTPS on the same Service. Save the following as `frontend-multiport.yaml`:

```yaml
# Save as frontend-multiport.yaml
apiVersion: v1
kind: Service
metadata:
  name: frontend-multiport
  namespace: lab04-$STUDENT_NAME
spec:
  type: ClusterIP
  selector:
    app: frontend
    tier: web
  ports:
    - name: http
      port: 80
      targetPort: 80
    - name: https
      port: 443
      targetPort: 443
```

```bash
kubectl apply -f frontend-multiport.yaml
kubectl get svc frontend-multiport -n lab04-$STUDENT_NAME
kubectl describe svc frontend-multiport -n lab04-$STUDENT_NAME
```

> ✅ **Expected Output:** `frontend-multiport ClusterIP 10.100.x.x 80/TCP,443/TCP`

> 📝 **Important:** When a Service has multiple ports, each port **must** have a `name` field. Kubernetes uses port names for DNS SRV records and Endpoint identification.

### DNS SRV Records for Multi-Port

Examine the SRV records created for named ports:

```bash
# Query SRV records for the http port
kubectl exec $FRONTEND_POD -n lab04-$STUDENT_NAME -- \
  dig SRV _http._tcp.frontend-multiport.lab04-$STUDENT_NAME.svc.cluster.local +short

# Query SRV records for the https port
kubectl exec $FRONTEND_POD -n lab04-$STUDENT_NAME -- \
  dig SRV _https._tcp.frontend-multiport.lab04-$STUDENT_NAME.svc.cluster.local +short
```

> ✅ **Expected:** SRV records return the port number and the Service hostname, allowing clients to discover both the address and port dynamically.

> 💡 **Production Pattern:** Multi-port Services are commonly used to expose application traffic and Prometheus metrics on separate ports (e.g., port 8080 for HTTP and port 9090 for metrics), all discoverable through a single Service name.

---

## Step 11: Clean Up Lab Resources

Remove all resources created during this lab:

```bash
# Delete the LoadBalancer Service first (triggers NLB deletion)
kubectl delete svc frontend-lb -n lab04-$STUDENT_NAME

# Wait for NLB deprovisioning (check AWS console or wait ~60s)
echo "Waiting for NLB deprovisioning..."
sleep 30

# Delete the entire namespace (removes all remaining resources)
kubectl delete namespace lab04-$STUDENT_NAME

# Verify cleanup
kubectl get all -n lab04-$STUDENT_NAME
kubectl get svc -n lab04-$STUDENT_NAME
```

> ⚠️ **Important:** Delete the LoadBalancer Service **before** the namespace to ensure the AWS Load Balancer Controller has time to clean up the NLB. If you delete the namespace first, the NLB may become orphaned and require manual cleanup in AWS. Orphaned NLBs incur ongoing AWS charges.

---

## Lab 4 Summary

### Service Type Comparison

| Service Type | Scope | Use Case | Access Method |
|-------------|-------|----------|---------------|
| **ClusterIP** | Internal only | Service-to-service communication | Virtual IP / DNS name |
| **NodePort** | External via node IP | Development, testing | node-ip:30000-32767 |
| **LoadBalancer** | External via cloud LB | Production external access | NLB/ALB hostname |
| **Headless** | Internal, no VIP | StatefulSets, direct pod access | DNS returns pod IPs |

### Key Concepts Learned

**Service Discovery:**
- **DNS** is the primary discovery mechanism (short names and FQDN)
- SRV records provide port discovery
- Endpoints track ready pod IPs dynamically

**Advanced Features:**
- **Session Affinity** -- ClientIP-based sticky sessions
- **Multi-Port and Headless** -- Multiple ports or direct pod IP discovery
- **EndpointSlices** -- Scalable endpoint tracking
- **AWS NLB** -- Production external access

> 💡 **Production Guidance:** Use ClusterIP for internal APIs, LoadBalancer with NLB annotations for external endpoints, and headless Services for StatefulSets. Always configure readiness probes so only healthy pods receive traffic.

---

**Lab 4 Complete!** You have successfully deployed multi-tier applications, created all Service types, tested DNS discovery, examined Endpoints, configured session affinity, and built multi-port Services.
