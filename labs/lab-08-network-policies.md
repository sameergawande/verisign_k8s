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

```bash
export STUDENT_NAME=<your-name>
echo "Student: $STUDENT_NAME"
```

---

## Step 1: Deploy a Three-Tier Application

```bash
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

```bash
kubectl apply -f database.yaml
kubectl apply -f backend.yaml
kubectl apply -f frontend.yaml

kubectl wait --for=condition=Ready pod --all -n lab08-$STUDENT_NAME --timeout=60s
kubectl get pods -n lab08-$STUDENT_NAME -o wide --show-labels
```

---

## Step 2: Verify Default Connectivity

Confirm all pods can communicate (all should succeed):

```bash
kubectl exec frontend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://backend.lab08-$STUDENT_NAME.svc.cluster.local:8080

kubectl exec frontend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://database.lab08-$STUDENT_NAME.svc.cluster.local:3306

kubectl exec database -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://frontend.lab08-$STUDENT_NAME.svc.cluster.local:80
```

---

## Step 3: Apply Default Deny-All Ingress Policy

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
kubectl apply -f deny-all-ingress.yaml
```

---

## Step 4: Verify Isolation

```bash
# All should FAIL / timeout
kubectl exec frontend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://backend.lab08-$STUDENT_NAME.svc.cluster.local:8080
echo "Exit code: $?"

kubectl exec backend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://database.lab08-$STUDENT_NAME.svc.cluster.local:3306
echo "Exit code: $?"

kubectl exec database -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://frontend.lab08-$STUDENT_NAME.svc.cluster.local:80
echo "Exit code: $?"
```

> ✅ **Checkpoint:** All curl commands timeout with a non-zero exit code.

---

## Step 5: Allow Frontend to Backend Communication

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
      port: 8080
```

```bash
kubectl apply -f allow-frontend-to-backend.yaml

# Frontend -> Backend (should now SUCCEED)
kubectl exec frontend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://backend.lab08-$STUDENT_NAME.svc.cluster.local:8080

# Database -> Backend (should still FAIL)
kubectl exec database -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://backend.lab08-$STUDENT_NAME.svc.cluster.local:8080
```

> ✅ **Checkpoint:** Frontend to backend succeeds; database to backend times out.

---

## Step 6: Allow Backend to Database Communication

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
      port: 3306
```

```bash
kubectl apply -f allow-backend-to-database.yaml

# Backend -> Database (should now SUCCEED)
kubectl exec backend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://database.lab08-$STUDENT_NAME.svc.cluster.local:3306

# Frontend -> Database (should still FAIL)
kubectl exec frontend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://database.lab08-$STUDENT_NAME.svc.cluster.local:3306
```

> ✅ **Checkpoint:** Backend to database succeeds; frontend to database times out.

---

## Step 7: Test the Complete Policy Set

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

> ✅ **Checkpoint:** Frontend->Backend: 200, Backend->Database: 200, all others: BLOCKED.

---

## Step 8: Add Egress Rules

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
kubectl apply -f deny-all-egress.yaml

# DNS is now broken
kubectl exec frontend -n lab08-$STUDENT_NAME -- \
  nslookup backend.lab08-$STUDENT_NAME.svc.cluster.local 2>&1 || echo "DNS FAILED"
```

### Allow DNS Egress

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

# Verify DNS and traffic flow restored
kubectl exec frontend -n lab08-$STUDENT_NAME -- \
  nslookup backend.lab08-$STUDENT_NAME.svc.cluster.local
kubectl exec frontend -n lab08-$STUDENT_NAME -- \
  curl -s --max-time 3 http://backend.lab08-$STUDENT_NAME.svc.cluster.local:8080
```

> ✅ **Checkpoint:** DNS works again and the frontend-to-backend path is restored.

---

## Step 9: Test Namespace-Based Policies

```bash
kubectl create namespace monitoring-$STUDENT_NAME
kubectl label namespace monitoring-$STUDENT_NAME purpose=monitoring
kubectl run monitor --image=nginx:1.25 -n monitoring-$STUDENT_NAME

# Monitor cannot reach backend (denied by default)
kubectl exec monitor -n monitoring-$STUDENT_NAME -- \
  curl -s --max-time 3 http://backend.lab08-$STUDENT_NAME.svc.cluster.local:8080
```

Allow monitoring namespace access:

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

```bash
kubectl apply -f allow-monitoring-ingress.yaml

kubectl exec monitor -n monitoring-$STUDENT_NAME -- \
  curl -s --max-time 3 http://backend.lab08-$STUDENT_NAME.svc.cluster.local:8080
```

> ✅ **Checkpoint:** Monitoring pod can now reach application pods.

---

## Step 10: Debug a Broken Policy

Apply this intentionally broken policy and find the bugs:

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
kubectl run test-client --image=nginx:1.25 -n lab08-$STUDENT_NAME --rm -it \
  --restart=Never -- curl -s --max-time 3 \
  http://frontend.lab08-$STUDENT_NAME.svc.cluster.local:80
```

> ⚠️ **Two bugs:** (1) `from.podSelector` matches `tier: frontend` (self-referencing) -- should be `from: []` to allow all sources. (2) Port is `8080` but frontend listens on `80`.

### Fix the Broken Policy

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
kubectl run test-client --image=nginx:1.25 \
  -n lab08-$STUDENT_NAME --rm -it --restart=Never -- \
  curl -s --max-time 3 \
  http://frontend.lab08-$STUDENT_NAME.svc.cluster.local:80
```

> ✅ **Checkpoint:** The test client can now reach the frontend.

---

## Step 11: Clean Up

```bash
kubectl delete namespace lab08-$STUDENT_NAME
kubectl delete namespace monitoring-$STUDENT_NAME
```

---

## Summary

- Kubernetes defaults to allowing all pod-to-pod communication -- NetworkPolicies add restrictions
- Start with a default deny-all policy, then selectively allow required traffic
- NetworkPolicies are additive -- multiple policies combine their allowed paths
- Always allow DNS (UDP/TCP port 53) when implementing egress policies
- Use `namespaceSelector` with namespace labels for cross-namespace communication
