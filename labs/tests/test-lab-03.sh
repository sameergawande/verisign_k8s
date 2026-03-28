#!/bin/bash
###############################################################################
# Lab 3 Test: Storage and StatefulSets
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/../lab-03" && pwd)"
source "$SCRIPT_DIR/lib.sh"

export STUDENT_NAME="test-$$"
NS="lab03-$STUDENT_NAME"
echo "=== Lab 3: Storage & StatefulSets (ns: $NS) ==="
echo ""

kubectl create namespace "$NS" &>/dev/null

# ─── PVC ────────────────────────────────────────────────────────────────────

echo "PersistentVolumeClaim:"
envsubst < "$LAB_DIR/lab-pvc.yaml" | kubectl apply -f - &>/dev/null
sleep 3

# PVC may be Pending (WaitForFirstConsumer) until a pod claims it
PVC_STATUS=$(kubectl get pvc lab-data-pvc -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
if [ "$PVC_STATUS" = "Bound" ] || [ "$PVC_STATUS" = "Pending" ]; then
  pass "PVC created (status: $PVC_STATUS)"
else
  fail "PVC status unexpected: $PVC_STATUS"
fi

# ─── Writer pod ─────────────────────────────────────────────────────────────

echo ""
echo "Data Persistence:"
envsubst < "$LAB_DIR/lab-writer-pod.yaml" | kubectl apply -f - &>/dev/null
wait_for_pod "$NS" data-writer 90
sleep 5

WRITTEN=$(kubectl exec data-writer -n "$NS" -- cat /data/testfile.txt 2>/dev/null)
assert_contains "writer pod wrote data" "$WRITTEN" "Written at"

# Delete writer, verify data persists via reader
kubectl delete pod data-writer -n "$NS" --timeout=30s &>/dev/null
envsubst < "$LAB_DIR/lab-reader-pod.yaml" | kubectl apply -f - &>/dev/null
wait_for_pod "$NS" data-reader 90

READ=$(kubectl exec data-reader -n "$NS" -- cat /data/testfile.txt 2>/dev/null)
assert_contains "data persists after pod deletion" "$READ" "Written at"

PVC_STATUS=$(kubectl get pvc lab-data-pvc -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
assert_eq "PVC is Bound" "Bound" "$PVC_STATUS"

# ─── StatefulSet ────────────────────────────────────────────────────────────

echo ""
echo "StatefulSet:"
envsubst < "$LAB_DIR/lab-headless-svc.yaml" | kubectl apply -f - &>/dev/null
envsubst < "$LAB_DIR/lab-statefulset.yaml" | kubectl apply -f - &>/dev/null

# Wait for all 3 pods
kubectl rollout status statefulset/web -n "$NS" --timeout=180s &>/dev/null
READY=$(kubectl get statefulset web -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
assert_eq "StatefulSet has 3 ready replicas" "3" "$READY"

# Check stable pod names
POD0=$(kubectl get pod web-0 -n "$NS" -o jsonpath='{.metadata.name}' 2>/dev/null)
assert_eq "stable pod name web-0" "web-0" "$POD0"

# Check each pod has its own PVC
PVC_COUNT=$(kubectl get pvc -n "$NS" -l app=web --no-headers 2>/dev/null | wc -l | tr -d ' ')
assert_eq "each pod has own PVC (3 total)" "3" "$PVC_COUNT"

# ─── Cleanup ────────────────────────────────────────────────────────────────

# StatefulSets don't delete PVCs automatically
kubectl delete statefulset web -n "$NS" &>/dev/null
kubectl delete pvc -l app=web -n "$NS" &>/dev/null
cleanup_ns "$NS"
summary
