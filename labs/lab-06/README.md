# Lab 6: Ingress Controllers and HTTP Routing
### Host-Based Routing, Path-Based Routing, TLS Termination, and Annotations
**Intermediate Kubernetes — Module 6 of 13**

---

## Lab Overview

### What You Will Do

- Verify the Ingress controller and deploy sample applications
- Configure host-based and path-based routing
- Set up TLS termination with a self-signed certificate
- Explore Ingress annotations (rewrite, rate limiting, CORS, custom headers)
- *Optional:* Create Gateway API resources for weighted traffic splitting
- *Optional:* Apply an egress NetworkPolicy to restrict outbound traffic

### Prerequisites

- Completion of Lab 1 with `kubectl` and cluster access configured
- Ingress controller installed (NGINX or AWS ALB)

### Duration

Approximately 30-40 minutes

> **Note:** Steps 8-9 are optional stretch goals for students who finish early.

---

## Environment Setup

```bash
cd ~/environment/verisign_k8s/labs/lab-06
export STUDENT_NAME=<your-name>
echo "Student: $STUDENT_NAME"
kubectl config set-context --current --namespace=default
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

<!-- Creates a Deployment and Service for app v1 (http-echo) -->

Apply the manifest:

```bash
envsubst < app-v1.yaml | kubectl apply -f -
```

### Deploy app-v2

<!-- Creates a Deployment and Service for app v2 (http-echo) -->

Apply the manifest:

```bash
envsubst < app-v2.yaml | kubectl apply -f -
kubectl get pods -n lab06-$STUDENT_NAME -l app=web
kubectl get svc -n lab06-$STUDENT_NAME
```

> ✅ **Checkpoint:** 4 pods (2 for v1, 2 for v2) Running and 2 ClusterIP services.

---

## Step 3: Create a Host-Based Ingress

<!-- Creates an Ingress with host-based routing for v1 and v2 -->

Apply the manifest:

```bash
envsubst < ingress-host.yaml | kubectl apply -f -
```

---

## Step 4: Test Host-Based Routing

```bash
INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-ingress-nginx-controller \
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

<!-- Creates an Ingress with path-based routing (/v1, /v2, /) -->

Apply the manifest:

```bash
envsubst < ingress-path.yaml | kubectl apply -f -

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
    -subj "/CN=*.lab.local/O=Lab"

kubectl create secret tls lab-tls-secret \
    --cert=tls-ingress.crt --key=tls-ingress.key -n lab06-$STUDENT_NAME
```

<!-- Creates an Ingress with TLS termination and SSL redirect -->

Apply the manifest:

```bash
envsubst < ingress-tls.yaml | kubectl apply -f -

curl -sk -H "Host: secure-$STUDENT_NAME.lab.local" https://$INGRESS_IP
curl -sI -H "Host: secure-$STUDENT_NAME.lab.local" http://$INGRESS_IP
```

> ✅ **Checkpoint:** HTTPS returns `Hello from App V1`. HTTP returns a `308 Permanent Redirect` to HTTPS.

---

## Step 7: Explore Ingress Annotations

<!-- Creates an Ingress with rewrite, rate limiting, CORS, and custom headers -->

Create the custom headers ConfigMap and apply the Ingress:

```bash
kubectl create configmap custom-headers \
    --from-literal=X-Served-By=lab-eks \
    -n lab06-$STUDENT_NAME

envsubst < ingress-annotations.yaml | kubectl apply -f -

curl -s -H "Host: api-$STUDENT_NAME.lab.local" http://$INGRESS_IP/api/

# Check CORS and custom headers
curl -sI -H "Host: api-$STUDENT_NAME.lab.local" \
    -H "Origin: https://app.example.com" \
    http://$INGRESS_IP/api/ 2>&1 | grep -iE "access-control|X-Served"

# Test rate limiting
for i in $(seq 1 15); do
    curl -s -o /dev/null -w "%{http_code} " \
        -H "Host: api-$STUDENT_NAME.lab.local" http://$INGRESS_IP/api/
done
echo ""
```

> ✅ **Checkpoint:** CORS and custom headers appear. After 10 rapid requests, excess requests return `503`.

---

---

## Optional Stretch Goals

> These exercises cover additional topics from the presentation. Complete them if you finish the core lab early.

### Step 8: Gateway API (Conditional)

> The Gateway API is the next-generation replacement for Ingress. This step requires the Gateway API CRDs to be installed.

```bash
# Check if Gateway API CRDs are available
kubectl get crd gatewayclasses.gateway.networking.k8s.io
```

If available, apply the Gateway and HTTPRoute:

```bash
envsubst < gateway.yaml | kubectl apply -f -
envsubst < httproute.yaml | kubectl apply -f -

# Verify the HTTPRoute with weighted traffic splitting
kubectl get httproute app-route -n lab06-$STUDENT_NAME -o yaml
```

> ✅ **Checkpoint:** The HTTPRoute sends 80% of traffic to app-v1-svc and 20% to app-v2-svc.

> If Gateway API CRDs are not installed, skip this step.

---

## Step 9: Egress NetworkPolicy

Create a NetworkPolicy that restricts outbound traffic:

```bash
envsubst < egress-policy.yaml | kubectl apply -f -

kubectl get networkpolicy restrict-egress -n lab06-$STUDENT_NAME
kubectl describe networkpolicy restrict-egress -n lab06-$STUDENT_NAME
```

> ✅ **Checkpoint:** The policy selects pods with `run=egress-test`, allows DNS (port 53) and HTTPS (port 443) egress only.

---

## Step 10: Clean Up

```bash
# Clean up cluster-scoped GatewayClass (if created)
kubectl delete gatewayclass lab-gateway-class-$STUDENT_NAME 2>/dev/null

kubectl delete namespace lab06-$STUDENT_NAME

rm -f tls-ingress.key tls-ingress.crt
```

---

## Summary

- **Host-Based Routing:** Route traffic to different backends based on the `Host` header
- **Path-Based Routing:** Route traffic to different backends based on the URL path
- **TLS Termination:** Terminate HTTPS at the Ingress controller with SSL redirect
- **Annotations:** Controller-specific annotations for rewrite-target, rate limiting, CORS, and custom headers
- **Gateway API:** Next-generation routing with GatewayClass, Gateway, and HTTPRoute resources
- **Egress Policy:** Restrict outbound traffic with NetworkPolicy egress rules

---

*Lab 6 Complete — Up Next: Lab 7 — RBAC, Security, and IRSA*
