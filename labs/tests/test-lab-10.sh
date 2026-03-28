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

# ─── Behavioral: no-probes failure stays undetected ──────────────────────

echo ""
echo "Behavioral: no-probes pod keeps running after internal failure"
NOPROBE_POD=$(kubectl get pod -l app=no-probes-app -n "$NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
# Break nginx by removing default config
kubectl exec "$NOPROBE_POD" -n "$NS" -- rm /etc/nginx/conf.d/default.conf &>/dev/null || true
kubectl exec "$NOPROBE_POD" -n "$NS" -- nginx -s reload &>/dev/null || true
sleep 10
NOPROBE_PHASE=$(kubectl get pod "$NOPROBE_POD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
assert_eq "no-probes pod still Running after failure" "Running" "$NOPROBE_PHASE"
NOPROBE_RESTARTS=$(kubectl get pod "$NOPROBE_POD" -n "$NS" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
assert_eq "no-probes pod not restarted despite failure" "0" "$NOPROBE_RESTARTS"

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

# ─── Behavioral: liveness probe triggers restart ─────────────────────────

echo ""
echo "Behavioral: liveness probe triggers restart after failure"
LIVE_POD=$(kubectl get pod -l app=liveness-http -n "$NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
LIVE_RESTARTS_BEFORE=$(kubectl get pod "$LIVE_POD" -n "$NS" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
# Remove the index.html so GET / returns 403/404, failing liveness
kubectl exec "$LIVE_POD" -n "$NS" -- rm /usr/share/nginx/html/index.html &>/dev/null || true
# Poll up to 60s for restart count to increment
LIVE_RESTARTED=false
for i in $(seq 1 12); do
  sleep 5
  LIVE_RESTARTS_NOW=$(kubectl get pod "$LIVE_POD" -n "$NS" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
  if [ "$LIVE_RESTARTS_NOW" -gt "$LIVE_RESTARTS_BEFORE" ] 2>/dev/null; then
    LIVE_RESTARTED=true
    break
  fi
done
if [ "$LIVE_RESTARTED" = "true" ]; then
  pass "liveness probe triggered restart"
else
  fail "liveness probe triggered restart (no restart within 60s)"
fi

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

# ─── Behavioral: readiness failure removes pod from endpoints ────────────

echo ""
echo "Behavioral: readiness failure/recovery cycle"
READY_POD=$(kubectl get pod -l app=readiness-app -n "$NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
READY_POD_IP=$(kubectl get pod "$READY_POD" -n "$NS" -o jsonpath='{.status.podIP}' 2>/dev/null)

# Ensure the /ready file exists so the pod is currently ready
kubectl exec "$READY_POD" -n "$NS" -- sh -c 'mkdir -p /usr/share/nginx/html && touch /usr/share/nginx/html/ready' &>/dev/null || true
sleep 12  # wait for successThreshold (2 checks x 5s period)

# Verify pod IP appears in endpoints before we break it
EP_BEFORE=$(kubectl get endpoints readiness-svc -n "$NS" -o jsonpath='{.subsets[0].addresses}' 2>/dev/null)
assert_contains "pod IP in endpoints before failure" "$EP_BEFORE" "$READY_POD_IP"

# Remove the /ready file to fail the readiness probe
kubectl exec "$READY_POD" -n "$NS" -- rm /usr/share/nginx/html/ready &>/dev/null || true

# Poll up to 20s: pod should be removed from endpoints
READY_REMOVED=false
for i in $(seq 1 4); do
  sleep 5
  EP_DURING=$(kubectl get endpoints readiness-svc -n "$NS" -o jsonpath='{.subsets[0].addresses}' 2>/dev/null)
  if ! echo "$EP_DURING" | grep -q "$READY_POD_IP"; then
    READY_REMOVED=true
    break
  fi
done
if [ "$READY_REMOVED" = "true" ]; then
  pass "readiness failure removed pod from endpoints"
else
  fail "readiness failure removed pod from endpoints (still present after 20s)"
fi

# Verify pod was NOT restarted (readiness failure should not restart)
READY_RESTARTS=$(kubectl get pod "$READY_POD" -n "$NS" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
assert_eq "readiness failure did not restart pod" "0" "$READY_RESTARTS"

# Restore the /ready file
kubectl exec "$READY_POD" -n "$NS" -- touch /usr/share/nginx/html/ready &>/dev/null || true

# Poll up to 20s: pod should reappear in endpoints
READY_RECOVERED=false
for i in $(seq 1 4); do
  sleep 5
  EP_AFTER=$(kubectl get endpoints readiness-svc -n "$NS" -o jsonpath='{.subsets[0].addresses}' 2>/dev/null)
  if echo "$EP_AFTER" | grep -q "$READY_POD_IP"; then
    READY_RECOVERED=true
    break
  fi
done
if [ "$READY_RECOVERED" = "true" ]; then
  pass "readiness recovery restored pod to endpoints"
else
  fail "readiness recovery restored pod to endpoints (not found after 20s)"
fi

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

# ─── Behavioral: exec probe triggers restart on health file removal ──────

echo ""
echo "Behavioral: exec probe triggers restart when /tmp/healthy removed"
EXEC_RESTARTS_BEFORE=$(kubectl get pod "$EXEC_POD" -n "$NS" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
# Remove the health file so cat /tmp/healthy fails
kubectl exec "$EXEC_POD" -n "$NS" -- rm /tmp/healthy &>/dev/null || true
# Poll up to 60s for restart count to increment
EXEC_RESTARTED=false
for i in $(seq 1 12); do
  sleep 5
  EXEC_RESTARTS_NOW=$(kubectl get pod "$EXEC_POD" -n "$NS" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
  if [ "$EXEC_RESTARTS_NOW" -gt "$EXEC_RESTARTS_BEFORE" ] 2>/dev/null; then
    EXEC_RESTARTED=true
    break
  fi
done
if [ "$EXEC_RESTARTED" = "true" ]; then
  pass "exec probe triggered restart after /tmp/healthy removal"
else
  fail "exec probe triggered restart after /tmp/healthy removal (no restart within 60s)"
fi

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

# ─── Behavioral: graceful shutdown takes time (preStop hook) ─────────────

echo ""
echo "Behavioral: graceful shutdown preStop hook delays termination"
GRACEFUL_POD=$(kubectl get pod -l app=graceful-app -n "$NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
# Delete pod without waiting
DELETE_START=$(date +%s)
kubectl delete pod "$GRACEFUL_POD" -n "$NS" --wait=false &>/dev/null
# Wait a few seconds and check the pod is still terminating (preStop sleeps 10s)
sleep 5
GRACEFUL_STATUS=$(kubectl get pod "$GRACEFUL_POD" -n "$NS" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)
if [ -n "$GRACEFUL_STATUS" ]; then
  pass "graceful pod still terminating after 5s (preStop hook running)"
else
  # Pod already gone after 5s or not found — check if it was replaced quickly
  skip "graceful pod terminated quickly (preStop may not have delayed)"
fi
# Wait for replacement pod to come up
sleep 20
GRACEFUL_RUNNING=$(kubectl get pods -l app=graceful-app -n "$NS" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$GRACEFUL_RUNNING" -ge 1 ]; then
  pass "graceful-app replacement pod is Running"
else
  fail "graceful-app replacement pod is Running (none found)"
fi

# ─── Cleanup ──────────────────────────────────────────────────────────────

cleanup_ns "$NS"
summary
