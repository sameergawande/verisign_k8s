#!/bin/bash
###############################################################################
# Platform Prerequisites Test
# Verifies tools, cluster access, and platform components
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

echo "=== Platform Prerequisites ==="
echo ""

# ─── Tools ──────────────────────────────────────────────────────────────────

echo "Tools:"
assert_cmd "kubectl installed" kubectl version --client
assert_cmd "helm installed" helm version --short
assert_cmd "flux installed" flux version --client
assert_cmd "argocd installed" argocd version --client
assert_cmd "jq installed" jq --version
assert_cmd "envsubst installed" envsubst --version
assert_cmd "git installed" git --version
assert_cmd "docker installed" docker --version
assert_cmd "aws cli installed" aws --version

# ─── Cluster Access ─────────────────────────────────────────────────────────

echo ""
echo "Cluster Access:"

CLUSTER_INFO=$(kubectl cluster-info 2>&1)
assert_contains "kubectl can reach cluster" "$CLUSTER_INFO" "is running at"

NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$NODES" -gt 0 ]; then
  pass "cluster has $NODES node(s)"
else
  fail "no nodes found"
fi

NODE_STATUS=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | sort -u)
assert_eq "all nodes Ready" "Ready" "$NODE_STATUS"

# ─── Helper: find running pods by name pattern across namespaces ───────────

# Check if any running pod matches a name pattern in a given namespace
# Falls back to checking all namespaces if namespace check fails
check_component() {
  local desc="$1" pattern="$2" ns="$3" skip_msg="$4"

  # First try the expected namespace
  local count
  count=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -iE "$pattern" | grep -c Running || true)
  if [ "$count" -gt 0 ]; then
    pass "$desc ($count pods in $ns)"
    return 0
  fi

  # Try all namespaces
  count=$(kubectl get pods -A --no-headers 2>/dev/null | grep -iE "$pattern" | grep -c Running || true)
  if [ "$count" -gt 0 ]; then
    local found_ns
    found_ns=$(kubectl get pods -A --no-headers 2>/dev/null | grep -iE "$pattern" | grep Running | head -1 | awk '{print $1}')
    pass "$desc ($count pods in $found_ns)"
    return 0
  fi

  skip "$skip_msg"
  return 1
}

# ─── Platform Components ────────────────────────────────────────────────────

echo ""
echo "Platform Components:"

# Metrics Server
check_component "metrics-server running" "metrics-server" "kube-system" \
  "metrics-server not found (labs 1,2,9 may have limited functionality)"

# Also verify kubectl top works
if kubectl top nodes &>/dev/null 2>&1; then
  pass "kubectl top nodes works"
else
  skip "kubectl top not responding (metrics-server may still be starting)"
fi

# Calico / Cilium / VPC-CNI with NetworkPolicy
if kubectl get installation default &>/dev/null 2>&1; then
  pass "calico installed"
elif kubectl get pods -A --no-headers 2>/dev/null | grep -i cilium | grep -q Running; then
  pass "cilium installed"
elif kubectl get daemonset -n kube-system aws-node &>/dev/null 2>&1; then
  # VPC-CNI is default on EKS — check if network policy agent is present
  if kubectl get pods -A --no-headers 2>/dev/null | grep -iE "network-policy|calico|tigera" | grep -q Running; then
    pass "network policy enforcement available"
  else
    skip "VPC-CNI present but no NetworkPolicy enforcement detected (labs 6,8 may fail)"
  fi
else
  skip "no CNI with NetworkPolicy support detected (labs 6,8 may fail)"
fi

# Ingress NGINX
check_component "ingress-nginx running" "ingress-nginx|nginx-controller" "ingress-nginx" \
  "ingress-nginx not found (lab 6 may fail)"

# Envoy Gateway
check_component "envoy-gateway running" "envoy-gateway|gateway-api" "envoy-gateway-system" \
  "envoy-gateway not found (lab 6 gateway section may fail)"

# Gateway API CRDs
if kubectl get crd gateways.gateway.networking.k8s.io &>/dev/null 2>&1; then
  pass "gateway API CRDs installed"
elif kubectl get crd httproutes.gateway.networking.k8s.io &>/dev/null 2>&1; then
  pass "gateway API CRDs installed (httproutes found)"
else
  skip "gateway API CRDs not found"
fi

# Prometheus stack
check_component "prometheus running" "prometheus" "monitoring" \
  "prometheus not found (lab 9 may fail)"

check_component "grafana running" "grafana" "monitoring" \
  "grafana not found (lab 9 may fail)"

# Kyverno
check_component "kyverno running" "kyverno" "kyverno" \
  "kyverno not found"

# ArgoCD
check_component "argocd running" "argocd" "argocd" \
  "argocd not found (lab 13 may fail)"

# Flux
check_component "flux running" "flux|source-controller|kustomize-controller" "flux-system" \
  "flux not found (lab 13 may fail)"

# Vault
if kubectl get pods -A --no-headers 2>/dev/null | grep -i vault | grep -q Running; then
  VAULT_NS=$(kubectl get pods -A --no-headers 2>/dev/null | grep -i vault | grep Running | head -1 | awk '{print $1}')
  VAULT_POD=$(kubectl get pods -n "$VAULT_NS" --no-headers 2>/dev/null | grep -i vault | grep Running | head -1 | awk '{print $1}')
  pass "vault running ($VAULT_NS/$VAULT_POD)"
  VAULT_STATUS=$(kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- vault status -format=json 2>/dev/null | jq -r '.sealed' 2>/dev/null || echo "unknown")
  assert_eq "vault unsealed" "false" "$VAULT_STATUS"
else
  skip "vault not found (lab 5 may fail)"
fi

# External Secrets Operator
check_component "external-secrets-operator running" "external-secrets|eso" "external-secrets" \
  "external-secrets-operator not found (lab 5 ESO section may fail)"

# ClusterSecretStore
if kubectl get clustersecretstore &>/dev/null 2>&1; then
  CSS_COUNT=$(kubectl get clustersecretstore --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$CSS_COUNT" -gt 0 ]; then
    pass "ClusterSecretStore configured ($CSS_COUNT found)"
  else
    skip "no ClusterSecretStore resources found"
  fi
else
  skip "ClusterSecretStore CRD not installed"
fi

# IRSA demo bucket
BUCKET_CHECK=$(aws s3 ls s3://platform-lab-irsa-demo/ 2>&1)
if echo "$BUCKET_CHECK" | grep -q "test-file.txt"; then
  pass "IRSA demo S3 bucket accessible"
else
  skip "IRSA demo S3 bucket not accessible (lab 7 IRSA section may fail)"
fi

# StorageClasses
SC_COUNT=$(kubectl get storageclasses --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$SC_COUNT" -gt 0 ]; then
  pass "$SC_COUNT StorageClass(es) available"
else
  fail "no StorageClasses found"
fi

# ─── Helm releases summary ─────────────────────────────────────────────────

echo ""
echo "Helm Releases:"
HELM_COUNT=$(helm list -A --short 2>/dev/null | wc -l | tr -d ' ')
if [ "$HELM_COUNT" -gt 0 ]; then
  pass "$HELM_COUNT Helm release(s) deployed"
else
  skip "no Helm releases found"
fi

# Flux HelmReleases
echo ""
echo "Flux HelmReleases:"
FLUX_HR=$(kubectl get helmreleases -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$FLUX_HR" -gt 0 ]; then
  FLUX_HR_READY=$(kubectl get helmreleases -A --no-headers 2>/dev/null | grep -c "True" || true)
  pass "$FLUX_HR_READY/$FLUX_HR Flux HelmReleases ready"
  if [ "$FLUX_HR_READY" -lt "$FLUX_HR" ]; then
    echo "  Not ready:"
    kubectl get helmreleases -A --no-headers 2>/dev/null | grep -v "True" | awk '{printf "    %s/%s\n", $1, $2}'
  fi
else
  skip "no Flux HelmReleases found"
fi

summary
