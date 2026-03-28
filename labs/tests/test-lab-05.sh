#!/bin/bash
###############################################################################
# Lab 5 Test: Configuration, Secrets, and Vault
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/../lab-05" && pwd)"
source "$SCRIPT_DIR/lib.sh"

export STUDENT_NAME="test-$$"
NS="lab05-$STUDENT_NAME"
echo "=== Lab 5: Config & Secrets (ns: $NS) ==="
echo ""

kubectl create namespace "$NS" &>/dev/null

# ─── ConfigMap from literals ────────────────────────────────────────────────

echo "ConfigMaps:"
kubectl create configmap app-config -n "$NS" \
  --from-literal=APP_ENV=production \
  --from-literal=LOG_LEVEL=info \
  --from-literal=MAX_CONNECTIONS=100 &>/dev/null

CM=$(kubectl get configmap app-config -n "$NS" -o jsonpath='{.data.APP_ENV}' 2>/dev/null)
assert_eq "configmap literal APP_ENV" "production" "$CM"

# ConfigMap from file
cp "$LAB_DIR/nginx.conf" /tmp/nginx-test-$$.conf
kubectl create configmap nginx-config -n "$NS" --from-file=/tmp/nginx-test-$$.conf &>/dev/null
rm -f /tmp/nginx-test-$$.conf
assert_cmd "configmap from file created" kubectl get configmap nginx-config -n "$NS"

# ─── Pod with envFrom ──────────────────────────────────────────────────────

echo ""
echo "Pod Environment Injection:"
envsubst < "$LAB_DIR/pod-envfrom.yaml" | kubectl apply -f - &>/dev/null
wait_for_pod "$NS" env-from-demo 60

ENV_VAL=$(kubectl exec env-from-demo -n "$NS" -- printenv APP_ENV 2>/dev/null)
assert_eq "envFrom injects APP_ENV" "production" "$ENV_VAL"

# ─── Pod with volume mount ─────────────────────────────────────────────────

echo ""
echo "Volume Mount:"
envsubst < "$LAB_DIR/pod-volume-mount.yaml" | kubectl apply -f - &>/dev/null
wait_for_pod "$NS" volume-mount-demo 60

VOL_DATA=$(kubectl exec volume-mount-demo -n "$NS" -- cat /etc/app/app.properties 2>/dev/null)
assert_contains "volume mount exposes app.properties" "$VOL_DATA" "db.host"

# ─── Secrets ────────────────────────────────────────────────────────────────

echo ""
echo "Secrets:"
kubectl create secret generic db-credentials -n "$NS" \
  --from-literal=DB_HOST=db.example.com \
  --from-literal=DB_USERNAME=admin &>/dev/null

SECRET_USER=$(kubectl get secret db-credentials -n "$NS" -o jsonpath='{.data.DB_USERNAME}' 2>/dev/null | base64 -d)
assert_eq "secret DB_USERNAME decoded" "admin" "$SECRET_USER"

envsubst < "$LAB_DIR/pod-secret-env.yaml" | kubectl apply -f - &>/dev/null
wait_for_pod "$NS" secret-env-demo 60

SEC_ENV=$(kubectl exec secret-env-demo -n "$NS" -- printenv DB_USER 2>/dev/null)
assert_eq "secret env injected" "admin" "$SEC_ENV"

# ─── Immutable ConfigMap ───────────────────────────────────────────────────

echo ""
echo "Immutable ConfigMap:"
envsubst < "$LAB_DIR/immutable-config.yaml" | kubectl apply -f - &>/dev/null

IMMUTABLE=$(kubectl get configmap immutable-app-config -n "$NS" -o jsonpath='{.immutable}' 2>/dev/null)
assert_eq "configmap is immutable" "true" "$IMMUTABLE"

PATCH_RESULT=$(kubectl patch configmap immutable-app-config -n "$NS" --type merge -p '{"data":{"VERSION":"2.0"}}' 2>&1)
assert_contains "immutable configmap rejects update" "$PATCH_RESULT" "immutable"

# ─── Vault integration ─────────────────────────────────────────────────────

echo ""
echo "Vault Integration:"
if kubectl get pods -n vault --no-headers 2>/dev/null | grep -q Running; then
  # Seed test secret
  kubectl exec -n vault vault-0 -- vault kv put "secret/lab05-$STUDENT_NAME/database" \
    username=testuser password=testpass host=db.test 2>/dev/null
  if [ $? -eq 0 ]; then
    pass "vault secret seeded"
  else
    fail "vault secret seeding failed"
  fi

  # Read it back
  VAULT_USER=$(kubectl exec -n vault vault-0 -- vault kv get -field=username \
    "secret/lab05-$STUDENT_NAME/database" 2>/dev/null)
  assert_eq "vault secret readable" "testuser" "$VAULT_USER"

  # Clean up vault secret
  kubectl exec -n vault vault-0 -- vault kv delete "secret/lab05-$STUDENT_NAME/database" &>/dev/null
else
  skip "vault not running"
fi

# ─── Cleanup ────────────────────────────────────────────────────────────────

cleanup_ns "$NS"
summary
