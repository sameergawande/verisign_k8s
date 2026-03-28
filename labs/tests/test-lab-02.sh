#!/bin/bash
###############################################################################
# Lab 2 Test: Autoscaling
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/../lab-02" && pwd)"
source "$SCRIPT_DIR/lib.sh"

export STUDENT_NAME="test-$$"
NS="lab02-$STUDENT_NAME"
echo "=== Lab 2: Autoscaling (ns: $NS) ==="
echo ""

kubectl create namespace "$NS" &>/dev/null

# ─── PHP Apache deployment + HPA ───────────────────────────────────────────

echo "HPA Setup:"
envsubst < "$LAB_DIR/php-apache-deployment.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" php-apache 90
assert_cmd "php-apache deployment ready" kubectl rollout status deployment/php-apache -n "$NS" --timeout=10s

kubectl autoscale deployment php-apache --cpu-percent=50 --min=1 --max=10 -n "$NS" &>/dev/null
sleep 5

HPA=$(kubectl get hpa php-apache -n "$NS" -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)
assert_eq "HPA max replicas is 10" "10" "$HPA"

HPA_TARGET=$(kubectl get hpa php-apache -n "$NS" -o jsonpath='{.spec.metrics[0].resource.name}' 2>/dev/null)
assert_eq "HPA targets cpu" "cpu" "$HPA_TARGET"

# ─── HPA v2 ─────────────────────────────────────────────────────────────────

echo ""
echo "HPA v2:"
envsubst < "$LAB_DIR/hpa-v2.yaml" | kubectl apply -f - &>/dev/null
sleep 3
HPA_V2=$(kubectl get hpa php-apache-v2 -n "$NS" -o jsonpath='{.spec.metrics}' 2>/dev/null)
assert_contains "HPA v2 has metrics defined" "$HPA_V2" "cpu"

BEHAVIOR=$(kubectl get hpa php-apache-v2 -n "$NS" -o jsonpath='{.spec.behavior.scaleDown.stabilizationWindowSeconds}' 2>/dev/null)
assert_eq "HPA v2 scale-down window is 300s" "300" "$BEHAVIOR"

# ─── VPA ─────────────────────────────────────────────────────────────────────

echo ""
echo "VPA:"
if kubectl api-resources | grep -q verticalpodautoscalers; then
  envsubst < "$LAB_DIR/vpa.yaml" | kubectl apply -f - &>/dev/null
  sleep 3
  VPA_MODE=$(kubectl get vpa php-apache-vpa -n "$NS" -o jsonpath='{.spec.updatePolicy.updateMode}' 2>/dev/null)
  assert_eq "VPA update mode is Off" "Off" "$VPA_MODE"
else
  skip "VPA CRD not installed"
fi

# ─── Cleanup ────────────────────────────────────────────────────────────────

cleanup_ns "$NS"
summary
