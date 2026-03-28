#!/bin/bash
###############################################################################
# Lab 6 Test: Ingress and Gateway API
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/../lab-06" && pwd)"
source "$SCRIPT_DIR/lib.sh"

export STUDENT_NAME="test-$$"
NS="lab06-$STUDENT_NAME"
echo "=== Lab 6: Ingress & Gateway API (ns: $NS) ==="
echo ""

kubectl create namespace "$NS" &>/dev/null

# ─── Deploy apps ───────────────────────────────────────────────────────────

echo "Application Deployment:"
envsubst < "$LAB_DIR/app-v1.yaml" | kubectl apply -f - &>/dev/null
envsubst < "$LAB_DIR/app-v2.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" app-v1 90
wait_for_deploy "$NS" app-v2 90

V1_READY=$(kubectl get deployment app-v1 -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
assert_eq "app-v1 has 2 replicas" "2" "$V1_READY"

V2_READY=$(kubectl get deployment app-v2 -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
assert_eq "app-v2 has 2 replicas" "2" "$V2_READY"

# ─── Ingress ───────────────────────────────────────────────────────────────

echo ""
echo "Ingress Resources:"
if kubectl get pods -n ingress-nginx --no-headers 2>/dev/null | grep -q Running; then
  envsubst < "$LAB_DIR/ingress-host.yaml" | kubectl apply -f - &>/dev/null
  sleep 3
  ING_HOST=$(kubectl get ingress -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "host-based ingress created" "1" "$ING_HOST"

  INGRESS_IP=$(kubectl get svc -n ingress-nginx -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  if [ -n "$INGRESS_IP" ]; then
    pass "ingress controller has external address"
  else
    skip "ingress controller has no external address (internal testing only)"
  fi

  envsubst < "$LAB_DIR/ingress-path.yaml" | kubectl apply -f - &>/dev/null
  sleep 3
  ING_COUNT=$(kubectl get ingress -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$ING_COUNT" -ge 2 ]; then
    pass "path-based ingress created"
  else
    fail "path-based ingress not created"
  fi

  envsubst < "$LAB_DIR/ingress-tls.yaml" | kubectl apply -f - &>/dev/null
  sleep 3
  TLS_ING=$(kubectl get ingress -n "$NS" -o jsonpath='{.items[?(@.metadata.name=="app-ingress-tls")].spec.tls}' 2>/dev/null)
  assert_contains "TLS ingress has tls config" "$TLS_ING" "secretName"
else
  skip "ingress-nginx not running — skipping ingress tests"
fi

# ─── Gateway API ───────────────────────────────────────────────────────────

echo ""
echo "Gateway API:"
if kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null; then
  envsubst < "$LAB_DIR/gateway.yaml" | kubectl apply -f - &>/dev/null
  sleep 5
  GW=$(kubectl get gateway -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "gateway resource created" "1" "$GW"

  envsubst < "$LAB_DIR/httproute.yaml" | kubectl apply -f - &>/dev/null
  sleep 3
  HR=$(kubectl get httproute -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "httproute resource created" "1" "$HR"
else
  skip "gateway API CRDs not installed"
fi

# ─── Egress NetworkPolicy ──────────────────────────────────────────────────

echo ""
echo "Egress Policy:"
envsubst < "$LAB_DIR/egress-policy.yaml" | kubectl apply -f - &>/dev/null
sleep 3
NP=$(kubectl get networkpolicy -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$NP" -ge 1 ]; then
  pass "egress network policy created"
else
  fail "egress network policy not created"
fi

# ─── Cleanup ────────────────────────────────────────────────────────────────

kubectl delete gatewayclass "lab-gateway-class-$STUDENT_NAME" &>/dev/null 2>&1 || true
cleanup_ns "$NS"
summary
