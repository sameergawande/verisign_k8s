#!/bin/bash
###############################################################################
# Lab 5 Test: Configuration, Secrets, and Vault
# Covers: ConfigMaps (literals, files), envFrom, valueFrom, volume mounts,
#         Secrets (opaque, TLS, volume with permissions), immutable configs,
#         projected volumes, ConfigMap update propagation, Vault, ExternalSecrets
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/../lab-05" && pwd)"
source "$SCRIPT_DIR/lib.sh"

export STUDENT_NAME="test-$$"
NS="lab05-$STUDENT_NAME"
echo "=== Lab 5: Config & Secrets (ns: $NS) ==="
echo ""

kubectl create namespace "$NS" &>/dev/null

# ─── Step 1: ConfigMap from literals ────────────────────────────────────────

echo "Step 1: ConfigMaps from Literals and Files"

kubectl create configmap app-config -n "$NS" \
  --from-literal=APP_ENV=production \
  --from-literal=APP_LOG_LEVEL=info \
  --from-literal=APP_MAX_CONNECTIONS=100 \
  --from-literal=APP_CACHE_TTL=3600 &>/dev/null

CM_ENV=$(kubectl get configmap app-config -n "$NS" -o jsonpath='{.data.APP_ENV}' 2>/dev/null)
assert_eq "configmap literal APP_ENV=production" "production" "$CM_ENV"

CM_LOG=$(kubectl get configmap app-config -n "$NS" -o jsonpath='{.data.APP_LOG_LEVEL}' 2>/dev/null)
assert_eq "configmap literal APP_LOG_LEVEL=info" "info" "$CM_LOG"

CM_MAX=$(kubectl get configmap app-config -n "$NS" -o jsonpath='{.data.APP_MAX_CONNECTIONS}' 2>/dev/null)
assert_eq "configmap literal APP_MAX_CONNECTIONS=100" "100" "$CM_MAX"

CM_TTL=$(kubectl get configmap app-config -n "$NS" -o jsonpath='{.data.APP_CACHE_TTL}' 2>/dev/null)
assert_eq "configmap literal APP_CACHE_TTL=3600" "3600" "$CM_TTL"

# ConfigMap from files
cp "$LAB_DIR/nginx.conf" /tmp/nginx.conf
envsubst < "$LAB_DIR/app.properties" > /tmp/app.properties

kubectl create configmap app-files -n "$NS" \
  --from-file=nginx.conf=/tmp/nginx.conf \
  --from-file=app.properties=/tmp/app.properties &>/dev/null

assert_cmd "configmap app-files created" kubectl get configmap app-files -n "$NS"

CM_NGINX=$(kubectl get configmap app-files -n "$NS" -o jsonpath='{.data.nginx\.conf}' 2>/dev/null)
assert_contains "app-files contains nginx.conf data" "$CM_NGINX" "listen 80"

CM_PROPS=$(kubectl get configmap app-files -n "$NS" -o jsonpath='{.data.app\.properties}' 2>/dev/null)
assert_contains "app-files contains app.properties with student name" "$CM_PROPS" "$STUDENT_NAME"

rm -f /tmp/nginx.conf /tmp/app.properties

# ─── Step 2: Pod with envFrom ──────────────────────────────────────────────

echo ""
echo "Step 2: Consume ConfigMap as Environment Variables"

envsubst < "$LAB_DIR/pod-envfrom.yaml" | kubectl apply -f - &>/dev/null
wait_for_pod "$NS" env-from-demo 60

ENV_APP=$(kubectl exec env-from-demo -n "$NS" -- printenv APP_ENV 2>/dev/null)
assert_eq "envFrom injects APP_ENV=production" "production" "$ENV_APP"

ENV_LOG=$(kubectl exec env-from-demo -n "$NS" -- printenv APP_LOG_LEVEL 2>/dev/null)
assert_eq "envFrom injects APP_LOG_LEVEL=info" "info" "$ENV_LOG"

ENV_MAX=$(kubectl exec env-from-demo -n "$NS" -- printenv APP_MAX_CONNECTIONS 2>/dev/null)
assert_eq "envFrom injects APP_MAX_CONNECTIONS=100" "100" "$ENV_MAX"

# Pod with valueFrom
envsubst < "$LAB_DIR/pod-valuefrom.yaml" | kubectl apply -f - &>/dev/null
wait_for_pod "$NS" value-from-demo 60

VF_ENV=$(kubectl exec value-from-demo -n "$NS" -- printenv ENVIRONMENT 2>/dev/null)
assert_eq "valueFrom maps APP_ENV -> ENVIRONMENT" "production" "$VF_ENV"

VF_LOG=$(kubectl exec value-from-demo -n "$NS" -- printenv LOG_LEVEL 2>/dev/null)
assert_eq "valueFrom maps APP_LOG_LEVEL -> LOG_LEVEL" "info" "$VF_LOG"

VF_OUTPUT=$(kubectl logs value-from-demo -n "$NS" 2>/dev/null)
assert_contains "valueFrom pod output shows Env=production" "$VF_OUTPUT" "Env=production"
assert_contains "valueFrom pod output shows Log=info" "$VF_OUTPUT" "Log=info"

# ─── Step 3: Pod with volume mount ────────────────────────────────────────

echo ""
echo "Step 3: Consume ConfigMap as Volume Mounts"

envsubst < "$LAB_DIR/pod-volume-mount.yaml" | kubectl apply -f - &>/dev/null
wait_for_pod "$NS" volume-mount-demo 60

VOL_NGINX=$(kubectl exec volume-mount-demo -n "$NS" -- cat /etc/nginx/conf.d/default.conf 2>/dev/null)
assert_contains "volume mount nginx.conf at /etc/nginx/conf.d/default.conf" "$VOL_NGINX" "listen 80"
assert_contains "nginx.conf contains /health location" "$VOL_NGINX" "/health"

VOL_PROPS=$(kubectl exec volume-mount-demo -n "$NS" -- cat /etc/app/app.properties 2>/dev/null)
assert_contains "volume mount app.properties contains db.host" "$VOL_PROPS" "db.host"
assert_contains "volume mount app.properties contains student name" "$VOL_PROPS" "$STUDENT_NAME"

HEALTH=$(kubectl exec volume-mount-demo -n "$NS" -- curl -s http://localhost/health 2>/dev/null)
assert_eq "nginx /health endpoint returns OK" "OK" "$HEALTH"

# ─── Step 4: Create Secrets ───────────────────────────────────────────────

echo ""
echo "Step 4: Secrets"

kubectl create secret generic db-credentials -n "$NS" \
  --from-literal=DB_USERNAME=app_user \
  --from-literal=DB_PASSWORD='S3cur3P@ssw0rd!' \
  --from-literal=DB_HOST="postgres-svc.lab05-$STUDENT_NAME.svc.cluster.local" &>/dev/null

SECRET_USER=$(kubectl get secret db-credentials -n "$NS" \
  -o jsonpath='{.data.DB_USERNAME}' 2>/dev/null | base64 -d)
assert_eq "secret DB_USERNAME decoded = app_user" "app_user" "$SECRET_USER"

SECRET_PASS=$(kubectl get secret db-credentials -n "$NS" \
  -o jsonpath='{.data.DB_PASSWORD}' 2>/dev/null | base64 -d)
assert_eq "secret DB_PASSWORD decoded" "S3cur3P@ssw0rd!" "$SECRET_PASS"

SECRET_HOST=$(kubectl get secret db-credentials -n "$NS" \
  -o jsonpath='{.data.DB_HOST}' 2>/dev/null | base64 -d)
assert_contains "secret DB_HOST contains namespace" "$SECRET_HOST" "$STUDENT_NAME"

# TLS Secret
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /tmp/tls-$$.key -out /tmp/tls-$$.crt \
  -subj "/CN=app.lab05-$STUDENT_NAME.local/O=Verisign Lab" &>/dev/null

kubectl create secret tls app-tls \
  --cert=/tmp/tls-$$.crt \
  --key=/tmp/tls-$$.key \
  -n "$NS" &>/dev/null

TLS_TYPE=$(kubectl get secret app-tls -n "$NS" -o jsonpath='{.type}' 2>/dev/null)
assert_eq "TLS secret type is kubernetes.io/tls" "kubernetes.io/tls" "$TLS_TYPE"

TLS_CRT=$(kubectl get secret app-tls -n "$NS" -o jsonpath='{.data.tls\.crt}' 2>/dev/null)
if [ -n "$TLS_CRT" ]; then
  pass "TLS secret contains tls.crt"
else
  fail "TLS secret missing tls.crt"
fi

TLS_KEY=$(kubectl get secret app-tls -n "$NS" -o jsonpath='{.data.tls\.key}' 2>/dev/null)
if [ -n "$TLS_KEY" ]; then
  pass "TLS secret contains tls.key"
else
  fail "TLS secret missing tls.key"
fi

rm -f /tmp/tls-$$.key /tmp/tls-$$.crt

# ─── Step 5: Consume Secrets ──────────────────────────────────────────────

echo ""
echo "Step 5: Consume Secrets as Env Vars and Volume Mounts"

# Secret as env vars
envsubst < "$LAB_DIR/pod-secret-env.yaml" | kubectl apply -f - &>/dev/null
wait_for_pod "$NS" secret-env-demo 60

SEC_HOST=$(kubectl exec secret-env-demo -n "$NS" -- printenv DB_HOST 2>/dev/null)
assert_contains "secret env DB_HOST injected" "$SEC_HOST" "postgres-svc"

SEC_USER=$(kubectl exec secret-env-demo -n "$NS" -- printenv DB_USER 2>/dev/null)
assert_eq "secret env DB_USER injected" "app_user" "$SEC_USER"

SEC_OUTPUT=$(kubectl logs secret-env-demo -n "$NS" 2>/dev/null)
assert_contains "secret-env-demo log shows Host=" "$SEC_OUTPUT" "Host="
assert_contains "secret-env-demo log shows User=app_user" "$SEC_OUTPUT" "User=app_user"

# Secret as volume mount
envsubst < "$LAB_DIR/pod-secret-volume.yaml" | kubectl apply -f - &>/dev/null
wait_for_pod "$NS" secret-vol-demo 60

SV_USER=$(kubectl exec secret-vol-demo -n "$NS" -- cat /etc/db-creds/DB_USERNAME 2>/dev/null)
assert_eq "secret volume mount DB_USERNAME=app_user" "app_user" "$SV_USER"

SV_PASS=$(kubectl exec secret-vol-demo -n "$NS" -- cat /etc/db-creds/DB_PASSWORD 2>/dev/null)
assert_eq "secret volume mount DB_PASSWORD" "S3cur3P@ssw0rd!" "$SV_PASS"

# Check 0400 permissions
SV_PERMS=$(kubectl exec secret-vol-demo -n "$NS" -- ls -la /etc/db-creds/DB_USERNAME 2>/dev/null)
assert_contains "secret volume permissions are 0400" "$SV_PERMS" "r--------"

SV_LOG=$(kubectl logs secret-vol-demo -n "$NS" 2>/dev/null)
assert_contains "secret-vol-demo lists /etc/db-creds/" "$SV_LOG" "DB_USERNAME"

# ─── Step 6: Immutable ConfigMap ──────────────────────────────────────────

echo ""
echo "Step 6: Immutable ConfigMap"

envsubst < "$LAB_DIR/immutable-config.yaml" | kubectl apply -f - &>/dev/null

IMMUTABLE=$(kubectl get configmap immutable-app-config -n "$NS" -o jsonpath='{.immutable}' 2>/dev/null)
assert_eq "configmap immutable field is true" "true" "$IMMUTABLE"

IM_VER=$(kubectl get configmap immutable-app-config -n "$NS" -o jsonpath='{.data.APP_VERSION}' 2>/dev/null)
assert_eq "immutable configmap APP_VERSION=2.1.0" "2.1.0" "$IM_VER"

IM_FLAGS=$(kubectl get configmap immutable-app-config -n "$NS" -o jsonpath='{.data.FEATURE_FLAGS}' 2>/dev/null)
assert_contains "immutable configmap has FEATURE_FLAGS" "$IM_FLAGS" "dark-mode=true"

PATCH_RESULT=$(kubectl patch configmap immutable-app-config -n "$NS" \
  --type merge -p '{"data":{"APP_VERSION":"2.2.0"}}' 2>&1)
assert_contains "immutable configmap rejects update" "$PATCH_RESULT" "immutable"

# ─── Step 7: Projected Volumes ────────────────────────────────────────────

echo ""
echo "Step 7: Projected Volumes"

envsubst < "$LAB_DIR/pod-projected.yaml" | kubectl apply -f - &>/dev/null
wait_for_pod "$NS" projected-demo 60

PROJ_LS=$(kubectl exec projected-demo -n "$NS" -- ls /etc/projected 2>/dev/null)
assert_contains "projected volume contains APP_ENV" "$PROJ_LS" "APP_ENV"
assert_contains "projected volume contains DB_USERNAME" "$PROJ_LS" "DB_USERNAME"
assert_contains "projected volume contains labels" "$PROJ_LS" "labels"
assert_contains "projected volume contains namespace" "$PROJ_LS" "namespace"

PROJ_ENV=$(kubectl exec projected-demo -n "$NS" -- cat /etc/projected/APP_ENV 2>/dev/null)
assert_eq "projected APP_ENV content = production" "production" "$PROJ_ENV"

PROJ_USER=$(kubectl exec projected-demo -n "$NS" -- cat /etc/projected/DB_USERNAME 2>/dev/null)
assert_eq "projected DB_USERNAME content = app_user" "app_user" "$PROJ_USER"

PROJ_LABELS=$(kubectl exec projected-demo -n "$NS" -- cat /etc/projected/labels 2>/dev/null)
assert_contains "projected labels contains app=projected-demo" "$PROJ_LABELS" "projected-demo"

PROJ_NS=$(kubectl exec projected-demo -n "$NS" -- cat /etc/projected/namespace 2>/dev/null)
assert_eq "projected namespace matches" "$NS" "$PROJ_NS"

# ─── Step 8: ConfigMap Update Propagation ─────────────────────────────────

echo ""
echo "Step 8: ConfigMap Update Propagation"

envsubst < "$LAB_DIR/pod-update-test.yaml" | kubectl apply -f - &>/dev/null
wait_for_pod "$NS" update-test 60

# Read initial file value
INITIAL_FILE=$(kubectl exec update-test -n "$NS" -- cat /etc/config/APP_LOG_LEVEL 2>/dev/null)
assert_eq "initial volume APP_LOG_LEVEL=info" "info" "$INITIAL_FILE"

# Patch the ConfigMap
kubectl patch configmap app-config -n "$NS" \
  --type merge -p '{"data":{"APP_LOG_LEVEL":"debug"}}' &>/dev/null

assert_cmd "configmap app-config patched" \
  kubectl get configmap app-config -n "$NS" -o jsonpath='{.data.APP_LOG_LEVEL}'

PATCHED_VAL=$(kubectl get configmap app-config -n "$NS" -o jsonpath='{.data.APP_LOG_LEVEL}' 2>/dev/null)
assert_eq "configmap APP_LOG_LEVEL updated to debug" "debug" "$PATCHED_VAL"

# Wait for volume propagation (kubelet sync ~60s)
echo "  ... waiting 65s for volume propagation"
sleep 65

UPDATED_FILE=$(kubectl exec update-test -n "$NS" -- cat /etc/config/APP_LOG_LEVEL 2>/dev/null)
assert_eq "volume mount updated to debug after propagation" "debug" "$UPDATED_FILE"

# Env var should NOT have updated (requires pod restart)
ENV_STILL=$(kubectl exec update-test -n "$NS" -- printenv APP_LOG_LEVEL 2>/dev/null)
assert_eq "env var APP_LOG_LEVEL still info (no auto-update)" "info" "$ENV_STILL"

# Verify from logs that both are visible
LOG_OUTPUT=$(kubectl logs update-test -n "$NS" --tail=1 2>/dev/null)
assert_contains "log shows ENV: info (env not updated)" "$LOG_OUTPUT" "ENV: info"
assert_contains "log shows FILE: debug (volume updated)" "$LOG_OUTPUT" "FILE: debug"

# ─── Step 9-11: Vault & External Secrets ──────────────────────────────────

echo ""
echo "Steps 9-11: Vault & External Secrets"

if kubectl get pods -n vault --no-headers 2>/dev/null | grep -q Running; then
  # Write secret to Vault
  kubectl exec -n vault vault-0 -- vault kv put "secret/lab05-$STUDENT_NAME/database" \
    username=admin password=s3cureP@ss \
    host="postgres.lab05-$STUDENT_NAME.svc.cluster.local" port=5432 &>/dev/null
  if [ $? -eq 0 ]; then
    pass "vault secret written"
  else
    fail "vault secret write failed"
  fi

  # Read back individual fields
  VAULT_USER=$(kubectl exec -n vault vault-0 -- \
    vault kv get -field=username "secret/lab05-$STUDENT_NAME/database" 2>/dev/null)
  assert_eq "vault secret username=admin" "admin" "$VAULT_USER"

  VAULT_PASS=$(kubectl exec -n vault vault-0 -- \
    vault kv get -field=password "secret/lab05-$STUDENT_NAME/database" 2>/dev/null)
  assert_eq "vault secret password=s3cureP@ss" "s3cureP@ss" "$VAULT_PASS"

  VAULT_PORT=$(kubectl exec -n vault vault-0 -- \
    vault kv get -field=port "secret/lab05-$STUDENT_NAME/database" 2>/dev/null)
  assert_eq "vault secret port=5432" "5432" "$VAULT_PORT"

  # Create policy and role
  kubectl exec -n vault vault-0 -- sh -c "
    vault policy write lab05-readonly-$STUDENT_NAME - <<POLICY
path \"secret/data/lab05-$STUDENT_NAME/*\" {
  capabilities = [\"read\", \"list\"]
}
path \"secret/metadata/lab05-$STUDENT_NAME/*\" {
  capabilities = [\"read\", \"list\"]
}
POLICY
  " &>/dev/null
  if [ $? -eq 0 ]; then
    pass "vault policy created"
  else
    fail "vault policy creation failed"
  fi

  kubectl exec -n vault vault-0 -- vault write "auth/kubernetes/role/lab05-role-$STUDENT_NAME" \
    bound_service_account_names=lab05-sa \
    bound_service_account_namespaces="lab05-$STUDENT_NAME" \
    policies="lab05-readonly-$STUDENT_NAME" \
    ttl=1h &>/dev/null
  if [ $? -eq 0 ]; then
    pass "vault kubernetes auth role created"
  else
    fail "vault kubernetes auth role creation failed"
  fi

  # ExternalSecret (conditional on ESO running)
  if kubectl get crd externalsecrets.external-secrets.io &>/dev/null; then
    kubectl create serviceaccount lab05-sa -n "$NS" &>/dev/null 2>&1 || true

    if kubectl get clustersecretstore vault-backend &>/dev/null; then
      cat <<ESEOF | kubectl apply -f - &>/dev/null
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: vault-db-credentials
  namespace: $NS
spec:
  refreshInterval: "1m"
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: vault-db-credentials
    creationPolicy: Owner
  data:
    - secretKey: username
      remoteRef:
        key: secret/lab05-$STUDENT_NAME/database
        property: username
    - secretKey: password
      remoteRef:
        key: secret/lab05-$STUDENT_NAME/database
        property: password
ESEOF
      assert_cmd "externalsecret resource created" \
        kubectl get externalsecret vault-db-credentials -n "$NS"

      # Wait for sync (up to 90s)
      SYNCED=false
      for i in $(seq 1 18); do
        ES_STATUS=$(kubectl get externalsecret vault-db-credentials -n "$NS" \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        if [ "$ES_STATUS" = "True" ]; then
          SYNCED=true
          break
        fi
        sleep 5
      done

      if [ "$SYNCED" = "true" ]; then
        pass "externalsecret synced successfully"

        SYNCED_USER=$(kubectl get secret vault-db-credentials -n "$NS" \
          -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)
        assert_eq "synced secret username=admin" "admin" "$SYNCED_USER"

        SYNCED_PASS=$(kubectl get secret vault-db-credentials -n "$NS" \
          -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
        assert_eq "synced secret password=s3cureP@ss" "s3cureP@ss" "$SYNCED_PASS"
      else
        fail "externalsecret did not sync within 90s"
      fi
    else
      skip "ClusterSecretStore vault-backend not found"
    fi
  else
    skip "ExternalSecrets CRDs not installed"
  fi

  # Clean up vault resources
  kubectl exec -n vault vault-0 -- vault kv metadata delete "secret/lab05-$STUDENT_NAME/database" &>/dev/null
  kubectl exec -n vault vault-0 -- vault delete "auth/kubernetes/role/lab05-role-$STUDENT_NAME" &>/dev/null
  kubectl exec -n vault vault-0 -- vault policy delete "lab05-readonly-$STUDENT_NAME" &>/dev/null
else
  skip "vault not running — skipping Vault integration tests"
  skip "vault not running — skipping ExternalSecret tests"
fi

# ─── Cleanup ──────────────────────────────────────────────────────────────

cleanup_ns "$NS"
summary
