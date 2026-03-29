#!/bin/bash
###############################################################################
# Lab 5 Test: ConfigMaps and Secrets
# Covers: ConfigMaps (literals, files), envFrom, valueFrom, volume mounts,
#         Secrets (opaque, TLS, env vars, volume with permissions)
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/../lab-05" && pwd)"
source "$SCRIPT_DIR/lib.sh"

export STUDENT_NAME="test-$$"
NS="lab05-$STUDENT_NAME"
echo "=== Lab 5: ConfigMaps & Secrets (ns: $NS) ==="
echo ""

kubectl create namespace "$NS" &>/dev/null

# --- Step 1: ConfigMap from literals ------------------------------------------

echo "Step 1: ConfigMap from Literals"

kubectl create configmap app-config -n "$NS" \
  --from-literal=APP_ENV=production \
  --from-literal=APP_LOG_LEVEL=info \
  --from-literal=APP_MAX_THREADS=4 &>/dev/null

CM_ENV=$(kubectl get configmap app-config -n "$NS" -o jsonpath='{.data.APP_ENV}' 2>/dev/null)
assert_eq "configmap literal APP_ENV=production" "production" "$CM_ENV"

CM_LOG=$(kubectl get configmap app-config -n "$NS" -o jsonpath='{.data.APP_LOG_LEVEL}' 2>/dev/null)
assert_eq "configmap literal APP_LOG_LEVEL=info" "info" "$CM_LOG"

CM_THREADS=$(kubectl get configmap app-config -n "$NS" -o jsonpath='{.data.APP_MAX_THREADS}' 2>/dev/null)
assert_eq "configmap literal APP_MAX_THREADS=4" "4" "$CM_THREADS"

# --- Step 2: ConfigMap from files ---------------------------------------------

echo ""
echo "Step 2: ConfigMap from Files"

cp "$LAB_DIR/nginx.conf" /tmp/nginx.conf
envsubst < "$LAB_DIR/app.properties" > /tmp/app.properties

kubectl create configmap app-files -n "$NS" \
  --from-file=nginx.conf=/tmp/nginx.conf \
  --from-file=app.properties=/tmp/app.properties &>/dev/null

assert_cmd "configmap app-files created" kubectl get configmap app-files -n "$NS"

CM_NGINX=$(kubectl get configmap app-files -n "$NS" -o jsonpath='{.data.nginx\.conf}' 2>/dev/null)
assert_contains "app-files contains nginx.conf data" "$CM_NGINX" "listen 80"

CM_PROPS=$(kubectl get configmap app-files -n "$NS" -o jsonpath='{.data.app\.properties}' 2>/dev/null)
assert_contains "app-files contains app.properties data" "$CM_PROPS" "db.host"

rm -f /tmp/nginx.conf /tmp/app.properties

# --- Step 3: Pod with envFrom ------------------------------------------------

echo ""
echo "Step 3: Pod with envFrom"

envsubst < "$LAB_DIR/pod-envfrom.yaml" | kubectl apply -f - &>/dev/null
wait_for_pod "$NS" env-from-demo 60

ENV_APP=$(kubectl exec env-from-demo -n "$NS" -- printenv APP_ENV 2>/dev/null)
assert_eq "envFrom injects APP_ENV=production" "production" "$ENV_APP"

ENV_LOG=$(kubectl exec env-from-demo -n "$NS" -- printenv APP_LOG_LEVEL 2>/dev/null)
assert_eq "envFrom injects APP_LOG_LEVEL=info" "info" "$ENV_LOG"

# --- Step 4: Pod with valueFrom ----------------------------------------------

echo ""
echo "Step 4: Pod with valueFrom"

envsubst < "$LAB_DIR/pod-valuefrom.yaml" | kubectl apply -f - &>/dev/null
wait_for_pod "$NS" value-from-demo 60

VF_ENV=$(kubectl exec value-from-demo -n "$NS" -- printenv ENVIRONMENT 2>/dev/null)
assert_eq "valueFrom maps APP_ENV -> ENVIRONMENT" "production" "$VF_ENV"

VF_LOG=$(kubectl exec value-from-demo -n "$NS" -- printenv LOG_LEVEL 2>/dev/null)
assert_eq "valueFrom maps APP_LOG_LEVEL -> LOG_LEVEL" "info" "$VF_LOG"

# --- Step 5: Pod with volume mount -------------------------------------------

echo ""
echo "Step 5: Pod with Volume Mount"

envsubst < "$LAB_DIR/pod-volume-mount.yaml" | kubectl apply -f - &>/dev/null
wait_for_pod "$NS" volume-mount-demo 60

VOL_NGINX=$(kubectl exec volume-mount-demo -n "$NS" -- cat /etc/nginx/conf.d/default.conf 2>/dev/null)
assert_contains "volume mount /etc/nginx/conf.d/default.conf exists" "$VOL_NGINX" "listen 80"

VOL_PROPS=$(kubectl exec volume-mount-demo -n "$NS" -- cat /etc/app/app.properties 2>/dev/null)
assert_contains "volume mount /etc/app/app.properties exists" "$VOL_PROPS" "db.host"

# --- Step 6: Create opaque Secret --------------------------------------------

echo ""
echo "Step 6: Create Opaque Secret"

kubectl create secret generic db-credentials -n "$NS" \
  --from-literal=DB_HOST="postgres-svc.${NS}.svc.cluster.local" \
  --from-literal=DB_USERNAME=app_user \
  --from-literal=DB_PASSWORD='S3cur3P@ssw0rd!' &>/dev/null

assert_cmd "secret db-credentials exists" kubectl get secret db-credentials -n "$NS"

SECRET_TYPE=$(kubectl get secret db-credentials -n "$NS" -o jsonpath='{.type}' 2>/dev/null)
assert_eq "secret db-credentials is Opaque" "Opaque" "$SECRET_TYPE"

# --- Step 7: Create TLS Secret -----------------------------------------------

echo ""
echo "Step 7: Create TLS Secret"

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /tmp/tls-$$.key -out /tmp/tls-$$.crt \
  -subj "/CN=app.${NS}.local/O=Lab" &>/dev/null

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

# --- Step 8: Pod with secret as env vars -------------------------------------

echo ""
echo "Step 8: Consume Secret as Env Vars"

envsubst < "$LAB_DIR/pod-secret-env.yaml" | kubectl apply -f - &>/dev/null
wait_for_pod "$NS" secret-env-demo 60

SEC_HOST=$(kubectl exec secret-env-demo -n "$NS" -- printenv DB_HOST 2>/dev/null)
assert_contains "secret env DB_HOST injected" "$SEC_HOST" "postgres-svc"

SEC_USER=$(kubectl exec secret-env-demo -n "$NS" -- printenv DB_USER 2>/dev/null)
assert_eq "secret env DB_USER injected" "app_user" "$SEC_USER"

# --- Step 9: Pod with secret as volume mount ---------------------------------

echo ""
echo "Step 9: Consume Secret as Volume Mount"

envsubst < "$LAB_DIR/pod-secret-volume.yaml" | kubectl apply -f - &>/dev/null
wait_for_pod "$NS" secret-vol-demo 60

SV_USER=$(kubectl exec secret-vol-demo -n "$NS" -- cat /etc/db-creds/DB_USERNAME 2>/dev/null)
assert_eq "secret volume mount DB_USERNAME=app_user" "app_user" "$SV_USER"

SV_MODE=$(kubectl get pod secret-vol-demo -n "$NS" \
  -o jsonpath='{.spec.volumes[?(@.name=="db-creds")].secret.defaultMode}' 2>/dev/null)
assert_eq "secret volume defaultMode is 0400 (256)" "256" "$SV_MODE"

# --- Step 10: Immutable ConfigMap ---------------------------------------------

echo ""
echo "Step 10: Immutable ConfigMap"

envsubst < "$LAB_DIR/immutable-config.yaml" | kubectl apply -f - &>/dev/null

IMM=$(kubectl get configmap immutable-app-config -n "$NS" -o jsonpath='{.immutable}' 2>/dev/null)
assert_eq "immutable-app-config immutable=true" "true" "$IMM"

IMM_VER=$(kubectl get configmap immutable-app-config -n "$NS" -o jsonpath='{.data.APP_VERSION}' 2>/dev/null)
assert_eq "immutable-app-config APP_VERSION=2.1.0" "2.1.0" "$IMM_VER"

# --- Step 11: Projected Volume ------------------------------------------------

echo ""
echo "Step 11: Projected Volume"

envsubst < "$LAB_DIR/pod-projected.yaml" | kubectl apply -f - &>/dev/null
wait_for_pod "$NS" projected-demo 60

PROJ_ENV=$(kubectl exec projected-demo -n "$NS" -- cat /etc/projected/APP_ENV 2>/dev/null)
assert_eq "projected volume has APP_ENV" "production" "$PROJ_ENV"

PROJ_USER=$(kubectl exec projected-demo -n "$NS" -- cat /etc/projected/DB_USERNAME 2>/dev/null)
assert_eq "projected volume has DB_USERNAME" "app_user" "$PROJ_USER"

PROJ_NS=$(kubectl exec projected-demo -n "$NS" -- cat /etc/projected/namespace 2>/dev/null)
assert_eq "projected volume has namespace" "$NS" "$PROJ_NS"

# --- Step 12: Vault / ESO note ------------------------------------------------

echo ""
echo "Step 12: Vault / External Secrets (informational)"

VAULT_PODS=$(kubectl get pods -n vault --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$VAULT_PODS" -gt 0 ] 2>/dev/null; then
  skip "Vault integration verified — ESO covered in platform setup"
else
  skip "Vault not available (platform component) — skipping ESO check"
fi

# --- Cleanup ------------------------------------------------------------------

cleanup_ns "$NS"
summary
