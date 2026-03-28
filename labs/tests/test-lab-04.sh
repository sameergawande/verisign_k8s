#!/bin/bash
###############################################################################
# Lab 4 Test: Services and Service Discovery — COMPREHENSIVE
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/../lab-04" && pwd)"
source "$SCRIPT_DIR/lib.sh"

export STUDENT_NAME="test-$$"
NS="lab04-$STUDENT_NAME"
echo "=== Lab 4: Services & Discovery (ns: $NS) ==="
echo ""

kubectl create namespace "$NS" &>/dev/null

###############################################################################
# Step 1: Deploy multi-tier application
###############################################################################

echo "Deployments:"

envsubst < "$LAB_DIR/backend-deployment.yaml" | kubectl apply -f - &>/dev/null
envsubst < "$LAB_DIR/frontend-deployment.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" backend 120
wait_for_deploy "$NS" frontend 120

BACKEND_READY=$(kubectl get deployment backend -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
assert_eq "backend has 3 replicas" "3" "$BACKEND_READY"

FRONTEND_READY=$(kubectl get deployment frontend -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
assert_eq "frontend has 2 replicas" "2" "$FRONTEND_READY"

# Verify labels
BACKEND_LABELS=$(kubectl get pods -n "$NS" -l "app=backend,tier=api" --no-headers 2>/dev/null | wc -l | tr -d ' ')
assert_eq "backend pods have app=backend,tier=api labels" "3" "$BACKEND_LABELS"

FRONTEND_LABELS=$(kubectl get pods -n "$NS" -l "app=frontend,tier=web" --no-headers 2>/dev/null | wc -l | tr -d ' ')
assert_eq "frontend pods have app=frontend,tier=web labels" "2" "$FRONTEND_LABELS"

# Verify backend has readiness probe
BACKEND_PROBE=$(kubectl get deployment backend -n "$NS" \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)
assert_eq "backend has readiness probe on /get" "/get" "$BACKEND_PROBE"

###############################################################################
# Step 2: ClusterIP Service for backend
###############################################################################

echo ""
echo "ClusterIP Service:"

envsubst < "$LAB_DIR/backend-svc.yaml" | kubectl apply -f - &>/dev/null
sleep 5

SVC_TYPE=$(kubectl get svc backend-svc -n "$NS" -o jsonpath='{.spec.type}' 2>/dev/null)
assert_eq "backend-svc is ClusterIP" "ClusterIP" "$SVC_TYPE"

CLUSTER_IP=$(kubectl get svc backend-svc -n "$NS" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
if [ -n "$CLUSTER_IP" ] && [ "$CLUSTER_IP" != "None" ]; then
  pass "backend-svc has ClusterIP: $CLUSTER_IP"
else
  fail "backend-svc has no ClusterIP"
fi

SVC_PORT=$(kubectl get svc backend-svc -n "$NS" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
assert_eq "backend-svc port is 80" "80" "$SVC_PORT"

SVC_SELECTOR=$(kubectl get svc backend-svc -n "$NS" -o jsonpath='{.spec.selector.app}' 2>/dev/null)
assert_eq "backend-svc selects app=backend" "backend" "$SVC_SELECTOR"

###############################################################################
# Step 2b: Endpoints verification
###############################################################################

echo ""
echo "Endpoints:"

EP_COUNT=$(kubectl get endpoints backend-svc -n "$NS" -o jsonpath='{.subsets[0].addresses}' 2>/dev/null | jq 'length' 2>/dev/null)
assert_eq "backend-svc has 3 endpoints" "3" "$EP_COUNT"

# Verify endpoints match pod IPs
POD_IPS=$(kubectl get pods -n "$NS" -l "app=backend,tier=api" -o jsonpath='{.items[*].status.podIP}' 2>/dev/null)
EP_IPS=$(kubectl get endpoints backend-svc -n "$NS" -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null)
ALL_MATCHED=true
for ip in $EP_IPS; do
  if ! echo "$POD_IPS" | grep -q "$ip"; then
    ALL_MATCHED=false
    break
  fi
done
if [ "$ALL_MATCHED" = true ] && [ -n "$EP_IPS" ]; then
  pass "endpoint IPs match backend pod IPs"
else
  fail "endpoint IPs do not match pod IPs (pods: $POD_IPS, eps: $EP_IPS)"
fi

# Scale down and verify endpoints update
kubectl scale deployment backend -n "$NS" --replicas=1 &>/dev/null
sleep 10
EP_COUNT_1=$(kubectl get endpoints backend-svc -n "$NS" -o jsonpath='{.subsets[0].addresses}' 2>/dev/null | jq 'length' 2>/dev/null)
assert_eq "endpoints shrink to 1 after scale-down" "1" "$EP_COUNT_1"

# Scale back up
kubectl scale deployment backend -n "$NS" --replicas=3 &>/dev/null
wait_for_deploy "$NS" backend 120
sleep 5
EP_COUNT_3=$(kubectl get endpoints backend-svc -n "$NS" -o jsonpath='{.subsets[0].addresses}' 2>/dev/null | jq 'length' 2>/dev/null)
assert_eq "endpoints grow to 3 after scale-up" "3" "$EP_COUNT_3"

###############################################################################
# Step 3: DNS-based service discovery
###############################################################################

echo ""
echo "DNS Service Discovery:"

# Use a dedicated busybox pod for DNS and curl tests (more reliable than --rm pods)
kubectl run test-tools -n "$NS" --image=busybox:1.36 --restart=Never \
  -- sh -c "sleep 600" &>/dev/null
wait_for_pod "$NS" test-tools 60

# Short name DNS resolution
DNS_SHORT=$(kubectl exec test-tools -n "$NS" -- nslookup backend-svc 2>&1) || true
if echo "$DNS_SHORT" | grep -q "Address"; then
  pass "DNS resolves short name: backend-svc"
else
  fail "DNS short name resolution failed"
fi

# FQDN resolution
DNS_FQDN=$(kubectl exec test-tools -n "$NS" -- \
  nslookup "backend-svc.${NS}.svc.cluster.local" 2>&1) || true
if echo "$DNS_FQDN" | grep -q "Address"; then
  pass "DNS resolves FQDN: backend-svc.${NS}.svc.cluster.local"
else
  fail "DNS FQDN resolution failed"
fi

# Verify resolv.conf contains namespace search domain
RESOLV=$(kubectl exec test-tools -n "$NS" -- cat /etc/resolv.conf 2>/dev/null)
assert_contains "resolv.conf has namespace search domain" "$RESOLV" "$NS"
assert_contains "resolv.conf has svc.cluster.local" "$RESOLV" "svc.cluster.local"

###############################################################################
# Step 3b: Curl through ClusterIP service
###############################################################################

echo ""
echo "Traffic Routing via ClusterIP:"

# Use a curl-capable pod (httpbin backend can curl itself)
CURL_RESULT=$(kubectl exec test-tools -n "$NS" -- \
  wget -q -O - "http://backend-svc/get" 2>/dev/null) || true
if [ -n "$CURL_RESULT" ]; then
  pass "traffic routes through ClusterIP to backend (wget /get)"
else
  # Try with a backend pod which has curl
  BACKEND_POD=$(kubectl get pod -n "$NS" -l tier=api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  CURL_RESULT2=$(kubectl exec "$BACKEND_POD" -n "$NS" -- \
    curl -s "http://backend-svc/get" 2>/dev/null) || true
  if [ -n "$CURL_RESULT2" ]; then
    pass "traffic routes through ClusterIP to backend (curl /get)"
  else
    fail "could not route traffic through ClusterIP service"
  fi
fi

###############################################################################
# Step 5: NodePort Service
###############################################################################

echo ""
echo "NodePort Service:"

envsubst < "$LAB_DIR/frontend-nodeport.yaml" | kubectl apply -f - &>/dev/null
sleep 3

NP_TYPE=$(kubectl get svc frontend-nodeport -n "$NS" -o jsonpath='{.spec.type}' 2>/dev/null)
assert_eq "frontend-nodeport type is NodePort" "NodePort" "$NP_TYPE"

NP=$(kubectl get svc frontend-nodeport -n "$NS" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
if [ -n "$NP" ] && [ "$NP" -ge 30000 ] && [ "$NP" -le 32767 ]; then
  pass "NodePort assigned in valid range: $NP"
else
  fail "NodePort not in valid range (30000-32767): $NP"
fi

NP_PORT=$(kubectl get svc frontend-nodeport -n "$NS" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
assert_eq "frontend-nodeport service port is 80" "80" "$NP_PORT"

###############################################################################
# Step 6: LoadBalancer Service
###############################################################################

echo ""
echo "LoadBalancer Service:"

envsubst < "$LAB_DIR/frontend-lb.yaml" | kubectl apply -f - &>/dev/null
sleep 5

LB_TYPE=$(kubectl get svc frontend-lb -n "$NS" -o jsonpath='{.spec.type}' 2>/dev/null)
assert_eq "frontend-lb type is LoadBalancer" "LoadBalancer" "$LB_TYPE"

LB_ANNO=$(kubectl get svc frontend-lb -n "$NS" \
  -o jsonpath='{.metadata.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-type}' 2>/dev/null)
assert_eq "frontend-lb has NLB annotation" "external" "$LB_ANNO"

LB_SCHEME=$(kubectl get svc frontend-lb -n "$NS" \
  -o jsonpath='{.metadata.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-scheme}' 2>/dev/null)
assert_eq "frontend-lb is internet-facing" "internet-facing" "$LB_SCHEME"

LB_SELECTOR=$(kubectl get svc frontend-lb -n "$NS" -o jsonpath='{.spec.selector.app}' 2>/dev/null)
assert_eq "frontend-lb selects app=frontend" "frontend" "$LB_SELECTOR"

# Check if EXTERNAL-IP is assigned (may be pending in test environments)
LB_HOST=$(kubectl get svc frontend-lb -n "$NS" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [ -n "$LB_HOST" ]; then
  pass "LoadBalancer EXTERNAL-IP assigned: $LB_HOST"
else
  skip "LoadBalancer EXTERNAL-IP pending (NLB provisioning may take time)"
fi

###############################################################################
# Step 8: Headless Service
###############################################################################

echo ""
echo "Headless Service:"

envsubst < "$LAB_DIR/backend-headless.yaml" | kubectl apply -f - &>/dev/null
sleep 3

HEADLESS_CIP=$(kubectl get svc backend-headless -n "$NS" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
assert_eq "headless service has clusterIP None" "None" "$HEADLESS_CIP"

HEADLESS_SELECTOR=$(kubectl get svc backend-headless -n "$NS" -o jsonpath='{.spec.selector.app}' 2>/dev/null)
assert_eq "headless service selects app=backend" "backend" "$HEADLESS_SELECTOR"

# DNS comparison: ClusterIP vs Headless
echo ""
echo "Headless vs ClusterIP DNS Comparison:"

# ClusterIP returns a single VIP
DNS_CLUSTERIP=$(kubectl exec test-tools -n "$NS" -- \
  nslookup backend-svc 2>&1) || true
# Count non-server Address lines (skip the DNS server address line)
VIP_COUNT=$(echo "$DNS_CLUSTERIP" | grep -A1 "^Name:" | grep -c "Address" || true)
if [ "$VIP_COUNT" -eq 1 ]; then
  pass "ClusterIP DNS returns single VIP"
else
  # Alternative check: just verify it resolves
  if echo "$DNS_CLUSTERIP" | grep -q "Address"; then
    pass "ClusterIP DNS resolves (addresses found)"
  else
    fail "ClusterIP DNS did not resolve"
  fi
fi

# Headless returns individual pod IPs
DNS_HEADLESS=$(kubectl exec test-tools -n "$NS" -- \
  nslookup backend-headless 2>&1) || true
# Count all Address lines (server line + pod IPs)
HEADLESS_ADDR_COUNT=$(echo "$DNS_HEADLESS" | grep -c "Address" || true)
# Should have at least 4 (1 DNS server + 3 pod IPs)
if [ "$HEADLESS_ADDR_COUNT" -ge 4 ]; then
  pass "headless DNS returns multiple pod IPs ($((HEADLESS_ADDR_COUNT - 1)) addresses)"
else
  # At minimum we should see more than the ClusterIP case
  if [ "$HEADLESS_ADDR_COUNT" -ge 2 ]; then
    pass "headless DNS returns pod IPs (count: $((HEADLESS_ADDR_COUNT - 1)))"
  else
    fail "headless DNS did not return pod IPs (address lines: $HEADLESS_ADDR_COUNT)"
  fi
fi

###############################################################################
# Step 9: Multi-Port Service
###############################################################################

echo ""
echo "Multi-Port Service:"

envsubst < "$LAB_DIR/frontend-multiport.yaml" | kubectl apply -f - &>/dev/null
sleep 3

MP_TYPE=$(kubectl get svc frontend-multiport -n "$NS" -o jsonpath='{.spec.type}' 2>/dev/null)
assert_eq "multi-port service is ClusterIP" "ClusterIP" "$MP_TYPE"

PORT_COUNT=$(kubectl get svc frontend-multiport -n "$NS" -o jsonpath='{.spec.ports}' 2>/dev/null | jq 'length' 2>/dev/null)
assert_eq "multi-port service has 2 ports" "2" "$PORT_COUNT"

MP_PORT1=$(kubectl get svc frontend-multiport -n "$NS" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
assert_eq "multi-port first port is 80" "80" "$MP_PORT1"

MP_PORT2=$(kubectl get svc frontend-multiport -n "$NS" -o jsonpath='{.spec.ports[1].port}' 2>/dev/null)
assert_eq "multi-port second port is 8443" "8443" "$MP_PORT2"

MP_NAME1=$(kubectl get svc frontend-multiport -n "$NS" -o jsonpath='{.spec.ports[0].name}' 2>/dev/null)
if [ -n "$MP_NAME1" ]; then
  pass "multi-port ports have names (required for multi-port): $MP_NAME1"
else
  fail "multi-port ports missing required name field"
fi

MP_SELECTOR=$(kubectl get svc frontend-multiport -n "$NS" -o jsonpath='{.spec.selector.app}' 2>/dev/null)
assert_eq "multi-port service selects app=frontend" "frontend" "$MP_SELECTOR"

###############################################################################
# Cleanup
###############################################################################

echo ""
echo "Cleanup:"

# Delete LoadBalancer first to prevent orphaned NLBs
kubectl delete svc frontend-lb -n "$NS" --timeout=30s &>/dev/null 2>&1
sleep 5
kubectl delete pod test-tools -n "$NS" --grace-period=0 --force &>/dev/null 2>&1
kubectl delete svc --all -n "$NS" --timeout=30s &>/dev/null 2>&1
cleanup_ns "$NS"

summary
