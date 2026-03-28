#!/bin/bash
###############################################################################
# Lab 10 Test: Health Checks and Probes
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/../lab-10" && pwd)"
source "$SCRIPT_DIR/lib.sh"

export STUDENT_NAME="test-$$"
NS="probes-lab-$STUDENT_NAME"
echo "=== Lab 10: Health Probes (ns: $NS) ==="
echo ""

kubectl create namespace "$NS" &>/dev/null

# ─── No probes (baseline) ──────────────────────────────────────────────────

echo "No Probes (baseline):"
envsubst < "$LAB_DIR/no-probes-app.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" no-probes-app 60
assert_cmd "no-probes deployment running" kubectl rollout status deployment/no-probes-app -n "$NS" --timeout=10s

# ─── Liveness probe ────────────────────────────────────────────────────────

echo ""
echo "Liveness Probe:"
envsubst < "$LAB_DIR/liveness-http.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" liveness-http 60

LIVENESS=$(kubectl get deployment liveness-http -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.path}' 2>/dev/null)
assert_eq "liveness probe path set" "/" "$LIVENESS"

# ─── Readiness probe ───────────────────────────────────────────────────────

echo ""
echo "Readiness Probe:"
envsubst < "$LAB_DIR/readiness-app.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" readiness-app 60

READINESS=$(kubectl get deployment readiness-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)
assert_eq "readiness probe path set" "/ready" "$READINESS"

# ─── Startup probe ─────────────────────────────────────────────────────────

echo ""
echo "Startup Probe:"
envsubst < "$LAB_DIR/slow-start-app.yaml" | kubectl apply -f - &>/dev/null
sleep 5

STARTUP=$(kubectl get deployment slow-start-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].startupProbe.httpGet.path}' 2>/dev/null)
assert_eq "startup probe path set" "/" "$STARTUP"

FAILURE_THRESH=$(kubectl get deployment slow-start-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].startupProbe.failureThreshold}' 2>/dev/null)
assert_eq "startup probe failure threshold 12" "12" "$FAILURE_THRESH"

# ─── TCP probe ──────────────────────────────────────────────────────────────

echo ""
echo "TCP Probe:"
envsubst < "$LAB_DIR/tcp-probe-app.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" tcp-probe-app 90

TCP_PORT=$(kubectl get deployment tcp-probe-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.tcpSocket.port}' 2>/dev/null)
assert_eq "TCP probe on port 6379" "6379" "$TCP_PORT"

# ─── Exec probe ────────────────────────────────────────────────────────────

echo ""
echo "Exec Probe:"
envsubst < "$LAB_DIR/exec-probe-app.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" exec-probe-app 60

EXEC_CMD=$(kubectl get deployment exec-probe-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.exec.command}' 2>/dev/null)
assert_contains "exec probe uses cat command" "$EXEC_CMD" "cat"

# ─── Graceful shutdown ──────────────────────────────────────────────────────

echo ""
echo "Graceful Shutdown:"
envsubst < "$LAB_DIR/graceful-app.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" graceful-app 60

PRESTOP=$(kubectl get deployment graceful-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].lifecycle.preStop.exec.command}' 2>/dev/null)
assert_contains "preStop hook configured" "$PRESTOP" "sleep"

GRACE=$(kubectl get deployment graceful-app -n "$NS" -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}' 2>/dev/null)
assert_eq "termination grace period 45s" "45" "$GRACE"

# ─── Cleanup ────────────────────────────────────────────────────────────────

cleanup_ns "$NS"
summary
