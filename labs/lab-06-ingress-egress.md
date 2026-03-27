# Lab 6: Ingress and Gateway API
### HTTP Routing, TLS Termination, and Egress Controls
**Intermediate Kubernetes — Module 6 of 13**

---

## Lab Overview

### What You Will Do

- Verify the Ingress controller and deploy sample applications
- Configure host-based and path-based routing with TLS
- Explore Ingress annotations (rewrite, rate limiting, CORS)
- Deploy Gateway API resources with HTTPRoute traffic splitting
- Configure egress NetworkPolicies to control outbound traffic

### Prerequisites

- Completion of Labs 1-5 with `kubectl` access
- Ingress controller installed (NGINX or AWS ALB)

> Steps 8-9 (Gateway API) require the Gateway API CRDs. If unavailable, read through as reference.

### Duration

Approximately 60 minutes

---

## Environment Setup

```bash
export STUDENT_NAME=<your-name>
echo "Student: $STUDENT_NAME"
```

---

## Step 1: Verify Ingress Controller and Create Namespace

```bash
# Check for NGINX Ingress Controller
kubectl get pods -n ingress-nginx

# Or check for AWS Load Balancer Controller
kubectl get pods -n kube-system \
  -l app.kubernetes.io/name=aws-load-balancer-controller

kubectl get ingressclass
```

> ⚠️ If no Ingress controller is found, notify the instructor.

```bash
kubectl create namespace lab06-$STUDENT_NAME

# Verify the Ingress controller service has an external IP/hostname
kubectl get svc -n ingress-nginx
```

---

## Step 2: Deploy Two Sample Applications

### Deploy app-v1

```yaml
# Save as app-v1.yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: app-v1, namespace: lab06-$STUDENT_NAME }
spec:
  replicas: 2
  selector: { matchLabels: { app: web, version: v1 } }
  template:
    metadata: { labels: { app: web, version: v1 } }
    spec:
      containers:
        - name: app
          image: hashicorp/http-echo
          args: ["-text=Hello from App V1", "-listen=:8080"]
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet: { path: /, port: 8080 }
---
apiVersion: v1
kind: Service
metadata: { name: app-v1-svc, namespace: lab06-$STUDENT_NAME }
spec:
  selector: { app: web, version: v1 }
  ports:
    - { port: 80, targetPort: 8080 }
```

### Deploy app-v2

```yaml
# Save as app-v2.yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: app-v2, namespace: lab06-$STUDENT_NAME }
spec:
  replicas: 2
  selector: { matchLabels: { app: web, version: v2 } }
  template:
    metadata: { labels: { app: web, version: v2 } }
    spec:
      containers:
        - name: app
          image: hashicorp/http-echo
          args: ["-text=Hello from App V2", "-listen=:8080"]
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet: { path: /, port: 8080 }
---
apiVersion: v1
kind: Service
metadata: { name: app-v2-svc, namespace: lab06-$STUDENT_NAME }
spec:
  selector: { app: web, version: v2 }
  ports:
    - { port: 80, targetPort: 8080 }
```

```bash
kubectl apply -f app-v1.yaml
kubectl apply -f app-v2.yaml
kubectl get pods -n lab06-$STUDENT_NAME -l app=web
kubectl get svc -n lab06-$STUDENT_NAME
```

> ✅ **Checkpoint:** 4 pods (2 for v1, 2 for v2) Running and 2 ClusterIP services.

---

## Step 3: Create a Host-Based Ingress

```yaml
# Save as ingress-host.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress-host
  namespace: lab06-$STUDENT_NAME
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
    - host: v1-$STUDENT_NAME.lab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app-v1-svc
                port:
                  number: 80
    - host: v2-$STUDENT_NAME.lab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app-v2-svc
                port:
                  number: 80
```

```bash
kubectl apply -f ingress-host.yaml
```

---

## Step 4: Test Host-Based Routing

```bash
INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Ingress address: $INGRESS_IP"

curl -s -H "Host: v1-$STUDENT_NAME.lab.local" http://$INGRESS_IP
curl -s -H "Host: v2-$STUDENT_NAME.lab.local" http://$INGRESS_IP
curl -s -H "Host: unknown.lab.local" http://$INGRESS_IP
```

> ✅ **Checkpoint:** v1 host returns `Hello from App V1`, v2 host returns `Hello from App V2`, unknown host returns 404.

> ⚠️ **AWS Note:** On EKS, use the hostname instead of IP. Allow 2-3 minutes for DNS propagation after LB creation.

---

## Step 5: Add Path-Based Routing

```yaml
# Save as ingress-path.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress-path
  namespace: lab06-$STUDENT_NAME
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
    - host: app-$STUDENT_NAME.lab.local
      http:
        paths:
          - path: /v1
            pathType: Prefix
            backend:
              service:
                name: app-v1-svc
                port:
                  number: 80
          - path: /v2
            pathType: Prefix
            backend:
              service:
                name: app-v2-svc
                port:
                  number: 80
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app-v1-svc
                port:
                  number: 80
```

```bash
kubectl apply -f ingress-path.yaml

curl -s -H "Host: app-$STUDENT_NAME.lab.local" http://$INGRESS_IP/v1
curl -s -H "Host: app-$STUDENT_NAME.lab.local" http://$INGRESS_IP/v2
curl -s -H "Host: app-$STUDENT_NAME.lab.local" http://$INGRESS_IP/
```

> ✅ **Checkpoint:** `/v1` returns V1, `/v2` returns V2, `/` defaults to V1.

---

## Step 6: Configure TLS Termination

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout tls-ingress.key -out tls-ingress.crt \
    -subj "/CN=*.lab.local/O=Verisign Lab"

kubectl create secret tls lab-tls-secret \
    --cert=tls-ingress.crt --key=tls-ingress.key -n lab06-$STUDENT_NAME
```

```yaml
# Save as ingress-tls.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress-tls
  namespace: lab06-$STUDENT_NAME
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - secure.lab.local
      secretName: lab-tls-secret
  rules:
    - host: secure.lab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app-v1-svc
                port:
                  number: 80
```

```bash
kubectl apply -f ingress-tls.yaml

curl -sk -H "Host: secure.lab.local" https://$INGRESS_IP
curl -sI -H "Host: secure.lab.local" http://$INGRESS_IP
```

> ✅ **Checkpoint:** HTTPS returns `Hello from App V1`. HTTP returns a `308 Permanent Redirect` to HTTPS.

---

## Step 7: Explore Ingress Annotations

```yaml
# Save as ingress-annotations.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress-advanced
  namespace: lab06-$STUDENT_NAME
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    nginx.ingress.kubernetes.io/limit-rps: "10"
    nginx.ingress.kubernetes.io/enable-cors: "true"
    nginx.ingress.kubernetes.io/cors-allow-origin: "https://app.verisign.com"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "10"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "30"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      more_set_headers "X-Served-By: verisign-eks";
spec:
  ingressClassName: nginx
  rules:
    - host: api.lab.local
      http:
        paths:
          - path: /api(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: app-v1-svc
                port:
                  number: 80
```

```bash
kubectl apply -f ingress-annotations.yaml

curl -s -H "Host: api.lab.local" http://$INGRESS_IP/api/

# Check CORS and custom headers
curl -sI -H "Host: api.lab.local" \
    -H "Origin: https://app.verisign.com" \
    http://$INGRESS_IP/api/ 2>&1 | grep -E "cors|X-Served"

# Test rate limiting
for i in $(seq 1 15); do
    curl -s -o /dev/null -w "%{http_code} " \
        -H "Host: api.lab.local" http://$INGRESS_IP/api/
done
echo ""
```

> ✅ **Checkpoint:** CORS and custom headers appear. After 10 rapid requests, excess requests return `503`.

---

## Step 8: Gateway API -- GatewayClass and Gateway

```bash
kubectl get crd | grep gateway
```

> ⚠️ **If CRDs are not installed:**
> ```bash
> kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
> ```

```yaml
# Save as gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: lab-gateway-class-$STUDENT_NAME
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: lab-gateway
  namespace: lab06-$STUDENT_NAME
spec:
  gatewayClassName: lab-gateway-class-$STUDENT_NAME
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: Same
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - name: lab-tls-secret
      allowedRoutes:
        namespaces:
          from: Same
```

```bash
kubectl apply -f gateway.yaml
kubectl get gateway -n lab06-$STUDENT_NAME
```

---

## Step 9: HTTPRoute for Traffic Splitting

```yaml
# Save as httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: app-route
  namespace: lab06-$STUDENT_NAME
spec:
  parentRefs:
    - name: lab-gateway
      sectionName: http
  hostnames:
    - "app-$STUDENT_NAME.lab.local"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: app-v1-svc
          port: 80
          weight: 80
        - name: app-v2-svc
          port: 80
          weight: 20
```

```bash
kubectl apply -f httproute.yaml

GATEWAY_IP=$(kubectl get gateway lab-gateway -n lab06-$STUDENT_NAME \
    -o jsonpath='{.status.addresses[0].value}')

for i in $(seq 1 20); do
    curl -s -H "Host: app-$STUDENT_NAME.lab.local" http://$GATEWAY_IP
done | sort | uniq -c | sort -rn
```

> ✅ **Checkpoint:** Expect roughly 80/20 distribution between V1 and V2.

> ⚠️ If the Gateway controller is not running, use Ingress-based routing from earlier steps as fallback.

---

## Step 10: Configure Egress Controls with NetworkPolicy

```bash
kubectl run egress-test --image=busybox:1.36 \
    -n lab06-$STUDENT_NAME --restart=Never \
    --command -- sleep 3600

# Test outbound connectivity
kubectl exec egress-test -n lab06-$STUDENT_NAME -- \
    wget -qO- --timeout=5 http://app-v1-svc.lab06-$STUDENT_NAME.svc.cluster.local
kubectl exec egress-test -n lab06-$STUDENT_NAME -- \
    wget -qO- --timeout=5 http://example.com
```

### Apply Egress NetworkPolicy

```yaml
# Save as egress-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: restrict-egress
  namespace: lab06-$STUDENT_NAME
spec:
  podSelector:
    matchLabels:
      run: egress-test
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: lab06-$STUDENT_NAME
      ports:
        - protocol: TCP
          port: 80
```

```bash
kubectl apply -f egress-policy.yaml

# Internal service access should work
kubectl exec egress-test -n lab06-$STUDENT_NAME -- \
    wget -qO- --timeout=5 http://app-v1-svc.lab06-$STUDENT_NAME.svc.cluster.local

# External access should be BLOCKED
kubectl exec egress-test -n lab06-$STUDENT_NAME -- \
    wget -qO- --timeout=5 http://example.com
```

> ✅ **Checkpoint:** Internal returns `Hello from App V1`. External times out.

> ⚠️ NetworkPolicy enforcement requires a compatible CNI (Calico, Cilium). Default AWS VPC CNI without a policy engine will accept but not enforce policies.

---

## Step 11: Clean Up

```bash
kubectl delete gatewayclass lab-gateway-class-$STUDENT_NAME --ignore-not-found
kubectl delete namespace lab06-$STUDENT_NAME

rm -f app-v1.yaml app-v2.yaml ingress-host.yaml ingress-path.yaml \
    ingress-tls.yaml ingress-annotations.yaml gateway.yaml httproute.yaml \
    egress-policy.yaml tls-ingress.key tls-ingress.crt
```

---

## Summary

- **Ingress:** Host-based and path-based routing, TLS termination with SSL redirect, controller-specific annotations for rewrite/rate-limiting/CORS
- **Gateway API:** Role-based separation (GatewayClass/Gateway/HTTPRoute), native traffic splitting via weighted `backendRefs`
- **Egress Controls:** NetworkPolicy egress rules restrict outbound traffic; always include a DNS exception (port 53) when restricting egress
