# Lab 7: RBAC, Security, and IRSA
### Pod Security Standards, SecurityContexts, and IAM Roles for Service Accounts
**Intermediate Kubernetes — Module 7 of 13**

---

## Lab Overview

### Objectives

- Explore existing ClusterRoles and bindings
- Create Roles, RoleBindings, and ServiceAccounts
- Apply Pod Security Standards and SecurityContexts
- Test RBAC permission boundaries
- Annotate ServiceAccounts with IAM roles (IRSA) and verify pod-level AWS access

### Prerequisites

- Completed Labs 1-6
- kubectl with cluster-admin access on a running EKS cluster

> **Duration:** ~45 minutes

---

## Environment Setup

```bash
export STUDENT_NAME=<your-name>
echo "Student: $STUDENT_NAME"
```

---

## Step 1: Explore Existing ClusterRoles

Create a namespace and examine the built-in ClusterRoles:

```bash
kubectl create namespace lab07-$STUDENT_NAME

kubectl get clusterroles | head -20

# Examine key built-in ClusterRoles
kubectl describe clusterrole admin
kubectl describe clusterrole edit
kubectl describe clusterrole view
```

---

## Step 2: Create a Namespace-Scoped Role and Bind It

Create a Role that allows read-only access to pods:

```yaml
# Save as pod-reader-role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: lab07-$STUDENT_NAME
  name: pod-reader
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods/log"]
  verbs: ["get"]
```

Create a ServiceAccount and bind the Role to it:

```bash
kubectl apply -f pod-reader-role.yaml
kubectl create serviceaccount pod-viewer -n lab07-$STUDENT_NAME
```

```yaml
# Save as pod-reader-binding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-pods
  namespace: lab07-$STUDENT_NAME
subjects:
- kind: ServiceAccount
  name: pod-viewer
  namespace: lab07-$STUDENT_NAME
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f pod-reader-binding.yaml
```

---

## Step 3: Test Permissions with kubectl auth can-i

```bash
kubectl auth can-i --list -n lab07-$STUDENT_NAME \
  --as=system:serviceaccount:lab07-$STUDENT_NAME:pod-viewer
```

> ✅ **Checkpoint:** Output shows `get`, `list`, `watch` on `pods` and `get` on `pods/log` -- nothing else.

---

## Step 4: Deploy a Pod Using the ServiceAccount

```yaml
# Save as rbac-test-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: rbac-test
  namespace: lab07-$STUDENT_NAME
spec:
  serviceAccountName: pod-viewer
  containers:
  - name: kubectl
    image: bitnami/kubectl:latest
    command: ["sleep", "3600"]
  restartPolicy: Never
```

```bash
kubectl apply -f rbac-test-pod.yaml
kubectl wait --for=condition=Ready pod/rbac-test -n lab07-$STUDENT_NAME --timeout=60s

# This should SUCCEED
kubectl exec rbac-test -n lab07-$STUDENT_NAME -- kubectl get pods -n lab07-$STUDENT_NAME

# This should FAIL with Forbidden
kubectl exec rbac-test -n lab07-$STUDENT_NAME -- kubectl create deployment \
  test --image=nginx -n lab07-$STUDENT_NAME
```

> ✅ **Checkpoint:** `get pods` succeeds; `create deployment` fails with Forbidden.

---

## Step 5: Create a ClusterRole for Cross-Namespace Access

```yaml
# Save as cluster-reader-role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-pod-reader-$STUDENT_NAME
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log", "services"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets"]
  verbs: ["get", "list", "watch"]
```

```bash
kubectl apply -f cluster-reader-role.yaml
kubectl create serviceaccount cluster-viewer -n lab07-$STUDENT_NAME
```

Bind it with a ClusterRoleBinding:

```yaml
# Save as cluster-reader-binding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cluster-pod-reader-binding-$STUDENT_NAME
subjects:
- kind: ServiceAccount
  name: cluster-viewer
  namespace: lab07-$STUDENT_NAME
roleRef:
  kind: ClusterRole
  name: cluster-pod-reader-$STUDENT_NAME
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f cluster-reader-binding.yaml

# Test cross-namespace read (should be YES)
kubectl auth can-i list pods -n kube-system \
  --as=system:serviceaccount:lab07-$STUDENT_NAME:cluster-viewer

# Test delete (should be NO)
kubectl auth can-i delete pods -n kube-system \
  --as=system:serviceaccount:lab07-$STUDENT_NAME:cluster-viewer
```

> ✅ **Checkpoint:** `list pods` returns `yes` in any namespace; `delete pods` returns `no`.

---

## Step 6: Apply Pod Security Standards

Create a namespace with the **restricted** Pod Security Standard:

```bash
kubectl create namespace lab07-restricted-$STUDENT_NAME

kubectl label namespace lab07-restricted-$STUDENT_NAME \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=latest
```

---

## Step 7: Test Pod Security -- Violations

Try deploying pods that violate the restricted profile:

```yaml
# Save as privileged-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: privileged-test
  namespace: lab07-restricted-$STUDENT_NAME
spec:
  containers:
  - name: nginx
    image: nginx:latest
    securityContext:
      privileged: true
```

```yaml
# Save as root-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: root-test
  namespace: lab07-restricted-$STUDENT_NAME
spec:
  containers:
  - name: nginx
    image: nginx:latest
    securityContext:
      runAsUser: 0
```

```bash
# Both should FAIL under the restricted profile
kubectl apply -f privileged-pod.yaml
kubectl apply -f root-pod.yaml
```

> ✅ **Checkpoint:** Both pods are blocked. Read the error messages to see which checks failed.

---

## Step 8: Deploy a Compliant Secure Pod

```yaml
# Save as secure-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-app
  namespace: lab07-restricted-$STUDENT_NAME
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: busybox:latest
    command: ["sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
    volumeMounts:
    - name: tmp
      mountPath: /tmp
  volumes:
  - name: tmp
    emptyDir: {}
  restartPolicy: Never
```

```bash
kubectl apply -f secure-pod.yaml
kubectl wait --for=condition=Ready pod/secure-app \
  -n lab07-restricted-$STUDENT_NAME --timeout=60s

# Verify security settings inside the pod
kubectl exec secure-app -n lab07-restricted-$STUDENT_NAME -- id
kubectl exec secure-app -n lab07-restricted-$STUDENT_NAME -- touch /test-file
kubectl exec secure-app -n lab07-restricted-$STUDENT_NAME -- touch /tmp/test-file
kubectl exec secure-app -n lab07-restricted-$STUDENT_NAME -- \
  cat /proc/1/status | grep -i cap
```

> ✅ **Checkpoint:**
> - `id` --> `uid=1000 gid=1000 groups=1000`
> - `touch /test-file` --> **Read-only file system** error
> - `touch /tmp/test-file` --> succeeds
> - `CapEff` --> `0000000000000000` (no capabilities)

---

## Part 3: IRSA -- IAM Roles for Service Accounts

---

## Step 9: Create an IRSA-Annotated ServiceAccount

```bash
OIDC_ISSUER=$(aws eks describe-cluster --name platform-lab \
  --query "cluster.identity.oidc.issuer" --output text | sed 's|https://||')
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/irsa-s3-reader-$STUDENT_NAME"
echo "Role ARN: $ROLE_ARN"
```

```bash
kubectl create namespace lab07-irsa-$STUDENT_NAME

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: s3-reader-$STUDENT_NAME
  namespace: lab07-irsa-$STUDENT_NAME
  annotations:
    eks.amazonaws.com/role-arn: "${ROLE_ARN}"
EOF
```

---

## Step 10: Deploy and Test an IRSA Pod

```yaml
# Save as irsa-test-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: irsa-test-$STUDENT_NAME
  namespace: lab07-irsa-$STUDENT_NAME
spec:
  serviceAccountName: s3-reader-$STUDENT_NAME
  containers:
  - name: aws-cli
    image: amazon/aws-cli:latest
    command: ["sleep", "3600"]
  restartPolicy: Never
```

```bash
kubectl apply -f irsa-test-pod.yaml
kubectl wait --for=condition=Ready \
  pod/irsa-test-$STUDENT_NAME -n lab07-irsa-$STUDENT_NAME --timeout=60s

# Test S3 read access
kubectl exec irsa-test-$STUDENT_NAME -n lab07-irsa-$STUDENT_NAME \
  -- aws s3 ls s3://platform-lab-irsa-demo/

kubectl exec irsa-test-$STUDENT_NAME -n lab07-irsa-$STUDENT_NAME \
  -- aws s3 cp s3://platform-lab-irsa-demo/test-file.txt -

# Test S3 write (should be denied)
kubectl exec irsa-test-$STUDENT_NAME -n lab07-irsa-$STUDENT_NAME \
  -- bash -c 'echo "test" | aws s3 cp - \
    s3://platform-lab-irsa-demo/unauthorized-$STUDENT_NAME.txt'
```

> ✅ **Checkpoint:** `s3 ls` and `s3 cp` (read) succeed. Write returns **AccessDenied**.

---

## Step 11: Inspect the IRSA Credential Chain

```bash
kubectl exec irsa-test-$STUDENT_NAME -n lab07-irsa-$STUDENT_NAME \
  -- env | grep AWS

kubectl exec irsa-test-$STUDENT_NAME -n lab07-irsa-$STUDENT_NAME \
  -- aws sts get-caller-identity
```

> ✅ **Checkpoint:** `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE` are injected. The STS identity ARN contains `assumed-role/irsa-s3-reader-$STUDENT_NAME`.

> ⚠️ **Troubleshooting:** If `sts get-caller-identity` shows the EC2 instance role, IRSA is not working. Verify the `eks.amazonaws.com/role-arn` annotation and OIDC provider configuration.

---

## Step 12: Clean Up

```bash
kubectl delete clusterrolebinding cluster-pod-reader-binding-$STUDENT_NAME
kubectl delete clusterrole cluster-pod-reader-$STUDENT_NAME

kubectl delete namespace lab07-$STUDENT_NAME
kubectl delete namespace lab07-restricted-$STUDENT_NAME
kubectl delete namespace lab07-irsa-$STUDENT_NAME
```

---

## Summary

- RBAC uses an additive model -- permissions are granted, never denied
- Roles are namespace-scoped; ClusterRoles are cluster-scoped; bind them with RoleBindings or ClusterRoleBindings
- Pod Security Standards (restricted, baseline, privileged) enforce security profiles at the namespace level
- SecurityContext settings (`runAsNonRoot`, `readOnlyRootFilesystem`, `drop: ALL`) provide defense-in-depth
- IRSA provides pod-level IAM identities via projected service-account tokens -- no long-lived AWS keys needed
