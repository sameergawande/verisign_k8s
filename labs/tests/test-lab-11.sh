#!/bin/bash
###############################################################################
# Lab 11 Test: Deployment Strategies
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/../lab-11" && pwd)"
source "$SCRIPT_DIR/lib.sh"

export STUDENT_NAME="test-$$"
NS="deploy-lab-$STUDENT_NAME"
echo "=== Lab 11: Deployment Strategies (ns: $NS) ==="
echo ""

kubectl create namespace "$NS" &>/dev/null

# ─── Rolling update ────────────────────────────────────────────────────────

echo "Rolling Update:"
envsubst < "$LAB_DIR/app-deploy-v1.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" webapp 90

V1_IMAGE=$(kubectl get deployment webapp -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
assert_contains "v1 deployed with nginx 1.24" "$V1_IMAGE" "1.24"

STRATEGY=$(kubectl get deployment webapp -n "$NS" -o jsonpath='{.spec.strategy.type}' 2>/dev/null)
assert_eq "strategy is RollingUpdate" "RollingUpdate" "$STRATEGY"

# Update to v2
kubectl set image deployment/webapp nginx=nginx:1.25 -n "$NS" &>/dev/null
wait_for_deploy "$NS" webapp 90

V2_IMAGE=$(kubectl get deployment webapp -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
assert_contains "rolled to nginx 1.25" "$V2_IMAGE" "1.25"

# Rollback
kubectl rollout undo deployment/webapp -n "$NS" &>/dev/null
wait_for_deploy "$NS" webapp 90

ROLLBACK_IMAGE=$(kubectl get deployment webapp -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
assert_contains "rollback to nginx 1.24" "$ROLLBACK_IMAGE" "1.24"

REVISIONS=$(kubectl rollout history deployment/webapp -n "$NS" 2>/dev/null | grep -c "^[0-9]" || true)
if [ "$REVISIONS" -ge 3 ]; then
  pass "rollout history has $REVISIONS revisions"
else
  fail "expected at least 3 revisions, got $REVISIONS"
fi

# ─── Blue-Green ─────────────────────────────────────────────────────────────

echo ""
echo "Blue-Green:"
envsubst < "$LAB_DIR/blue-deploy.yaml" | kubectl apply -f - &>/dev/null
envsubst < "$LAB_DIR/green-deploy.yaml" | kubectl apply -f - &>/dev/null
envsubst < "$LAB_DIR/bg-service.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" webapp-blue 90
wait_for_deploy "$NS" webapp-green 90

SVC_SEL=$(kubectl get svc webapp-bg-svc -n "$NS" -o jsonpath='{.spec.selector.version}' 2>/dev/null)
assert_eq "service initially selects blue" "blue" "$SVC_SEL"

# Switch to green
kubectl patch svc webapp-bg-svc -n "$NS" -p '{"spec":{"selector":{"version":"green"}}}' &>/dev/null
SVC_SEL_NEW=$(kubectl get svc webapp-bg-svc -n "$NS" -o jsonpath='{.spec.selector.version}' 2>/dev/null)
assert_eq "service switched to green" "green" "$SVC_SEL_NEW"

# ─── Canary ─────────────────────────────────────────────────────────────────

echo ""
echo "Canary:"
envsubst < "$LAB_DIR/canary-stable.yaml" | kubectl apply -f - &>/dev/null
envsubst < "$LAB_DIR/canary-new.yaml" | kubectl apply -f - &>/dev/null
envsubst < "$LAB_DIR/canary-service.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" webapp-stable 90
wait_for_deploy "$NS" webapp-canary 90

STABLE_REPLICAS=$(kubectl get deployment webapp-stable -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
CANARY_REPLICAS=$(kubectl get deployment webapp-canary -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
assert_eq "stable has 2 replicas" "2" "$STABLE_REPLICAS"
assert_eq "canary has 1 replica" "1" "$CANARY_REPLICAS"

# ─── PDB ────────────────────────────────────────────────────────────────────

echo ""
echo "Pod Disruption Budget:"
envsubst < "$LAB_DIR/pdb.yaml" | kubectl apply -f - &>/dev/null
sleep 3

PDB_MIN=$(kubectl get pdb webapp-pdb -n "$NS" -o jsonpath='{.spec.minAvailable}' 2>/dev/null)
assert_eq "PDB minAvailable is 2" "2" "$PDB_MIN"

# ─── Cleanup ────────────────────────────────────────────────────────────────

cleanup_ns "$NS"
summary
