# Lab 8: Network Policies
### Controlling Pod-to-Pod Communication with NetworkPolicy Resources
**Intermediate Kubernetes — Module 8 of 13**

---

## Lab Overview

### Objectives

- Deploy a three-tier application and verify default connectivity
- Apply a default-deny NetworkPolicy
- Create targeted ingress policies per tier
- Test allowed/blocked paths and egress controls

### Prerequisites

- Completed Labs 1-7 with kubectl access
- CNI with NetworkPolicy support (Calico or Cilium)

> **Duration:** ~45 minutes

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

## Step 1: Deploy a Three-Tier Application

Create a namespace and deploy frontend, backend, and database tiers.

### Create the Namespace

```bash
# Create the lab namespace
kubectl create namespace lab08-$STUDENT_NAME
```

### Deploy the Database Tier

```yaml
# Save as database.yaml
apiVersion: v1
kind: Pod
metadata:
  name: database
  namespace: lab08-$STUDENT_NAME
  labels: { app: bookstore, tier: database }
spec:
  containers:
  - name: db
    image: nginx:1.25
    ports: [{ containerPort: 3306 }]
---
apiVersion: v1
kind: Service
metadata:
  name: database
  namespace: lab08-$STUDENT_NAME
spec:
  selector: { tier: database }
  ports: [{ port: 3306, targetPort: 3306 }]
```

### Deploy the Backend and Frontend Tiers

Deploy the backend and frontend tiers with matching Services:

```yaml
# Save as backend.yaml
apiVersion: v1
kind: Pod
metadata:
  name: backend
  namespace: lab08-$STUDENT_NAME
  labels: { app: bookstore, tier: backend }
spec:
  containers:
  - name: api
    image: nginx:1.25
    ports: [{ containerPort: 8080 }]
---
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: lab08-$STUDENT_NAME
spec:
  selector: { tier: backend }
  ports: [{ port: 8080, targetPort: 8080 }]
```

```yaml
# Save as frontend.yaml
apiVersion: v1
kind: Pod
metadata:
  name: frontend
  namespace: lab08-$STUDENT_NAME
  labels: { app: bookstore, tier: frontend }
spec:
  containers:
  - name: web
    image: nginx:1.25
    ports: [{ containerPort: 80 }]
---
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: lab08-$STUDENT_NAME
spec:
  selector: { tier: frontend }
  ports: [{ port: 80, targetPort: 80 }]
```

### Apply and Verify the Deployment

```bash
# Apply all three tiers (each file contains Pod + Service)
kubectl apply -f database.yaml
kubectl apply -f backend.yaml
kubectl apply -f frontend.yaml

# Wait for all pods to be ready
kubectl wait --for=condition=Ready pod --all -n lab08-$STUDENT_NAME --timeout=60s

# Verify everything is running
kubectl get pods -n lab08-$STUDENT_NAME -o wide --show-labels

# Verify services
kubectl get services -n lab08-$STUDENT_NAME
```

> ✅ **Expected Output:** Three pods (`frontend`, `backend`, `database`) all in `Running` state. Three corresponding services with ClusterIP addresses. Each pod has `app=bookstore` and its respective `tier` label.

> 💡 **Key Point:** Labels are the foundation of NetworkPolicies. The `tier` labels on each pod will be used as selectors in our policies. Well-designed labeling is essential for effective network segmentation.

---

## Step 2: Verify Default Connectivity

Confirm that all pods can communicate with each other (default behavior):

```bash
# Frontend -> Backend (should SUCCEED)
kubectl exec frontend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://backend.lab08-$STUDENT_NAME.svc.cluster.local:8080

# Frontend -> Database (should SUCCEED)
kubectl exec frontend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://database.lab08-$STUDENT_NAME.svc.cluster.local:3306

# Backend -> Database (should SUCCEED)
kubectl exec backend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://database.lab08-$STUDENT_NAME.svc.cluster.local:3306

# Database -> Frontend (should SUCCEED)
kubectl exec database -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://frontend.lab08-$STUDENT_NAME.svc.cluster.local:80
```

> ✅ **Expected Output:** All four curl commands return the nginx welcome page HTML. Every pod can reach every other pod -- this is the Kubernetes default.

> 💡 **Key Point:** By default, Kubernetes has a flat network with no restrictions. Any pod can communicate with any other pod in any namespace. This is why NetworkPolicies are critical for security.

---

## Step 3: Apply Default Deny-All Ingress Policy

Create a policy that blocks all incoming traffic to all pods in the namespace:

```yaml
# Save as deny-all-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all-ingress
  namespace: lab08-$STUDENT_NAME
spec:
  podSelector: {}
  policyTypes:
  - Ingress
```

```bash
# Apply the deny-all policy
kubectl apply -f deny-all-ingress.yaml

# Verify the policy
kubectl get networkpolicies -n lab08-$STUDENT_NAME

# Describe the policy
kubectl describe networkpolicy default-deny-all-ingress -n lab08-$STUDENT_NAME
```

> 💡 **Key Point:** A `podSelector: {}` (empty selector) matches **all pods** in the namespace. Specifying `policyTypes: [Ingress]` with no ingress rules creates a deny-all for inbound traffic. Egress is not affected by this policy. This is the foundation of zero-trust networking.

---

## Step 4: Verify Isolation

Test that all pod-to-pod communication is now blocked:

```bash
# Frontend -> Backend (should FAIL / timeout)
kubectl exec frontend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://backend.lab08-$STUDENT_NAME.svc.cluster.local:8080
echo "Exit code: $?"

# Frontend -> Database (should FAIL / timeout)
kubectl exec frontend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://database.lab08-$STUDENT_NAME.svc.cluster.local:3306
echo "Exit code: $?"

# Backend -> Database (should FAIL / timeout)
kubectl exec backend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://database.lab08-$STUDENT_NAME.svc.cluster.local:3306
echo "Exit code: $?"

# Database -> Frontend (should FAIL / timeout)
kubectl exec database -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://frontend.lab08-$STUDENT_NAME.svc.cluster.local:80
echo "Exit code: $?"
```

> ✅ **Expected Output:** All four curl commands timeout after 3 seconds with a non-zero exit code. No pod can receive traffic from any other pod. The deny-all policy is working.

> 📝 **Note:** The curl commands will hang for 3 seconds before timing out. This is expected -- the packets are being dropped by the CNI, not rejected. A timeout (not a connection refused) is the typical behavior for NetworkPolicy denials. NetworkPolicies silently drop packets rather than sending a TCP RST. This is a security feature -- it does not reveal to the sender whether the destination exists.

---

## Step 5: Allow Frontend to Backend Communication

Create a policy allowing the backend to receive traffic from the frontend:

```yaml
# Save as allow-frontend-to-backend.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: lab08-$STUDENT_NAME
spec:
  podSelector:
    matchLabels:
      tier: backend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          tier: frontend
    ports:
    - protocol: TCP
      port: 80
```

```bash
# Apply the policy
kubectl apply -f allow-frontend-to-backend.yaml

# Test: Frontend -> Backend (should now SUCCEED)
kubectl exec frontend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://backend.lab08-$STUDENT_NAME.svc.cluster.local:8080

# Test: Database -> Backend (should still FAIL)
kubectl exec database -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://backend.lab08-$STUDENT_NAME.svc.cluster.local:8080
```

> ✅ **Expected Output:** Frontend to backend returns the nginx page. Database to backend still times out. Only the explicitly allowed path works.

> 💡 **Key Point:** NetworkPolicies are additive. The deny-all policy is still in effect, but this new policy adds an exception for frontend-to-backend on TCP port 80. The `podSelector` targets the backend (the destination), and the `ingress.from` targets the frontend (the source). NetworkPolicies are written from the perspective of the target pod.

---

## Step 6: Allow Backend to Database Communication

Create a policy allowing the database to receive traffic from the backend:

```yaml
# Save as allow-backend-to-database.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-backend-to-database
  namespace: lab08-$STUDENT_NAME
spec:
  podSelector:
    matchLabels:
      tier: database
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          tier: backend
    ports:
    - protocol: TCP
      port: 80
```

```bash
# Apply the policy
kubectl apply -f allow-backend-to-database.yaml

# Test: Backend -> Database (should now SUCCEED)
kubectl exec backend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://database.lab08-$STUDENT_NAME.svc.cluster.local:3306

# Test: Frontend -> Database (should still FAIL)
kubectl exec frontend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://database.lab08-$STUDENT_NAME.svc.cluster.local:3306
```

> ✅ **Expected Output:** Backend to database returns the nginx page. Frontend to database still times out. The database is only accessible from the backend tier.

> 📝 **Note:** This completes the second leg of the three-tier architecture. The frontend must go through the backend to access data.

---

## Step 7: Test the Complete Policy Set

Run a comprehensive test of all communication paths to verify the complete policy set is working as intended:

```bash
echo "=== ALLOWED PATHS ==="
echo -n "Frontend -> Backend: "
kubectl exec frontend -n lab08-$STUDENT_NAME -- curl -s -o /dev/null \
  -w "%{http_code}" --max-time 3 \
  http://backend:8080 2>/dev/null || echo "BLOCKED"

echo -n "Backend -> Database: "
kubectl exec backend -n lab08-$STUDENT_NAME -- curl -s -o /dev/null \
  -w "%{http_code}" --max-time 3 \
  http://database:3306 2>/dev/null || echo "BLOCKED"

echo ""
echo "=== BLOCKED PATHS ==="
echo -n "Frontend -> Database: "
kubectl exec frontend -n lab08-$STUDENT_NAME -- curl -s -o /dev/null \
  -w "%{http_code}" --max-time 3 \
  http://database:3306 2>/dev/null || echo "BLOCKED"

echo -n "Database -> Frontend: "
kubectl exec database -n lab08-$STUDENT_NAME -- curl -s -o /dev/null \
  -w "%{http_code}" --max-time 3 \
  http://frontend:80 2>/dev/null || echo "BLOCKED"

echo -n "Database -> Backend: "
kubectl exec database -n lab08-$STUDENT_NAME -- curl -s -o /dev/null \
  -w "%{http_code}" --max-time 3 \
  http://backend:8080 2>/dev/null || echo "BLOCKED"
```

> ✅ **Expected Output:** Frontend to Backend: 200, Backend to Database: 200, Frontend to Database: BLOCKED, Database to Frontend: BLOCKED, Database to Backend: BLOCKED.

> 💡 **Key Point:** The policies enforce a strict traffic flow: Frontend -> Backend -> Database. No reverse paths, no direct frontend-to-database access, and no lateral movement from the database tier. This is the principle of least privilege applied to networking -- micro-segmentation and defense in depth at the network layer.

---

## Step 8: Add Egress Rules

Apply a default deny-all egress policy, then selectively allow DNS and specific traffic:

```yaml
# Save as deny-all-egress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all-egress
  namespace: lab08-$STUDENT_NAME
spec:
  podSelector: {}
  policyTypes:
  - Egress
```

```bash
# Apply deny-all egress
kubectl apply -f deny-all-egress.yaml

# Test: DNS resolution is now broken
kubectl exec frontend -n lab08-$STUDENT_NAME -- \
  nslookup backend.lab08-$STUDENT_NAME.svc.cluster.local 2>&1 || echo "DNS FAILED"
```

> ⚠️ **Troubleshooting:** DNS is now broken! The deny-all egress policy blocks all outbound traffic, including DNS queries to kube-dns (port 53). We need to explicitly allow DNS resolution. This is a very common gotcha -- when you deny all egress, you break DNS. Services that resolve by name will stop working. Always allow DNS egress when implementing egress policies.

### Allow DNS and Tier-Specific Egress

Allow DNS resolution and backend egress to the database:

```yaml
# Save as allow-dns-egress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: lab08-$STUDENT_NAME
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector: {}
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
```

```bash
kubectl apply -f allow-dns-egress.yaml

# Verify DNS and full path work again
kubectl exec frontend -n lab08-$STUDENT_NAME -- \
  nslookup backend.lab08-$STUDENT_NAME.svc.cluster.local
kubectl exec frontend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://backend.lab08-$STUDENT_NAME.svc.cluster.local:8080
```

> ✅ **Expected Output:** DNS resolution works again. The `namespaceSelector: {}` allows DNS queries to kube-dns in the kube-system namespace. The frontend-to-backend path is restored.

> 💡 **Key Point:** When implementing egress policies, always create a DNS allow rule first. Use `namespaceSelector: {}` to allow DNS to any namespace (kube-dns might be in kube-system). Include both UDP and TCP port 53. DNS uses UDP port 53 by default but can fall back to TCP port 53 for large responses. Always allow both.

---

## Step 9: Test Namespace-Based Policies

Create a monitoring namespace and allow it to access application pods:

```bash
kubectl create namespace monitoring-$STUDENT_NAME
kubectl label namespace monitoring-$STUDENT_NAME purpose=monitoring
kubectl run monitor --image=nginx:1.25 -n monitoring-$STUDENT_NAME

# Test: Monitor cannot reach backend (FAIL due to deny-all)
kubectl exec monitor -n monitoring-$STUDENT_NAME -- \
  curl -s --max-time 3 http://backend.lab08-$STUDENT_NAME.svc.cluster.local:8080
```

Create a policy to allow monitoring namespace access:

```yaml
# Save as allow-monitoring-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-monitoring-ingress
  namespace: lab08-$STUDENT_NAME
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          purpose: monitoring
    ports:
    - protocol: TCP
      port: 80
```

### Test Monitoring Access

```bash
# Apply the monitoring ingress policy
kubectl apply -f allow-monitoring-ingress.yaml

# Test: Monitor -> Backend (should now SUCCEED)
kubectl exec monitor -n monitoring-$STUDENT_NAME -- \
  curl -s --max-time 3 http://backend.lab08-$STUDENT_NAME.svc.cluster.local:8080

# Test: Monitor -> Frontend (should also SUCCEED)
kubectl exec monitor -n monitoring-$STUDENT_NAME -- \
  curl -s --max-time 3 http://frontend.lab08-$STUDENT_NAME.svc.cluster.local:80

# Test: Monitor -> Database (should also SUCCEED)
kubectl exec monitor -n monitoring-$STUDENT_NAME -- \
  curl -s --max-time 3 http://database.lab08-$STUDENT_NAME.svc.cluster.local:3306
```

> ✅ **Expected Output:** All three requests from the monitoring namespace succeed. The `namespaceSelector` with `purpose: monitoring` allows any pod in the monitoring namespace to reach any pod in lab08-$STUDENT_NAME on TCP port 80.

> 💡 **Key Point:** `namespaceSelector` selects by **namespace labels**, not by namespace name. This is why we labeled the monitoring namespace with `purpose=monitoring`. Always label namespaces that you intend to use in cross-namespace NetworkPolicies. You can combine `podSelector` and `namespaceSelector` for more granular cross-namespace rules.

---

## Step 10: Debug a Broken Policy

Apply this intentionally broken policy and find the bug:

```yaml
# Save as broken-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-external-to-frontend
  namespace: lab08-$STUDENT_NAME
spec:
  podSelector:
    matchLabels:
      tier: frontend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          tier: frontend
    ports:
    - protocol: TCP
      port: 8080
```

```bash
kubectl apply -f broken-policy.yaml
# Test - this should work but does not
kubectl run test-client --image=nginx:1.25 -n lab08-$STUDENT_NAME --rm -it \
  --restart=Never -- curl -s --max-time 3 \
  http://frontend.lab08-$STUDENT_NAME.svc.cluster.local:80
```

> ⚠️ **The policy is broken!** Can you identify the two bugs? Take 2-3 minutes to analyze the policy before looking at the fix below.

### Fix the Broken Policy

**Bug 1:** `from.podSelector` matches `tier: frontend` (self-referencing) -- fix: use `from: []` to allow from all sources.

**Bug 2:** Port is `8080` but frontend listens on `80`.

```yaml
# Save as fixed-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-external-to-frontend
  namespace: lab08-$STUDENT_NAME
spec:
  podSelector:
    matchLabels:
      tier: frontend
  policyTypes:
  - Ingress
  ingress:
  - from: []
    ports:
    - protocol: TCP
      port: 80
```

```bash
kubectl apply -f fixed-policy.yaml
# Test again - should now work
kubectl run test-client --image=nginx:1.25 \
  -n lab08-$STUDENT_NAME --rm -it --restart=Never -- \
  curl -s --max-time 3 \
  http://frontend.lab08-$STUDENT_NAME.svc.cluster.local:80
```

> ✅ **Expected Output:** The test client can now reach the frontend and receives the nginx welcome page. The fixed policy uses `from: []` (allow all sources) and the correct port 80.

> 📝 **Note:** The `from: []` syntax means allow from any source. This is different from omitting the `from` field entirely. Common debugging techniques: check labels match, verify ports, use `kubectl describe` to inspect the policy, and always test with curl.

---

## Step 11: Clean Up Resources

Remove all resources created during this lab:

```bash
# Delete both namespaces (cascades to all resources within)
kubectl delete namespace lab08-$STUDENT_NAME
kubectl delete namespace monitoring-$STUDENT_NAME

# Verify cleanup
kubectl get namespace lab08-$STUDENT_NAME 2>/dev/null \
  || echo "Namespace lab08-$STUDENT_NAME deleted"
kubectl get namespace monitoring-$STUDENT_NAME 2>/dev/null \
  || echo "Namespace monitoring-$STUDENT_NAME deleted"
```

> ✅ **Checkpoint:** Both namespaces and all their resources (pods, services, NetworkPolicies) are deleted. NetworkPolicies are namespace-scoped, so they are automatically removed when the namespace is deleted.

> 💡 **Key Point:** Unlike ClusterRoles and ClusterRoleBindings (from Lab 7), NetworkPolicies are always namespace-scoped. Deleting the namespace is sufficient to clean up all network policies within it.

---

## Summary -- Network Policy Patterns Reference

| Pattern | Use Case |
|---------|----------|
| `podSelector: {}` + no rules | Default deny all (ingress or egress) |
| `podSelector.matchLabels` | Target specific pods by label |
| `ingress.from.podSelector` | Allow from specific pods (same namespace) |
| `ingress.from.namespaceSelector` | Allow from pods in labeled namespaces |
| `egress.to` + `ports: [53]` | Allow DNS resolution (always include this) |
| `from: []` | Allow from all sources (open ingress) |
| `kubectl get netpol -n <ns>` | List policies in a namespace |
| `kubectl describe netpol <name>` | View policy details and selectors |

## Key Takeaways

- Kubernetes defaults to allowing all pod-to-pod communication -- NetworkPolicies add restrictions
- Start with a default deny-all policy, then selectively allow required traffic
- NetworkPolicies are additive -- multiple policies combine their allowed paths
- Always allow DNS (UDP/TCP port 53) when implementing egress policies
- Use `namespaceSelector` for cross-namespace communication (based on namespace labels)
- Test policies thoroughly -- verify both allowed and blocked paths
