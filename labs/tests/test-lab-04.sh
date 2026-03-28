#!/bin/bash
###############################################################################
# Lab 4 Test: Services and Service Discovery
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/../lab-04" && pwd)"
source "$SCRIPT_DIR/lib.sh"

export STUDENT_NAME="test-$$"
NS="lab04-$STUDENT_NAME"
echo "=== Lab 4: Services & Discovery (ns: $NS) ==="
echo ""

kubectl create namespace "$NS" &>/dev/null

# ─── Deploy backend and frontend ───────────────────────────────────────────

echo "Deployments:"
envsubst < "$LAB_DIR/backendment.yaml" | kubectl apply -f - &>/dev/null
envsubst < "$LAB_DIR/frontendment.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" backend 90
wait_for_deploy "$NS" frontend 90

BACKEND_READY=$(kubectl get deployment backend -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
assert_eq "backend has 3 replicas" "3" "$BACKEND_READY"

FRONTEND_READY=$(kubectl get deployment frontend -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
assert_eq "frontend has 2 replicas" "2" "$FRONTEND_READY"

# ─── ClusterIP service ─────────────────────────────────────────────────────

echo ""
echo "ClusterIP Service:"
envsubst < "$LAB_DIR/backend-svc.yaml" | kubectl apply -f - &>/dev/null
sleep 3

SVC_TYPE=$(kubectl get svc backend-svc -n "$NS" -o jsonpath='{.spec.type}' 2>/dev/null)
assert_eq "backend-svc is ClusterIP" "ClusterIP" "$SVC_TYPE"

EP_COUNT=$(kubectl get endpoints backend-svc -n "$NS" -o jsonpath='{.subsets[0].addresses}' 2>/dev/null | jq 'length' 2>/dev/null)
assert_eq "backend-svc has 3 endpoints" "3" "$EP_COUNT"

# DNS resolution from a test pod
DNS_RESULT=$(kubectl run dns-test --image=busybox:1.36 --rm -it --restart=Never -n "$NS" \
  -- nslookup backend-svc 2>/dev/null | grep -c "Address" || true)
if [ "$DNS_RESULT" -ge 1 ]; then
  pass "DNS resolves backend-svc"
else
  fail "DNS lookup failed for backend-svc"
fi

# ─── NodePort service ──────────────────────────────────────────────────────

echo ""
echo "NodePort Service:"
envsubst < "$LAB_DIR/frontend-nodeport.yaml" | kubectl apply -f - &>/dev/null
sleep 3

NP=$(kubectl get svc frontend-nodeport -n "$NS" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
if [ -n "$NP" ] && [ "$NP" -ge 30000 ]; then
  pass "NodePort assigned: $NP"
else
  fail "NodePort not assigned"
fi

# ─── Headless service ──────────────────────────────────────────────────────

echo ""
echo "Headless Service:"
envsubst < "$LAB_DIR/backend-headless.yaml" | kubectl apply -f - &>/dev/null
sleep 3

CLUSTER_IP=$(kubectl get svc backend-headless -n "$NS" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
assert_eq "headless service has clusterIP None" "None" "$CLUSTER_IP"

# ─── Multi-port service ────────────────────────────────────────────────────

echo ""
echo "Multi-Port Service:"
envsubst < "$LAB_DIR/frontend-multiport.yaml" | kubectl apply -f - &>/dev/null
sleep 3

PORT_COUNT=$(kubectl get svc frontend-multiport -n "$NS" -o jsonpath='{.spec.ports}' 2>/dev/null | jq 'length' 2>/dev/null)
assert_eq "multi-port service has 2 ports" "2" "$PORT_COUNT"

# ─── Cleanup ────────────────────────────────────────────────────────────────

# Delete LB service first to avoid orphaned NLB
kubectl delete svc -n "$NS" --all &>/dev/null
sleep 5
cleanup_ns "$NS"
summary
