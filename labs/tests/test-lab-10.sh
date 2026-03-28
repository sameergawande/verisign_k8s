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

# ─── Step 1: No probes (baseline) ────────────────────────────────────────

echo "No Probes (baseline):"
envsubst < "$LAB_DIR/no-probes-app.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" no-probes-app 60
assert_cmd "no-probes deployment running" kubectl rollout status deployment/no-probes-app -n "$NS" --timeout=10s

NOPROBE_REPLICAS=$(kubectl get deployment no-probes-app -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null)
assert_eq "no-probes-app has 2 replicas" "2" "$NOPROBE_REPLICAS"

# Verify no probes are configured
NOPROBE_LIVE=$(kubectl get deployment no-probes-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe}' 2>/dev/null)
assert_eq "no-probes-app has no liveness probe" "" "$NOPROBE_LIVE"

NOPROBE_READY=$(kubectl get deployment no-probes-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}' 2>/dev/null)
assert_eq "no-probes-app has no readiness probe" "" "$NOPROBE_READY"

# ─── Step 2: Liveness probe ──────────────────────────────────────────────

echo ""
echo "Liveness Probe (HTTP):"
envsubst < "$LAB_DIR/liveness-http.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" liveness-http 60

LIVENESS_PATH=$(kubectl get deployment liveness-http -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.path}' 2>/dev/null)
assert_eq "liveness probe path is /" "/" "$LIVENESS_PATH"

LIVENESS_PORT=$(kubectl get deployment liveness-http -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.port}' 2>/dev/null)
assert_eq "liveness probe port is 80" "80" "$LIVENESS_PORT"

LIVENESS_DELAY=$(kubectl get deployment liveness-http -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.initialDelaySeconds}' 2>/dev/null)
assert_eq "liveness initialDelaySeconds is 5" "5" "$LIVENESS_DELAY"

LIVENESS_PERIOD=$(kubectl get deployment liveness-http -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.periodSeconds}' 2>/dev/null)
assert_eq "liveness periodSeconds is 10" "10" "$LIVENESS_PERIOD"

LIVENESS_REPLICAS=$(kubectl get deployment liveness-http -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null)
assert_eq "liveness-http has 2 replicas" "2" "$LIVENESS_REPLICAS"

# ─── Step 3: Readiness probe ─────────────────────────────────────────────

echo ""
echo "Readiness Probe:"
envsubst < "$LAB_DIR/readiness-app.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" readiness-app 90

READINESS_PATH=$(kubectl get deployment readiness-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)
assert_eq "readiness probe path is /ready" "/ready" "$READINESS_PATH"

READINESS_PERIOD=$(kubectl get deployment readiness-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.periodSeconds}' 2>/dev/null)
assert_eq "readiness periodSeconds is 5" "5" "$READINESS_PERIOD"

READINESS_FAIL_THRESH=$(kubectl get deployment readiness-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.failureThreshold}' 2>/dev/null)
assert_eq "readiness failureThreshold is 2" "2" "$READINESS_FAIL_THRESH"

READINESS_SUCCESS_THRESH=$(kubectl get deployment readiness-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.successThreshold}' 2>/dev/null)
assert_eq "readiness successThreshold is 2" "2" "$READINESS_SUCCESS_THRESH"

# Verify it also has a liveness probe
READINESS_LIVE_PATH=$(kubectl get deployment readiness-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.path}' 2>/dev/null)
assert_eq "readiness-app also has liveness probe on /" "/" "$READINESS_LIVE_PATH"

# Verify the Service was created
SVC_EXISTS=$(kubectl get svc readiness-svc -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
assert_eq "readiness-svc Service created" "1" "$SVC_EXISTS"

SVC_PORT=$(kubectl get svc readiness-svc -n "$NS" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
assert_eq "readiness-svc port is 80" "80" "$SVC_PORT"

SVC_SELECTOR=$(kubectl get svc readiness-svc -n "$NS" -o jsonpath='{.spec.selector.app}' 2>/dev/null)
assert_eq "readiness-svc selector is readiness-app" "readiness-app" "$SVC_SELECTOR"

READINESS_REPLICAS=$(kubectl get deployment readiness-app -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null)
assert_eq "readiness-app has 3 replicas" "3" "$READINESS_REPLICAS"

# ─── Step 4: Startup probe ───────────────────────────────────────────────

echo ""
echo "Startup Probe:"
envsubst < "$LAB_DIR/slow-start-app.yaml" | kubectl apply -f - &>/dev/null
sleep 5

STARTUP_PATH=$(kubectl get deployment slow-start-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].startupProbe.httpGet.path}' 2>/dev/null)
assert_eq "startup probe path is /" "/" "$STARTUP_PATH"

STARTUP_PORT=$(kubectl get deployment slow-start-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].startupProbe.httpGet.port}' 2>/dev/null)
assert_eq "startup probe port is 80" "80" "$STARTUP_PORT"

STARTUP_FAIL_THRESH=$(kubectl get deployment slow-start-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].startupProbe.failureThreshold}' 2>/dev/null)
assert_eq "startup failureThreshold is 12" "12" "$STARTUP_FAIL_THRESH"

STARTUP_PERIOD=$(kubectl get deployment slow-start-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].startupProbe.periodSeconds}' 2>/dev/null)
assert_eq "startup periodSeconds is 5" "5" "$STARTUP_PERIOD"

# Verify liveness and readiness are also present (disabled until startup passes)
STARTUP_LIVE=$(kubectl get deployment slow-start-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.path}' 2>/dev/null)
assert_eq "slow-start-app has liveness probe on /" "/" "$STARTUP_LIVE"

STARTUP_READY=$(kubectl get deployment slow-start-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)
assert_eq "slow-start-app has readiness probe on /" "/" "$STARTUP_READY"

# ─── Step 5: Tuned probes ────────────────────────────────────────────────

echo ""
echo "Tuned Probes:"
envsubst < "$LAB_DIR/tuned-probes.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" tuned-probes 60

# Verify liveness probe tuning
TUNED_LIVE_DELAY=$(kubectl get deployment tuned-probes -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.initialDelaySeconds}' 2>/dev/null)
assert_eq "tuned liveness initialDelaySeconds is 10" "10" "$TUNED_LIVE_DELAY"

TUNED_LIVE_PERIOD=$(kubectl get deployment tuned-probes -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.periodSeconds}' 2>/dev/null)
assert_eq "tuned liveness periodSeconds is 5" "5" "$TUNED_LIVE_PERIOD"

TUNED_LIVE_FAIL=$(kubectl get deployment tuned-probes -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.failureThreshold}' 2>/dev/null)
assert_eq "tuned liveness failureThreshold is 2" "2" "$TUNED_LIVE_FAIL"

TUNED_LIVE_PATH=$(kubectl get deployment tuned-probes -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.path}' 2>/dev/null)
assert_eq "tuned liveness probe path is /" "/" "$TUNED_LIVE_PATH"

# Verify readiness probe tuning
TUNED_READY_DELAY=$(kubectl get deployment tuned-probes -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.initialDelaySeconds}' 2>/dev/null)
assert_eq "tuned readiness initialDelaySeconds is 5" "5" "$TUNED_READY_DELAY"

TUNED_READY_PERIOD=$(kubectl get deployment tuned-probes -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.periodSeconds}' 2>/dev/null)
assert_eq "tuned readiness periodSeconds is 3" "3" "$TUNED_READY_PERIOD"

TUNED_READY_FAIL=$(kubectl get deployment tuned-probes -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.failureThreshold}' 2>/dev/null)
assert_eq "tuned readiness failureThreshold is 2" "2" "$TUNED_READY_FAIL"

TUNED_READY_SUCCESS=$(kubectl get deployment tuned-probes -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.successThreshold}' 2>/dev/null)
assert_eq "tuned readiness successThreshold is 3" "3" "$TUNED_READY_SUCCESS"

TUNED_READY_PATH=$(kubectl get deployment tuned-probes -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)
assert_eq "tuned readiness probe path is /" "/" "$TUNED_READY_PATH"

# Verify all three probe types are configured (liveness + readiness; no startup on this one)
TUNED_STARTUP=$(kubectl get deployment tuned-probes -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].startupProbe}' 2>/dev/null)
assert_eq "tuned-probes has no startup probe (tuning exercise)" "" "$TUNED_STARTUP"

# ─── Step 6: TCP probe ───────────────────────────────────────────────────

echo ""
echo "TCP Probe:"
envsubst < "$LAB_DIR/tcp-probe-app.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" tcp-probe-app 90

TCP_LIVE_PORT=$(kubectl get deployment tcp-probe-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.tcpSocket.port}' 2>/dev/null)
assert_eq "TCP liveness probe on port 6379" "6379" "$TCP_LIVE_PORT"

TCP_READY_PORT=$(kubectl get deployment tcp-probe-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.tcpSocket.port}' 2>/dev/null)
assert_eq "TCP readiness probe on port 6379" "6379" "$TCP_READY_PORT"

TCP_LIVE_DELAY=$(kubectl get deployment tcp-probe-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.initialDelaySeconds}' 2>/dev/null)
assert_eq "TCP liveness initialDelaySeconds is 5" "5" "$TCP_LIVE_DELAY"

TCP_LIVE_PERIOD=$(kubectl get deployment tcp-probe-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.periodSeconds}' 2>/dev/null)
assert_eq "TCP liveness periodSeconds is 10" "10" "$TCP_LIVE_PERIOD"

TCP_READY_DELAY=$(kubectl get deployment tcp-probe-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.initialDelaySeconds}' 2>/dev/null)
assert_eq "TCP readiness initialDelaySeconds is 3" "3" "$TCP_READY_DELAY"

# Verify Redis responds
TCP_POD=$(kubectl get pod -l app=tcp-probe-app -n "$NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
REDIS_PING=$(kubectl exec "$TCP_POD" -n "$NS" -- redis-cli ping 2>/dev/null)
assert_eq "Redis responds with PONG" "PONG" "$REDIS_PING"

# ─── Step 7: Exec probe ──────────────────────────────────────────────────

echo ""
echo "Exec Probe:"
envsubst < "$LAB_DIR/exec-probe-app.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" exec-probe-app 60

EXEC_CMD=$(kubectl get deployment exec-probe-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.exec.command}' 2>/dev/null)
assert_contains "exec probe uses cat command" "$EXEC_CMD" "cat"
assert_contains "exec probe checks /tmp/healthy" "$EXEC_CMD" "/tmp/healthy"

EXEC_DELAY=$(kubectl get deployment exec-probe-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.initialDelaySeconds}' 2>/dev/null)
assert_eq "exec probe initialDelaySeconds is 5" "5" "$EXEC_DELAY"

EXEC_PERIOD=$(kubectl get deployment exec-probe-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.periodSeconds}' 2>/dev/null)
assert_eq "exec probe periodSeconds is 5" "5" "$EXEC_PERIOD"

# Verify the health file exists
EXEC_POD=$(kubectl get pod -l app=exec-probe-app -n "$NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
assert_cmd "health file /tmp/healthy exists" kubectl exec "$EXEC_POD" -n "$NS" -- cat /tmp/healthy

# ─── Step 8: Graceful shutdown ────────────────────────────────────────────

echo ""
echo "Graceful Shutdown:"
envsubst < "$LAB_DIR/graceful-app.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" graceful-app 60

PRESTOP=$(kubectl get deployment graceful-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].lifecycle.preStop.exec.command}' 2>/dev/null)
assert_contains "preStop hook includes sleep" "$PRESTOP" "sleep"
assert_contains "preStop hook includes nginx quit" "$PRESTOP" "nginx"

GRACE=$(kubectl get deployment graceful-app -n "$NS" -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}' 2>/dev/null)
assert_eq "terminationGracePeriodSeconds is 45" "45" "$GRACE"

GRACEFUL_REPLICAS=$(kubectl get deployment graceful-app -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null)
assert_eq "graceful-app has 2 replicas" "2" "$GRACEFUL_REPLICAS"

# Verify graceful-app also has liveness and readiness probes
GRACEFUL_LIVE=$(kubectl get deployment graceful-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.path}' 2>/dev/null)
assert_eq "graceful-app has liveness probe on /" "/" "$GRACEFUL_LIVE"

GRACEFUL_READY=$(kubectl get deployment graceful-app -n "$NS" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)
assert_eq "graceful-app has readiness probe on /" "/" "$GRACEFUL_READY"

# ─── Cleanup ──────────────────────────────────────────────────────────────

cleanup_ns "$NS"
summary
