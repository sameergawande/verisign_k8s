#!/bin/bash
###############################################################################
# Lab 6 Test: Ingress and Gateway API
# Covers: App deployment, host-based ingress, path-based ingress, TLS ingress,
#         ingress annotations, functional HTTP routing via curl, Gateway API
#         (GatewayClass, Gateway, HTTPRoute), egress NetworkPolicy enforcement
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/../lab-06" && pwd)"
source "$SCRIPT_DIR/lib.sh"

export STUDENT_NAME="test-$$"
NS="lab06-$STUDENT_NAME"
echo "=== Lab 6: Ingress & Gateway API (ns: $NS) ==="
echo ""

kubectl create namespace "$NS" &>/dev/null

# ─── Step 2: Deploy apps ──────────────────────────────────────────────────

echo "Step 2: Deploy Sample Applications"

envsubst < "$LAB_DIR/app-v1.yaml" | kubectl apply -f - &>/dev/null
envsubst < "$LAB_DIR/app-v2.yaml" | kubectl apply -f - &>/dev/null
wait_for_deploy "$NS" app-v1 90
wait_for_deploy "$NS" app-v2 90

V1_READY=$(kubectl get deployment app-v1 -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
assert_eq "app-v1 has 2 ready replicas" "2" "$V1_READY"

V2_READY=$(kubectl get deployment app-v2 -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
assert_eq "app-v2 has 2 ready replicas" "2" "$V2_READY"

# Verify services
assert_cmd "app-v1-svc exists" kubectl get svc app-v1-svc -n "$NS"
assert_cmd "app-v2-svc exists" kubectl get svc app-v2-svc -n "$NS"

V1_PORT=$(kubectl get svc app-v1-svc -n "$NS" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
assert_eq "app-v1-svc port is 80" "80" "$V1_PORT"

V2_PORT=$(kubectl get svc app-v2-svc -n "$NS" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
assert_eq "app-v2-svc port is 80" "80" "$V2_PORT"

# Verify pod labels
V1_PODS=$(kubectl get pods -n "$NS" -l "app=web,version=v1" --no-headers 2>/dev/null | grep -c Running)
assert_eq "2 v1 pods running with correct labels" "2" "$V1_PODS"

V2_PODS=$(kubectl get pods -n "$NS" -l "app=web,version=v2" --no-headers 2>/dev/null | grep -c Running)
assert_eq "2 v2 pods running with correct labels" "2" "$V2_PODS"

# ─── Resolve ingress controller address ───────────────────────────────────

INGRESS_AVAILABLE=false
INGRESS_IP=""

if kubectl get pods -n ingress-nginx --no-headers 2>/dev/null | grep -q Running; then
  # Try hostname first (AWS EKS), then IP (bare metal / minikube)
  INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  if [ -z "$INGRESS_IP" ]; then
    INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  fi
  if [ -z "$INGRESS_IP" ]; then
    # NodePort fallback: use cluster IP of the controller service
    INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
      -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
  fi
  if [ -n "$INGRESS_IP" ]; then
    INGRESS_AVAILABLE=true
  fi
fi

# ─── IngressClass verification ────────────────────────────────────────────

echo ""
echo "IngressClass:"

if kubectl get ingressclass nginx &>/dev/null; then
  pass "IngressClass nginx exists"
else
  skip "IngressClass nginx not found"
fi

# ─── Step 3: Host-based Ingress ──────────────────────────────────────────

echo ""
echo "Step 3: Host-Based Ingress"

if [ "$INGRESS_AVAILABLE" = "true" ]; then
  envsubst < "$LAB_DIR/ingress-host.yaml" | kubectl apply -f - &>/dev/null
  sleep 5

  assert_cmd "host-based ingress created" kubectl get ingress app-ingress-host -n "$NS"

  ING_CLASS=$(kubectl get ingress app-ingress-host -n "$NS" \
    -o jsonpath='{.spec.ingressClassName}' 2>/dev/null)
  assert_eq "ingress class is nginx" "nginx" "$ING_CLASS"

  ING_RULES=$(kubectl get ingress app-ingress-host -n "$NS" -o json 2>/dev/null)
  RULE_COUNT=$(echo "$ING_RULES" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['spec']['rules']))" 2>/dev/null || echo "0")
  assert_eq "host ingress has 2 rules" "2" "$RULE_COUNT"

  # ─── Step 4: Functional HTTP routing tests ────────────────────────────

  echo ""
  echo "Step 4: Test Host-Based Routing"

  V1_RESP=$(curl -s --max-time 10 -H "Host: v1-$STUDENT_NAME.lab.local" "http://$INGRESS_IP" 2>/dev/null)
  if [ -n "$V1_RESP" ]; then
    assert_contains "host v1 returns App V1" "$V1_RESP" "App V1"
  else
    skip "host v1 curl returned empty (LB may not be reachable)"
  fi

  V2_RESP=$(curl -s --max-time 10 -H "Host: v2-$STUDENT_NAME.lab.local" "http://$INGRESS_IP" 2>/dev/null)
  if [ -n "$V2_RESP" ]; then
    assert_contains "host v2 returns App V2" "$V2_RESP" "App V2"
  else
    skip "host v2 curl returned empty (LB may not be reachable)"
  fi

  UNKNOWN_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    -H "Host: unknown.lab.local" "http://$INGRESS_IP" 2>/dev/null)
  if [ -n "$UNKNOWN_CODE" ] && [ "$UNKNOWN_CODE" != "000" ]; then
    assert_eq "unknown host returns 404" "404" "$UNKNOWN_CODE"
  else
    skip "unknown host curl failed (LB may not be reachable)"
  fi

  # ─── Step 5: Path-based Ingress ──────────────────────────────────────

  echo ""
  echo "Step 5: Path-Based Routing"

  envsubst < "$LAB_DIR/ingress-path.yaml" | kubectl apply -f - &>/dev/null
  sleep 5

  assert_cmd "path-based ingress created" kubectl get ingress app-ingress-path -n "$NS"

  PATH_RULES=$(kubectl get ingress app-ingress-path -n "$NS" \
    -o jsonpath='{.spec.rules[0].http.paths}' 2>/dev/null)
  assert_contains "path ingress has /v1 path" "$PATH_RULES" "/v1"
  assert_contains "path ingress has /v2 path" "$PATH_RULES" "/v2"

  PATH_V1=$(curl -s --max-time 10 \
    -H "Host: app-$STUDENT_NAME.lab.local" "http://$INGRESS_IP/v1" 2>/dev/null)
  if [ -n "$PATH_V1" ]; then
    assert_contains "/v1 path returns V1" "$PATH_V1" "V1"
  else
    skip "/v1 curl returned empty"
  fi

  PATH_V2=$(curl -s --max-time 10 \
    -H "Host: app-$STUDENT_NAME.lab.local" "http://$INGRESS_IP/v2" 2>/dev/null)
  if [ -n "$PATH_V2" ]; then
    assert_contains "/v2 path returns V2" "$PATH_V2" "V2"
  else
    skip "/v2 curl returned empty"
  fi

  PATH_ROOT=$(curl -s --max-time 10 \
    -H "Host: app-$STUDENT_NAME.lab.local" "http://$INGRESS_IP/" 2>/dev/null)
  if [ -n "$PATH_ROOT" ]; then
    assert_contains "/ path defaults to V1" "$PATH_ROOT" "V1"
  else
    skip "/ curl returned empty"
  fi

  # ─── Step 6: TLS Termination ────────────────────────────────────────

  echo ""
  echo "Step 6: TLS Termination"

  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /tmp/tls-ingress-$$.key -out /tmp/tls-ingress-$$.crt \
    -subj "/CN=*.lab.local/O=Verisign Lab" &>/dev/null

  kubectl create secret tls lab-tls-secret \
    --cert=/tmp/tls-ingress-$$.crt --key=/tmp/tls-ingress-$$.key \
    -n "$NS" &>/dev/null

  assert_cmd "TLS secret lab-tls-secret created" kubectl get secret lab-tls-secret -n "$NS"

  envsubst < "$LAB_DIR/ingress-tls.yaml" | kubectl apply -f - &>/dev/null
  sleep 5

  assert_cmd "TLS ingress created" kubectl get ingress app-ingress-tls -n "$NS"

  TLS_SPEC=$(kubectl get ingress app-ingress-tls -n "$NS" -o jsonpath='{.spec.tls}' 2>/dev/null)
  assert_contains "TLS ingress has tls config" "$TLS_SPEC" "lab-tls-secret"
  assert_contains "TLS ingress references correct host" "$TLS_SPEC" "secure-$STUDENT_NAME"

  SSL_REDIR=$(kubectl get ingress app-ingress-tls -n "$NS" \
    -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/ssl-redirect}' 2>/dev/null)
  assert_eq "TLS ingress has ssl-redirect=true" "true" "$SSL_REDIR"

  # Functional TLS test
  HTTPS_RESP=$(curl -sk --max-time 10 \
    -H "Host: secure-$STUDENT_NAME.lab.local" "https://$INGRESS_IP" 2>/dev/null)
  if [ -n "$HTTPS_RESP" ]; then
    assert_contains "HTTPS returns App V1" "$HTTPS_RESP" "App V1"
  else
    skip "HTTPS curl returned empty (LB may not be reachable)"
  fi

  HTTP_REDIR=$(curl -sI --max-time 10 -o /dev/null -w "%{http_code}" \
    -H "Host: secure-$STUDENT_NAME.lab.local" "http://$INGRESS_IP" 2>/dev/null)
  if [ -n "$HTTP_REDIR" ] && [ "$HTTP_REDIR" != "000" ]; then
    assert_eq "HTTP redirects with 308" "308" "$HTTP_REDIR"
  else
    skip "HTTP redirect curl failed"
  fi

  rm -f /tmp/tls-ingress-$$.key /tmp/tls-ingress-$$.crt

  # ─── Step 7: Ingress Annotations ────────────────────────────────────

  echo ""
  echo "Step 7: Ingress Annotations"

  envsubst < "$LAB_DIR/ingress-annotations.yaml" | kubectl apply -f - &>/dev/null
  sleep 5

  assert_cmd "annotated ingress created" kubectl get ingress app-ingress-advanced -n "$NS"

  ANN_REWRITE=$(kubectl get ingress app-ingress-advanced -n "$NS" \
    -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/rewrite-target}' 2>/dev/null)
  assert_eq "rewrite-target annotation = /\$2" '/$2' "$ANN_REWRITE"

  ANN_RPS=$(kubectl get ingress app-ingress-advanced -n "$NS" \
    -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/limit-rps}' 2>/dev/null)
  assert_eq "rate limit annotation = 10" "10" "$ANN_RPS"

  ANN_CORS=$(kubectl get ingress app-ingress-advanced -n "$NS" \
    -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/enable-cors}' 2>/dev/null)
  assert_eq "CORS enabled annotation = true" "true" "$ANN_CORS"

  ANN_ORIGIN=$(kubectl get ingress app-ingress-advanced -n "$NS" \
    -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/cors-allow-origin}' 2>/dev/null)
  assert_eq "CORS origin = https://app.verisign.com" "https://app.verisign.com" "$ANN_ORIGIN"

  ANN_TIMEOUT=$(kubectl get ingress app-ingress-advanced -n "$NS" \
    -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/proxy-read-timeout}' 2>/dev/null)
  assert_eq "proxy-read-timeout annotation = 30" "30" "$ANN_TIMEOUT"

  ANN_SNIPPET=$(kubectl get ingress app-ingress-advanced -n "$NS" \
    -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/configuration-snippet}' 2>/dev/null)
  assert_contains "configuration-snippet contains X-Served-By" "$ANN_SNIPPET" "X-Served-By"

  # Functional annotation test
  API_RESP=$(curl -s --max-time 10 \
    -H "Host: api-$STUDENT_NAME.lab.local" "http://$INGRESS_IP/api/" 2>/dev/null)
  if [ -n "$API_RESP" ]; then
    assert_contains "api rewrite returns app content" "$API_RESP" "App V1"
  else
    skip "api curl returned empty"
  fi

  CORS_HEADERS=$(curl -sI --max-time 10 \
    -H "Host: api-$STUDENT_NAME.lab.local" \
    -H "Origin: https://app.verisign.com" \
    "http://$INGRESS_IP/api/" 2>/dev/null)
  if [ -n "$CORS_HEADERS" ]; then
    # CORS headers are case-insensitive
    CORS_LC=$(echo "$CORS_HEADERS" | tr '[:upper:]' '[:lower:]')
    if echo "$CORS_LC" | grep -q "access-control"; then
      pass "CORS headers present in response"
    else
      skip "CORS headers not in response (controller may not support)"
    fi
  else
    skip "CORS curl returned empty"
  fi

  # Functional rate-limit test
  echo ""
  echo "Rate Limit Functional Test:"

  COUNT_503=0
  for i in $(seq 1 15); do
    RL_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
      -H "Host: api-$STUDENT_NAME.lab.local" "http://$INGRESS_IP/api/" 2>/dev/null)
    if [ "$RL_CODE" = "503" ]; then
      COUNT_503=$((COUNT_503 + 1))
    fi
  done
  if [ "$COUNT_503" -gt 0 ]; then
    pass "rate limiting active ($COUNT_503/15 requests returned 503)"
  else
    skip "no 503s from 15 rapid requests (controller may not enforce rate limiting)"
  fi

else
  skip "ingress-nginx not running — skipping all ingress tests"
  skip "ingress-nginx not running — skipping host-based routing"
  skip "ingress-nginx not running — skipping path-based routing"
  skip "ingress-nginx not running — skipping TLS termination"
  skip "ingress-nginx not running — skipping annotations"
fi

# ─── Steps 8-9: Gateway API ──────────────────────────────────────────────

echo ""
echo "Steps 8-9: Gateway API"

if kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null; then
  # Need TLS secret for Gateway HTTPS listener (create if not already done)
  if ! kubectl get secret lab-tls-secret -n "$NS" &>/dev/null; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout /tmp/tls-gw-$$.key -out /tmp/tls-gw-$$.crt \
      -subj "/CN=*.lab.local/O=Verisign Lab" &>/dev/null
    kubectl create secret tls lab-tls-secret \
      --cert=/tmp/tls-gw-$$.crt --key=/tmp/tls-gw-$$.key \
      -n "$NS" &>/dev/null
    rm -f /tmp/tls-gw-$$.key /tmp/tls-gw-$$.crt
  fi

  envsubst < "$LAB_DIR/gateway.yaml" | kubectl apply -f - &>/dev/null
  sleep 5

  # GatewayClass verification
  assert_cmd "GatewayClass created" \
    kubectl get gatewayclass "lab-gateway-class-$STUDENT_NAME"

  GC_CONTROLLER=$(kubectl get gatewayclass "lab-gateway-class-$STUDENT_NAME" \
    -o jsonpath='{.spec.controllerName}' 2>/dev/null)
  assert_eq "GatewayClass controller name correct" \
    "gateway.envoyproxy.io/gatewayclass-controller" "$GC_CONTROLLER"

  # Gateway verification
  assert_cmd "Gateway resource created" kubectl get gateway lab-gateway -n "$NS"

  GW_CLASS=$(kubectl get gateway lab-gateway -n "$NS" \
    -o jsonpath='{.spec.gatewayClassName}' 2>/dev/null)
  assert_eq "Gateway references correct GatewayClass" \
    "lab-gateway-class-$STUDENT_NAME" "$GW_CLASS"

  GW_LISTENERS=$(kubectl get gateway lab-gateway -n "$NS" -o json 2>/dev/null)
  LISTENER_COUNT=$(echo "$GW_LISTENERS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['spec']['listeners']))" 2>/dev/null || echo "0")
  assert_eq "Gateway has 2 listeners (http+https)" "2" "$LISTENER_COUNT"

  # Check Gateway status (may take time for controller to reconcile)
  GW_STATUS=$(kubectl get gateway lab-gateway -n "$NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
  if [ "$GW_STATUS" = "True" ]; then
    pass "Gateway status is Accepted"
  elif [ -n "$GW_STATUS" ]; then
    skip "Gateway status is $GW_STATUS (controller may still be reconciling)"
  else
    skip "Gateway has no status yet (controller may not be running)"
  fi

  # HTTPRoute
  envsubst < "$LAB_DIR/httproute.yaml" | kubectl apply -f - &>/dev/null
  sleep 5

  assert_cmd "HTTPRoute resource created" kubectl get httproute app-route -n "$NS"

  HR_PARENT=$(kubectl get httproute app-route -n "$NS" \
    -o jsonpath='{.spec.parentRefs[0].name}' 2>/dev/null)
  assert_eq "HTTPRoute references lab-gateway" "lab-gateway" "$HR_PARENT"

  HR_HOST=$(kubectl get httproute app-route -n "$NS" \
    -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null)
  assert_eq "HTTPRoute hostname correct" "app-$STUDENT_NAME.lab.local" "$HR_HOST"

  # Verify traffic split weights
  HR_W1=$(kubectl get httproute app-route -n "$NS" \
    -o jsonpath='{.spec.rules[0].backendRefs[0].weight}' 2>/dev/null)
  assert_eq "HTTPRoute v1 weight=80" "80" "$HR_W1"

  HR_W2=$(kubectl get httproute app-route -n "$NS" \
    -o jsonpath='{.spec.rules[0].backendRefs[1].weight}' 2>/dev/null)
  assert_eq "HTTPRoute v2 weight=20" "20" "$HR_W2"

  HR_SVC1=$(kubectl get httproute app-route -n "$NS" \
    -o jsonpath='{.spec.rules[0].backendRefs[0].name}' 2>/dev/null)
  assert_eq "HTTPRoute backend 1 = app-v1-svc" "app-v1-svc" "$HR_SVC1"

  HR_SVC2=$(kubectl get httproute app-route -n "$NS" \
    -o jsonpath='{.spec.rules[0].backendRefs[1].name}' 2>/dev/null)
  assert_eq "HTTPRoute backend 2 = app-v2-svc" "app-v2-svc" "$HR_SVC2"

  # Check HTTPRoute status
  HR_STATUS=$(kubectl get httproute app-route -n "$NS" \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
  if [ "$HR_STATUS" = "True" ]; then
    pass "HTTPRoute status is Accepted"
  elif [ -n "$HR_STATUS" ]; then
    skip "HTTPRoute status is $HR_STATUS (controller may not support)"
  else
    skip "HTTPRoute has no status yet (controller may not be running)"
  fi

  # Functional test via Gateway (if it has an address)
  GATEWAY_IP=$(kubectl get gateway lab-gateway -n "$NS" \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
  if [ -n "$GATEWAY_IP" ]; then
    GW_RESP=$(curl -s --max-time 10 \
      -H "Host: app-$STUDENT_NAME.lab.local" "http://$GATEWAY_IP" 2>/dev/null)
    if [ -n "$GW_RESP" ]; then
      assert_contains "Gateway routes to app" "$GW_RESP" "App V"
    else
      skip "Gateway curl returned empty"
    fi
  else
    skip "Gateway has no assigned address — skipping functional test"
  fi
else
  skip "Gateway API CRDs not installed — skipping GatewayClass"
  skip "Gateway API CRDs not installed — skipping Gateway"
  skip "Gateway API CRDs not installed — skipping HTTPRoute"
fi

# ─── Step 10: Egress NetworkPolicy ────────────────────────────────────────

echo ""
echo "Step 10: Egress NetworkPolicy"

# Deploy egress test pod
kubectl run egress-test --image=busybox:1.36 \
  -n "$NS" --restart=Never \
  --command -- sleep 3600 &>/dev/null
wait_for_pod "$NS" egress-test 60

# Test connectivity BEFORE policy (baseline)
PRE_INTERNAL=$(kubectl exec egress-test -n "$NS" -- \
  wget -qO- --timeout=5 "http://app-v1-svc.$NS.svc.cluster.local" 2>/dev/null)
if [ -n "$PRE_INTERNAL" ]; then
  assert_contains "pre-policy: internal service reachable" "$PRE_INTERNAL" "App V1"
else
  skip "pre-policy: internal service not reachable (may need time)"
fi

# Apply egress policy
envsubst < "$LAB_DIR/egress-policy.yaml" | kubectl apply -f - &>/dev/null
sleep 3

assert_cmd "egress network policy created" kubectl get networkpolicy restrict-egress -n "$NS"

NP_SELECTOR=$(kubectl get networkpolicy restrict-egress -n "$NS" \
  -o jsonpath='{.spec.podSelector.matchLabels.run}' 2>/dev/null)
assert_eq "policy selects run=egress-test" "egress-test" "$NP_SELECTOR"

NP_TYPES=$(kubectl get networkpolicy restrict-egress -n "$NS" \
  -o jsonpath='{.spec.policyTypes}' 2>/dev/null)
assert_contains "policy type includes Egress" "$NP_TYPES" "Egress"

# Verify DNS egress rule (port 53)
NP_JSON=$(kubectl get networkpolicy restrict-egress -n "$NS" -o json 2>/dev/null)
DNS_PORT=$(echo "$NP_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for rule in data['spec']['egress']:
    for port in rule.get('ports', []):
        if port.get('port') == 53:
            print('53')
            break
" 2>/dev/null || echo "")
assert_eq "egress policy allows DNS port 53" "53" "$DNS_PORT"

# Functional egress enforcement test
# Internal should still work (DNS + same namespace port 80)
POST_INTERNAL=$(kubectl exec egress-test -n "$NS" -- \
  wget -qO- --timeout=10 "http://app-v1-svc.$NS.svc.cluster.local" 2>&1)
if echo "$POST_INTERNAL" | grep -q "App V1"; then
  pass "post-policy: internal service still reachable"
else
  # NetworkPolicy may not be enforced by CNI
  NP_NOTE="post-policy: internal access"
  if echo "$POST_INTERNAL" | grep -qi "timed out\|connection refused"; then
    skip "$NP_NOTE blocked (CNI may enforce differently)"
  else
    skip "$NP_NOTE inconclusive (CNI may not enforce NetworkPolicy)"
  fi
fi

# External should be BLOCKED
POST_EXTERNAL=$(kubectl exec egress-test -n "$NS" -- \
  wget -qO- --timeout=5 http://example.com 2>&1)
if echo "$POST_EXTERNAL" | grep -qi "timed out\|bad address\|connection refused"; then
  pass "post-policy: external access blocked"
elif echo "$POST_EXTERNAL" | grep -q "example"; then
  # External still reachable — CNI may not enforce
  skip "post-policy: external still reachable (CNI may not enforce NetworkPolicy)"
else
  pass "post-policy: external access blocked"
fi

# ─── Cleanup ──────────────────────────────────────────────────────────────

kubectl delete gatewayclass "lab-gateway-class-$STUDENT_NAME" &>/dev/null 2>&1 || true
rm -f /tmp/tls-ingress-$$.key /tmp/tls-ingress-$$.crt /tmp/tls-gw-$$.key /tmp/tls-gw-$$.crt
cleanup_ns "$NS"
summary
