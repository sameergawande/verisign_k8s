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

> 💡 **Note:** Steps 8-9 (Gateway API) require the Gateway API CRDs to be installed. If unavailable, those steps can be read through as reference.

### Duration

> ⏱ **Estimated Time:** 60 minutes

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

## Step 1: Verify Ingress Controller Is Running

Before creating Ingress resources, verify that an Ingress controller is deployed in the cluster.

### Check for the Ingress Controller

```bash
# Check for NGINX Ingress Controller
kubectl get pods -n ingress-nginx

# Or check for AWS Load Balancer Controller
kubectl get pods -n kube-system \
  -l app.kubernetes.io/name=aws-load-balancer-controller

# Check IngressClasses available
kubectl get ingressclass
```

> ✅ **Expected Output (NGINX):**
> ```
> NAME                                        READY   STATUS
> ingress-nginx-controller-5d4f4f7b8-xxxxx   1/1     Running
>
> NAME    CONTROLLER                     PARAMETERS   AGE
> nginx   k8s.io/ingress-nginx           <none>       10d
> ```

> ⚠️ **Troubleshooting:** If no Ingress controller is found, notify the instructor. Ingress resources will not function without a controller. The IngressClass determines which controller processes your Ingress resources.

### Create Lab Namespace

```bash
# Create the lab namespace
kubectl create namespace lab06-$STUDENT_NAME

# Verify the Ingress controller service has an external IP/hostname
kubectl get svc -n ingress-nginx
# Or for AWS ALB Controller, the external address appears on the Ingress itself
```

> ✅ **Expected Output:**
> ```
> NAME                              TYPE           CLUSTER-IP     EXTERNAL-IP
> ingress-nginx-controller          LoadBalancer   10.100.x.x    ab1c2d3e4...elb.amazonaws.com
> ```

> 💡 **Key Point:** The EXTERNAL-IP (or hostname on AWS) is where all Ingress traffic enters the cluster. The Ingress controller then routes requests to the correct backend Service based on host and path rules.

---

## Step 2: Deploy Two Sample Applications

Deploy two versions of a sample application. These represent different microservices or application versions that will be routed to via Ingress using host-based and path-based rules.

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

### Apply and Verify

```bash
kubectl apply -f app-v1.yaml
kubectl apply -f app-v2.yaml

# Verify all pods are running
kubectl get pods -n lab06-$STUDENT_NAME -l app=web
kubectl get svc -n lab06-$STUDENT_NAME
```

> ✅ **Checkpoint:** You should see 4 pods (2 for v1, 2 for v2) in Running/Ready state and 2 ClusterIP services.

---

## Step 3: Create a Basic Ingress (Host-Based Routing)

Host-based routing directs traffic based on the HTTP Host header. This is the most common Ingress pattern, allowing multiple applications to share a single load balancer IP by using different domain names.

### Create Host-Based Ingress

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
kubectl apply -f ingress-host.yaml && kubectl get ingress -n lab06-$STUDENT_NAME
```

### Verify the Ingress

```bash
# Check Ingress details
kubectl describe ingress app-ingress-host -n lab06-$STUDENT_NAME
```

> ✅ **Expected Output:**
> ```
> Name:             app-ingress-host
> Namespace:        lab06-$STUDENT_NAME
> Rules:
>   Host           Path  Backends
>   ----           ----  --------
>   v1-$STUDENT_NAME.lab.local   /     app-v1-svc:80 (10.0.x.x:8080,10.0.x.x:8080)
>   v2-$STUDENT_NAME.lab.local   /     app-v2-svc:80 (10.0.x.x:8080,10.0.x.x:8080)
> ```

> 💡 **Note:** The Backends column shows the pod IP addresses. If it shows `<error: endpoints ... not found>`, the service selector does not match any pods.

---

## Step 4: Test Host-Based Routing

Use the Ingress controller's address with Host headers to test routing:

```bash
# Get the Ingress controller external address
INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Ingress address: $INGRESS_IP"

# Test routing to v1
curl -s -H "Host: v1-$STUDENT_NAME.lab.local" http://$INGRESS_IP

# Test routing to v2
curl -s -H "Host: v2-$STUDENT_NAME.lab.local" http://$INGRESS_IP

# Test with an unknown host (should get 404)
curl -s -H "Host: unknown.lab.local" http://$INGRESS_IP
```

> ✅ **Expected Output:**
> ```
> $ curl -H "Host: v1-$STUDENT_NAME.lab.local" http://$INGRESS_IP
> Hello from App V1
>
> $ curl -H "Host: v2-$STUDENT_NAME.lab.local" http://$INGRESS_IP
> Hello from App V2
> ```

> ⚠️ **AWS Note:** On EKS, use the hostname instead of IP. If using NLB, the `jsonpath` field may be `.ip` instead of `.hostname`. Allow 2-3 minutes for DNS propagation after the load balancer is created.

---

## Step 5: Add Path-Based Routing

Path-based routing directs traffic based on the URL path. This allows a single hostname to serve multiple backends based on the request path. It is commonly used for API versioning and microservice routing.

### Create Path-Based Ingress

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
```

### Test Path-Based Routing

```bash
# Test path /v1
curl -s -H "Host: app-$STUDENT_NAME.lab.local" http://$INGRESS_IP/v1

# Test path /v2
curl -s -H "Host: app-$STUDENT_NAME.lab.local" http://$INGRESS_IP/v2

# Test default path
curl -s -H "Host: app-$STUDENT_NAME.lab.local" http://$INGRESS_IP/
```

> ✅ **Expected Output:**
> ```
> $ curl -H "Host: app-$STUDENT_NAME.lab.local" http://$INGRESS_IP/v1
> Hello from App V1
>
> $ curl -H "Host: app-$STUDENT_NAME.lab.local" http://$INGRESS_IP/v2
> Hello from App V2
>
> $ curl -H "Host: app-$STUDENT_NAME.lab.local" http://$INGRESS_IP/
> Hello from App V1
> ```

> 📝 **pathType Values:**
> - **Prefix:** Matches URL paths where the path element is a prefix (split by `/`)
> - **Exact:** Matches the URL path exactly, case-sensitive
> - **ImplementationSpecific:** Matching depends on the IngressClass

---

## Step 6: Configure TLS Termination

TLS termination at the Ingress controller is the standard pattern for HTTPS. The Ingress controller handles TLS decryption, forwarding unencrypted traffic to the backend services within the cluster network.

### Create TLS Secret and Ingress

```bash
# Generate a self-signed certificate and create TLS Secret
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

### Test TLS Termination

```bash
kubectl apply -f ingress-tls.yaml

# Test HTTPS (use -k to accept self-signed cert)
curl -sk -H "Host: secure.lab.local" https://$INGRESS_IP

# Verify the certificate details
curl -skv -H "Host: secure.lab.local" https://$INGRESS_IP 2>&1 | \
    grep -E "subject|issuer|expire"

# Test HTTP redirect to HTTPS
curl -sI -H "Host: secure.lab.local" http://$INGRESS_IP
```

> ✅ **Expected Output:**
> ```
> Hello from App V1
>
> * subject: CN=*.lab.local; O=Verisign Lab
>
> HTTP/1.1 308 Permanent Redirect
> Location: https://secure.lab.local/
> ```

> ⚠️ **Note:** The `-k` flag skips certificate verification (required for self-signed certs). Never use `-k` in production scripts. The 308 redirect confirms that HTTP traffic is automatically redirected to HTTPS.

---

## Step 7: Explore Ingress Annotations

Annotations are the primary mechanism for configuring Ingress controller behavior beyond basic routing. The available annotations depend on the Ingress controller in use.

### Create Advanced Annotations Ingress

```yaml
# Save as ingress-annotations.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress-advanced
  namespace: lab06-$STUDENT_NAME
  annotations:
    # URL rewriting with regex capture
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    # Rate limiting
    nginx.ingress.kubernetes.io/limit-rps: "10"
    # CORS
    nginx.ingress.kubernetes.io/enable-cors: "true"
    nginx.ingress.kubernetes.io/cors-allow-origin: "https://app.verisign.com"
    # Proxy timeouts
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "10"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "30"
    # Custom headers
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

### Test Annotations

```bash
kubectl apply -f ingress-annotations.yaml

# Test URL rewriting: /api/anything routes to /anything on the backend
curl -s -H "Host: api.lab.local" http://$INGRESS_IP/api/

# Check response headers for CORS and custom headers
curl -sI -H "Host: api.lab.local" \
    -H "Origin: https://app.verisign.com" \
    http://$INGRESS_IP/api/ 2>&1 | grep -E "cors|X-Served"

# Test rate limiting (rapid requests)
for i in $(seq 1 15); do
    curl -s -o /dev/null -w "%{http_code} " \
        -H "Host: api.lab.local" http://$INGRESS_IP/api/
done
echo ""
```

> ✅ **Expected Output:**
> ```
> Access-Control-Allow-Origin: https://app.verisign.com
> X-Served-By: verisign-eks
>
> 200 200 200 200 200 200 200 200 200 200 503 503 503 503 503
> ```

> 💡 **Key Point:** After 10 requests per second (with burst), excess requests receive `503 Service Temporarily Unavailable`. Rate limiting protects backend services from overload.

---

## Step 8: Gateway API -- GatewayClass and Gateway

The Gateway API is the successor to Ingress, offering a more expressive, role-oriented, and portable API for traffic routing. It separates infrastructure concerns (GatewayClass, Gateway) from application routing (HTTPRoute).

### Check Gateway API CRDs

```bash
# Verify Gateway API CRDs are installed
kubectl get crd | grep gateway

# Expected CRDs:
# gatewayclasses.gateway.networking.k8s.io
# gateways.gateway.networking.k8s.io
# httproutes.gateway.networking.k8s.io
```

> ⚠️ **If CRDs are not installed:** Install them with:
> ```bash
> kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
> ```
> If installation is not permitted, read through steps 8-9 as reference material.

### Deploy GatewayClass and Gateway

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

### Verify Gateway Status

```bash
kubectl get gateway lab-gateway -n lab06-$STUDENT_NAME -o yaml | \
    kubectl neat 2>/dev/null || \
    kubectl get gateway lab-gateway -n lab06-$STUDENT_NAME -o yaml
```

> ✅ **Expected Status:** The Gateway should show `Accepted: True` and `Programmed: True` conditions. If the controller is not running, the status will show `Accepted: False` with a reason.

> 📝 **Gateway API Role Separation:**
> - **Infrastructure Provider** -- Manages GatewayClass, deploys the controller
> - **Cluster Operator** -- Manages Gateway, configures listeners and TLS
> - **Application Developer** -- Manages HTTPRoute, attaches to Gateway

---

## Step 9: HTTPRoute for Traffic Splitting

HTTPRoute is where application developers define routing rules. A powerful feature of Gateway API is native traffic splitting (weighted routing), which enables canary deployments and A/B testing without additional tooling.

### Create HTTPRoute with Traffic Splitting

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
kubectl get httproute -n lab06-$STUDENT_NAME
kubectl describe httproute app-route -n lab06-$STUDENT_NAME
```

### Test Traffic Splitting

```bash
# Get the Gateway address
GATEWAY_IP=$(kubectl get gateway lab-gateway -n lab06-$STUDENT_NAME \
    -o jsonpath='{.status.addresses[0].value}')

# Send 20 requests and count the distribution
for i in $(seq 1 20); do
    curl -s -H "Host: app-$STUDENT_NAME.lab.local" http://$GATEWAY_IP
done | sort | uniq -c | sort -rn
```

> ✅ **Expected Output (approximately):**
> ```
>   16 Hello from App V1
>    4 Hello from App V2
> ```

> 💡 **Key Point:** Traffic splitting is probabilistic. With 20 requests, expect roughly 80/20 distribution. In production canary deployments, start with 5% to the new version and gradually increase as confidence grows.

> ⚠️ **Note:** If the Gateway controller is not running or CRDs are missing, this test will not work. Use the Ingress-based routing from earlier steps as the fallback.

---

## Step 10: Configure Egress Controls with NetworkPolicy

While Ingress controls inbound traffic routing, egress NetworkPolicies control outbound traffic from pods. This is critical for security: restricting which external services pods can communicate with reduces the blast radius of a compromise.

### Test Default Egress (No Restrictions)

```bash
# Deploy a test pod
kubectl run egress-test --image=busybox:1.36 \
    -n lab06-$STUDENT_NAME --restart=Never \
    --command -- sleep 3600

# Test outbound connectivity (DNS and HTTP)
kubectl exec egress-test -n lab06-$STUDENT_NAME -- \
    nslookup kubernetes.default.svc.cluster.local

kubectl exec egress-test -n lab06-$STUDENT_NAME -- \
    wget -qO- --timeout=5 http://app-v1-svc.lab06-$STUDENT_NAME.svc.cluster.local

kubectl exec egress-test -n lab06-$STUDENT_NAME -- \
    wget -qO- --timeout=5 http://example.com
```

> ✅ **Expected Output:** All three requests succeed. By default, pods have unrestricted egress to both cluster-internal and external destinations.

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
    - to:  # Allow DNS
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:  # Allow cluster-internal HTTP
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: lab06-$STUDENT_NAME
      ports:
        - protocol: TCP
          port: 80
```

```bash
kubectl apply -f egress-policy.yaml
```

### Verify Egress Restrictions

```bash
# DNS should still work
kubectl exec egress-test -n lab06-$STUDENT_NAME -- \
    nslookup kubernetes.default.svc.cluster.local

# Internal service access should work
kubectl exec egress-test -n lab06-$STUDENT_NAME -- \
    wget -qO- --timeout=5 http://app-v1-svc.lab06-$STUDENT_NAME.svc.cluster.local

# External access should be BLOCKED
kubectl exec egress-test -n lab06-$STUDENT_NAME -- \
    wget -qO- --timeout=5 http://example.com
```

> ✅ **Expected Output:**
> ```
> DNS:       Server: 10.100.0.10  Address: 10.100.0.10:53  Name: kubernetes...
> Internal:  Hello from App V1
> External:  wget: download timed out
> ```

> ⚠️ **CNI Requirement:** NetworkPolicy enforcement requires a compatible CNI plugin (Calico, Cilium). If using the default AWS VPC CNI without a policy engine, NetworkPolicies are accepted but not enforced. Verify with your cluster administrator.

---

## Step 11: Clean Up

```bash
# Delete the GatewayClass (cluster-scoped, not deleted with namespace)
kubectl delete gatewayclass lab-gateway-class-$STUDENT_NAME --ignore-not-found

# Delete the entire namespace
kubectl delete namespace lab06-$STUDENT_NAME

# Verify cleanup
kubectl get namespace lab06-$STUDENT_NAME
kubectl get gatewayclass lab-gateway-class-$STUDENT_NAME

# Clean up local files
rm -f app-v1.yaml app-v2.yaml ingress-host.yaml ingress-path.yaml \
    ingress-tls.yaml ingress-annotations.yaml gateway.yaml httproute.yaml \
    egress-policy.yaml tls-ingress.key tls-ingress.crt
```

> ✅ **Expected Output:** Both the namespace and GatewayClass are deleted. All Ingress, Gateway, HTTPRoute, NetworkPolicy, and Service resources are removed.

---

## Summary and Key Takeaways

### Ingress

- Host-based and path-based routing using Ingress resources
- TLS termination with self-signed certificates and SSL redirect
- Controller-specific annotations for rewrite, rate limiting, CORS, and custom headers

### Gateway API

- Role-based separation: GatewayClass (infra), Gateway (operator), HTTPRoute (developer)
- Native traffic splitting via weighted `backendRefs` for canary deployments
- Portable spec across controller implementations

### Egress Controls

- NetworkPolicy egress rules restrict outbound traffic from pods
- Always include a DNS exception (port 53 to kube-dns) when restricting egress
- Namespace-scoped restrictions require a NetworkPolicy-capable CNI (Calico, Cilium)

### Ingress vs Gateway API Comparison

| Feature | Ingress | Gateway API |
|---|---|---|
| API maturity | Stable (v1 since 1.19) | GA core (v1 since 1.29) |
| Role separation | Single resource | GatewayClass / Gateway / Route |
| Traffic splitting | Annotation-dependent | Native (weight field) |
| Header matching | Annotation-dependent | Native (matches block) |
| Portability | Annotations not portable | Spec is portable |
| Protocol support | HTTP/HTTPS only | HTTP, gRPC, TCP, TLS, UDP |
