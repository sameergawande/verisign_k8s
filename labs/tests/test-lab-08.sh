#!/bin/bash
###############################################################################
# Lab 8 Test: Network Policies — Comprehensive Coverage
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/../lab-08" && pwd)"
source "$SCRIPT_DIR/lib.sh"

export STUDENT_NAME="test-$$"
NS="lab08-$STUDENT_NAME"
NS_MON="monitoring-$STUDENT_NAME"
echo "=== Lab 8: Network Policies (ns: $NS) ==="
echo ""

kubectl create namespace "$NS" &>/dev/null

###############################################################################
# Step 1: Deploy Three-Tier Application
###############################################################################

echo "Three-Tier App Deployment:"
envsubst < "$LAB_DIR/database.yaml" | kubectl apply -f - &>/dev/null
envsubst < "$LAB_DIR/backend.yaml" | kubectl apply -f - &>/dev/null
envsubst < "$LAB_DIR/frontend.yaml" | kubectl apply -f - &>/dev/null
kubectl wait --for=condition=Ready pod --all -n "$NS" --timeout=90s &>/dev/null

PODS=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | grep -c Running || true)
assert_eq "3 pods running" "3" "$PODS"

# Verify labels
FE_LABELS=$(kubectl get pod frontend -n "$NS" -o jsonpath='{.metadata.labels.tier}' 2>/dev/null)
assert_eq "frontend has tier=frontend label" "frontend" "$FE_LABELS"

BE_LABELS=$(kubectl get pod backend -n "$NS" -o jsonpath='{.metadata.labels.tier}' 2>/dev/null)
assert_eq "backend has tier=backend label" "backend" "$BE_LABELS"

DB_LABELS=$(kubectl get pod database -n "$NS" -o jsonpath='{.metadata.labels.tier}' 2>/dev/null)
assert_eq "database has tier=database label" "database" "$DB_LABELS"

# Verify services
assert_cmd "frontend Service exists" kubectl get svc frontend -n "$NS"
assert_cmd "backend Service exists" kubectl get svc backend -n "$NS"
assert_cmd "database Service exists" kubectl get svc database -n "$NS"

###############################################################################
# Step 2: Verify Default Connectivity (full matrix)
###############################################################################

echo ""
echo "Default Connectivity (no policies):"

F2B=$(kubectl exec frontend -n "$NS" -- curl -s --max-time 5 "http://backend.${NS}.svc.cluster.local:80" 2>/dev/null)
assert_contains "frontend -> backend (default)" "$F2B" "nginx"

F2D=$(kubectl exec frontend -n "$NS" -- curl -s --max-time 5 "http://database.${NS}.svc.cluster.local:80" 2>/dev/null)
assert_contains "frontend -> database (default)" "$F2D" "nginx"

D2F=$(kubectl exec database -n "$NS" -- curl -s --max-time 5 "http://frontend.${NS}.svc.cluster.local:80" 2>/dev/null)
assert_contains "database -> frontend (default)" "$D2F" "nginx"

B2D=$(kubectl exec backend -n "$NS" -- curl -s --max-time 5 "http://database.${NS}.svc.cluster.local:80" 2>/dev/null)
assert_contains "backend -> database (default)" "$B2D" "nginx"

D2B=$(kubectl exec database -n "$NS" -- curl -s --max-time 5 "http://backend.${NS}.svc.cluster.local:80" 2>/dev/null)
assert_contains "database -> backend (default)" "$D2B" "nginx"

B2F=$(kubectl exec backend -n "$NS" -- curl -s --max-time 5 "http://frontend.${NS}.svc.cluster.local:80" 2>/dev/null)
assert_contains "backend -> frontend (default)" "$B2F" "nginx"

###############################################################################
# Step 3-4: Default Deny-All Ingress & Full Isolation Verification
###############################################################################

echo ""
echo "Default Deny-All Ingress:"

envsubst < "$LAB_DIR/deny-all-ingress.yaml" | kubectl apply -f - &>/dev/null
assert_cmd "deny-all-ingress policy created" kubectl get networkpolicy default-deny-all-ingress -n "$NS"
sleep 3

# Probe whether the CNI actually enforces NetworkPolicy
# If traffic still flows after deny-all, skip all enforcement tests
CNI_ENFORCES=true
kubectl exec frontend -n "$NS" -- curl -s --max-time 3 "http://backend.${NS}.svc.cluster.local:80" &>/dev/null
if [ $? -eq 0 ]; then
  CNI_ENFORCES=false
  skip "CNI does not enforce NetworkPolicy — skipping all enforcement tests"
fi

if [ "$CNI_ENFORCES" = "true" ]; then

# Full isolation matrix — all should fail
kubectl exec frontend -n "$NS" -- curl -s --max-time 3 "http://backend.${NS}.svc.cluster.local:80" &>/dev/null
if [ $? -ne 0 ]; then pass "frontend -> backend BLOCKED"; else fail "frontend -> backend should be blocked"; fi

kubectl exec frontend -n "$NS" -- curl -s --max-time 3 "http://database.${NS}.svc.cluster.local:80" &>/dev/null
if [ $? -ne 0 ]; then pass "frontend -> database BLOCKED"; else fail "frontend -> database should be blocked"; fi

kubectl exec backend -n "$NS" -- curl -s --max-time 3 "http://database.${NS}.svc.cluster.local:80" &>/dev/null
if [ $? -ne 0 ]; then pass "backend -> database BLOCKED"; else fail "backend -> database should be blocked"; fi

kubectl exec backend -n "$NS" -- curl -s --max-time 3 "http://frontend.${NS}.svc.cluster.local:80" &>/dev/null
if [ $? -ne 0 ]; then pass "backend -> frontend BLOCKED"; else fail "backend -> frontend should be blocked"; fi

kubectl exec database -n "$NS" -- curl -s --max-time 3 "http://frontend.${NS}.svc.cluster.local:80" &>/dev/null
if [ $? -ne 0 ]; then pass "database -> frontend BLOCKED"; else fail "database -> frontend should be blocked"; fi

kubectl exec database -n "$NS" -- curl -s --max-time 3 "http://backend.${NS}.svc.cluster.local:80" &>/dev/null
if [ $? -ne 0 ]; then pass "database -> backend BLOCKED"; else fail "database -> backend should be blocked"; fi

###############################################################################
# Step 5: Allow Frontend to Backend
###############################################################################

echo ""
echo "Selective Allow — Frontend to Backend:"

envsubst < "$LAB_DIR/allow-frontend-to-backend.yaml" | kubectl apply -f - &>/dev/null
assert_cmd "allow-frontend-to-backend policy created" kubectl get networkpolicy allow-frontend-to-backend -n "$NS"
sleep 3

F2B_ALLOW=$(kubectl exec frontend -n "$NS" -- curl -s --max-time 5 "http://backend.${NS}.svc.cluster.local:80" 2>/dev/null)
assert_contains "frontend -> backend ALLOWED" "$F2B_ALLOW" "nginx"

# database -> backend should still be blocked
kubectl exec database -n "$NS" -- curl -s --max-time 3 "http://backend.${NS}.svc.cluster.local:80" &>/dev/null
if [ $? -ne 0 ]; then pass "database -> backend still BLOCKED"; else fail "database -> backend should still be blocked"; fi

# frontend -> database should still be blocked
kubectl exec frontend -n "$NS" -- curl -s --max-time 3 "http://database.${NS}.svc.cluster.local:80" &>/dev/null
if [ $? -ne 0 ]; then pass "frontend -> database still BLOCKED"; else fail "frontend -> database should still be blocked"; fi

###############################################################################
# Step 6: Allow Backend to Database
###############################################################################

echo ""
echo "Selective Allow — Backend to Database:"

envsubst < "$LAB_DIR/allow-backend-to-database.yaml" | kubectl apply -f - &>/dev/null
assert_cmd "allow-backend-to-database policy created" kubectl get networkpolicy allow-backend-to-database -n "$NS"
sleep 3

B2D_ALLOW=$(kubectl exec backend -n "$NS" -- curl -s --max-time 5 "http://database.${NS}.svc.cluster.local:80" 2>/dev/null)
assert_contains "backend -> database ALLOWED" "$B2D_ALLOW" "nginx"

# frontend -> database should still be blocked
kubectl exec frontend -n "$NS" -- curl -s --max-time 3 "http://database.${NS}.svc.cluster.local:80" &>/dev/null
if [ $? -ne 0 ]; then pass "frontend -> database still BLOCKED"; else fail "frontend -> database should still be blocked"; fi

###############################################################################
# Step 7: Complete Policy Matrix Validation
###############################################################################

echo ""
echo "Complete Policy Matrix:"

# Allowed paths
F2B_HTTP=$(kubectl exec frontend -n "$NS" -- curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://backend:80" 2>/dev/null || echo "000")
assert_eq "frontend -> backend HTTP 200" "200" "$F2B_HTTP"

B2D_HTTP=$(kubectl exec backend -n "$NS" -- curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://database:80" 2>/dev/null || echo "000")
assert_eq "backend -> database HTTP 200" "200" "$B2D_HTTP"

# Blocked paths
kubectl exec frontend -n "$NS" -- curl -s --max-time 3 "http://database:80" &>/dev/null
if [ $? -ne 0 ]; then pass "frontend -> database BLOCKED (matrix)"; else fail "frontend -> database should be blocked"; fi

kubectl exec database -n "$NS" -- curl -s --max-time 3 "http://frontend:80" &>/dev/null
if [ $? -ne 0 ]; then pass "database -> frontend BLOCKED (matrix)"; else fail "database -> frontend should be blocked"; fi

kubectl exec database -n "$NS" -- curl -s --max-time 3 "http://backend:80" &>/dev/null
if [ $? -ne 0 ]; then pass "database -> backend BLOCKED (matrix)"; else fail "database -> backend should be blocked"; fi

###############################################################################
# Step 8: Egress Rules
###############################################################################

echo ""
echo "Egress Policies:"

# Apply deny-all egress
envsubst < "$LAB_DIR/deny-all-egress.yaml" | kubectl apply -f - &>/dev/null
assert_cmd "deny-all-egress policy created" kubectl get networkpolicy default-deny-all-egress -n "$NS"
sleep 3

# DNS should break — curl will fail to resolve hostnames
kubectl exec frontend -n "$NS" -- curl -s --max-time 3 "http://backend.${NS}.svc.cluster.local:80" &>/dev/null
if [ $? -ne 0 ]; then
  pass "egress deny breaks DNS resolution"
else
  fail "egress deny should break DNS resolution"
fi

# Apply allow-dns-egress to restore DNS + in-namespace traffic
envsubst < "$LAB_DIR/allow-dns-egress.yaml" | kubectl apply -f - &>/dev/null
assert_cmd "allow-dns-egress policy created" kubectl get networkpolicy allow-dns-egress -n "$NS"
sleep 3

# DNS should work again and frontend -> backend should be restored
F2B_AFTER_EGRESS=$(kubectl exec frontend -n "$NS" -- curl -s --max-time 5 "http://backend.${NS}.svc.cluster.local:80" 2>/dev/null)
assert_contains "DNS and frontend -> backend restored after allow-dns-egress" "$F2B_AFTER_EGRESS" "nginx"

# Backend -> database should also work (in-namespace egress on port 80 is allowed)
B2D_AFTER_EGRESS=$(kubectl exec backend -n "$NS" -- curl -s --max-time 5 "http://database.${NS}.svc.cluster.local:80" 2>/dev/null)
assert_contains "backend -> database works with egress rules" "$B2D_AFTER_EGRESS" "nginx"

###############################################################################
# Step 9: Namespace-Based Policies
###############################################################################

echo ""
echo "Namespace-Based Policies:"

kubectl create namespace "$NS_MON" &>/dev/null
kubectl label namespace "$NS_MON" purpose=monitoring &>/dev/null
assert_cmd "monitoring namespace created" kubectl get namespace "$NS_MON"

MON_LABELS=$(kubectl get namespace "$NS_MON" -o jsonpath='{.metadata.labels.purpose}' 2>/dev/null)
assert_eq "monitoring ns has purpose=monitoring label" "monitoring" "$MON_LABELS"

kubectl run monitor --image=nginx:1.25 -n "$NS_MON" &>/dev/null
wait_for_pod "$NS_MON" monitor 60

# Before allow-monitoring-ingress: monitor cannot reach backend (denied by deny-all)
kubectl exec monitor -n "$NS_MON" -- curl -s --max-time 3 "http://backend.${NS}.svc.cluster.local:80" &>/dev/null
if [ $? -ne 0 ]; then
  pass "monitor -> backend BLOCKED before monitoring policy"
else
  fail "monitor -> backend should be blocked before monitoring policy"
fi

# Apply allow-monitoring-ingress
envsubst < "$LAB_DIR/allow-monitoring-ingress.yaml" | kubectl apply -f - &>/dev/null
assert_cmd "allow-monitoring-ingress policy created" kubectl get networkpolicy allow-monitoring-ingress -n "$NS"
sleep 3

# Monitor should now be able to reach backend
MON_RESULT=$(kubectl exec monitor -n "$NS_MON" -- curl -s --max-time 5 "http://backend.${NS}.svc.cluster.local:80" 2>/dev/null)
assert_contains "monitor -> backend ALLOWED after monitoring policy" "$MON_RESULT" "nginx"

# Monitor should also reach frontend (policy selects all pods in namespace)
MON_FE=$(kubectl exec monitor -n "$NS_MON" -- curl -s --max-time 5 "http://frontend.${NS}.svc.cluster.local:80" 2>/dev/null)
assert_contains "monitor -> frontend ALLOWED after monitoring policy" "$MON_FE" "nginx"

###############################################################################
# Step 10: Debug Broken Policy
###############################################################################

echo ""
echo "Debug — Broken Policy:"

envsubst < "$LAB_DIR/broken-policy.yaml" | kubectl apply -f - &>/dev/null
assert_cmd "broken-policy applied" kubectl get networkpolicy allow-external-to-frontend -n "$NS"
sleep 2

# Broken policy: self-referencing selector (tier: frontend) and wrong port (8080)
# A test-client should NOT be able to reach frontend via the broken policy
kubectl run test-client-broken --image=nginx:1.25 -n "$NS" --labels="tier=test" --restart=Never &>/dev/null
wait_for_pod "$NS" test-client-broken 60

kubectl exec test-client-broken -n "$NS" -- curl -s --max-time 3 "http://frontend.${NS}.svc.cluster.local:80" &>/dev/null
if [ $? -ne 0 ]; then
  pass "broken policy does NOT allow test-client -> frontend"
else
  fail "broken policy should NOT allow test-client -> frontend"
fi

# Inspect the broken policy for the known bugs
BROKEN_TIER=$(kubectl get networkpolicy allow-external-to-frontend -n "$NS" \
  -o jsonpath='{.spec.ingress[0].from[0].podSelector.matchLabels.tier}' 2>/dev/null)
assert_eq "broken policy has self-referencing selector (tier: frontend)" "frontend" "$BROKEN_TIER"
BROKEN_PORT=$(kubectl get networkpolicy allow-external-to-frontend -n "$NS" \
  -o jsonpath='{.spec.ingress[0].ports[0].port}' 2>/dev/null)
assert_eq "broken policy has wrong port 8080" "8080" "$BROKEN_PORT"

echo ""
echo "Debug — Fixed Policy:"

envsubst < "$LAB_DIR/fixed-policy.yaml" | kubectl apply -f - &>/dev/null
sleep 2

# Fixed policy: from: [] (allow all) and port: 80
FIXED_PORT=$(kubectl get networkpolicy allow-external-to-frontend -n "$NS" \
  -o jsonpath='{.spec.ingress[0].ports[0].port}' 2>/dev/null)
assert_eq "fixed policy uses port 80" "80" "$FIXED_PORT"

# test-client should now reach frontend
FIXED_RESULT=$(kubectl exec test-client-broken -n "$NS" -- curl -s --max-time 5 "http://frontend.${NS}.svc.cluster.local:80" 2>/dev/null)
assert_contains "fixed policy allows test-client -> frontend" "$FIXED_RESULT" "nginx"

# Clean up the test client pod
kubectl delete pod test-client-broken -n "$NS" --grace-period=0 --force &>/dev/null

fi  # end CNI_ENFORCES block

###############################################################################
# Cleanup
###############################################################################

echo ""
echo "Cleanup:"
cleanup_ns "$NS"
cleanup_ns "$NS_MON"
summary
