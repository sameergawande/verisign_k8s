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

Set your student identifier (use your first name or assigned number):

```bash
# Set your unique student name
export STUDENT_NAME=<your-name>
echo "Student: $STUDENT_NAME"
```

> ⚠️ **Important:** This shared cluster is used by all 22 students. Your `$STUDENT_NAME` ensures your resources don't conflict with others.

---

## Step 1: Explore Existing ClusterRoles

First, create a namespace for this lab and examine the built-in ClusterRoles:

```bash
# Create a namespace for this lab
kubectl create namespace lab07-$STUDENT_NAME

# List all ClusterRoles (there are many built-in ones)
kubectl get clusterroles | head -20

# Count the total number of ClusterRoles
kubectl get clusterroles --no-headers | wc -l
```

Examine the three key built-in ClusterRoles:

```bash
# The 'admin' ClusterRole - full access within a namespace
kubectl describe clusterrole admin

# The 'edit' ClusterRole - read/write but no role management
kubectl describe clusterrole edit

# The 'view' ClusterRole - read-only access
kubectl describe clusterrole view
```

> ✅ **Expected Output:** You should see dozens of ClusterRoles. The `admin` role grants full namespace access, `edit` allows modifications but not role changes, and `view` is strictly read-only.

> 💡 **Key Point:** Kubernetes ships with several default ClusterRoles. The `admin`, `edit`, and `view` roles are designed to be bound at the namespace level using RoleBindings, even though they are cluster-scoped definitions.

---

## Step 2: Create a Namespace-Scoped Role

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

Apply and verify:

```bash
# Apply the Role
kubectl apply -f pod-reader-role.yaml

# Verify the Role was created
kubectl get roles -n lab07-$STUDENT_NAME

# Examine the Role details
kubectl describe role pod-reader -n lab07-$STUDENT_NAME
```

> 💡 **Key Point:** Roles use an additive model -- there are no "deny" rules. If a permission is not explicitly granted, it is denied by default. The `apiGroups: [""]` refers to the core API group.

---

## Step 3: Create a ServiceAccount and RoleBinding

Create a ServiceAccount and bind the pod-reader Role to it:

```bash
kubectl create serviceaccount pod-viewer -n lab07-$STUDENT_NAME
kubectl get serviceaccounts -n lab07-$STUDENT_NAME
```

Now create the RoleBinding:

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
kubectl describe rolebinding read-pods -n lab07-$STUDENT_NAME
```

> ✅ **Expected Output:** The RoleBinding `read-pods` should show the `pod-viewer` ServiceAccount as a subject and `pod-reader` as the referenced Role.

---

## Step 4: Test Permissions with kubectl auth can-i

Use the `--as` flag to impersonate the ServiceAccount and test permissions:

```bash
# Test: Can the pod-viewer list pods in lab07-$STUDENT_NAME? (should be YES)
kubectl auth can-i list pods -n lab07-$STUDENT_NAME \
  --as=system:serviceaccount:lab07-$STUDENT_NAME:pod-viewer

# Test: Can the pod-viewer get pods in lab07-$STUDENT_NAME? (should be YES)
kubectl auth can-i get pods -n lab07-$STUDENT_NAME \
  --as=system:serviceaccount:lab07-$STUDENT_NAME:pod-viewer

# Test: Can the pod-viewer delete pods? (should be NO)
kubectl auth can-i delete pods -n lab07-$STUDENT_NAME \
  --as=system:serviceaccount:lab07-$STUDENT_NAME:pod-viewer

# Test: Can the pod-viewer create deployments? (should be NO)
kubectl auth can-i create deployments -n lab07-$STUDENT_NAME \
  --as=system:serviceaccount:lab07-$STUDENT_NAME:pod-viewer
```

List all allowed actions in the namespace:

```bash
# List all allowed actions in the namespace
kubectl auth can-i --list -n lab07-$STUDENT_NAME \
  --as=system:serviceaccount:lab07-$STUDENT_NAME:pod-viewer
```

> ✅ **Expected Output:** list pods: `yes`, get pods: `yes`, delete pods: `no`, create deployments: `no`. Always test RBAC changes with `kubectl auth can-i` before relying on them.

> 📝 **Note:** The `--as` flag allows impersonation of any user or ServiceAccount. The `--list` flag is useful for auditing what a ServiceAccount can actually do. Impersonation requires cluster-admin privileges, which you have by default.

---

## Step 5: Deploy a Pod Using the ServiceAccount

Create a pod that uses the `pod-viewer` ServiceAccount, then test permissions from inside:

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

# This should SUCCEED - list pods
kubectl exec rbac-test -n lab07-$STUDENT_NAME -- kubectl get pods -n lab07-$STUDENT_NAME
# This should FAIL - try to create a deployment
kubectl exec rbac-test -n lab07-$STUDENT_NAME -- kubectl create deployment \
  test --image=nginx -n lab07-$STUDENT_NAME
```

> ✅ **Expected Output:** The `get pods` command succeeds and shows the running pods. The `create deployment` command fails with a Forbidden error, confirming RBAC enforcement.

> 💡 **Key Point:** The pod's ServiceAccount token is automatically mounted and used by kubectl inside the container. RBAC is enforced at the API server level, not at the client.

---

## Step 6: Create a ClusterRole for Cross-Namespace Access

Create a ClusterRole that grants read access to pods and deployments across all namespaces:

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
# Apply the ClusterRole
kubectl apply -f cluster-reader-role.yaml

# Create a new ServiceAccount for cluster-wide access
kubectl create serviceaccount cluster-viewer -n lab07-$STUDENT_NAME

# Verify the ClusterRole
kubectl describe clusterrole cluster-pod-reader-$STUDENT_NAME
```

> 💡 **Key Point:** A ClusterRole is a cluster-scoped resource (no namespace in its metadata). It can be bound with a `ClusterRoleBinding` for cluster-wide access or a `RoleBinding` for access within a single namespace.

---

## Step 7: Test ClusterRoleBinding

Create a ClusterRoleBinding to grant cluster-wide read access:

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
# Apply the ClusterRoleBinding
kubectl apply -f cluster-reader-binding.yaml

# Test: Can cluster-viewer list pods in kube-system? (should be YES)
kubectl auth can-i list pods -n kube-system \
  --as=system:serviceaccount:lab07-$STUDENT_NAME:cluster-viewer

# Test: Can cluster-viewer list pods in default? (should be YES)
kubectl auth can-i list pods -n default \
  --as=system:serviceaccount:lab07-$STUDENT_NAME:cluster-viewer

# Test: Can cluster-viewer delete pods? (should be NO)
kubectl auth can-i delete pods -n kube-system \
  --as=system:serviceaccount:lab07-$STUDENT_NAME:cluster-viewer
```

> ✅ **Expected Output:** The `cluster-viewer` can list pods in any namespace (`yes`, `yes`) but cannot delete pods anywhere (`no`). This confirms cluster-wide read-only access.

> ⚠️ **Production Warning:** ClusterRoleBindings grant access across all namespaces, including system namespaces like `kube-system`. Use them sparingly and prefer namespace-scoped RoleBindings when possible.

---

## Step 8: Apply Pod Security Standards

Create a new namespace with the **restricted** Pod Security Standard:

```bash
# Create a namespace with Pod Security Standards labels
kubectl create namespace lab07-restricted-$STUDENT_NAME

# Apply the restricted profile (enforce mode)
kubectl label namespace lab07-restricted-$STUDENT_NAME \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=latest
```

Verify the labels:

```bash
# Verify the labels
kubectl get namespace lab07-restricted-$STUDENT_NAME --show-labels

# View the labels in YAML format
kubectl get namespace lab07-restricted-$STUDENT_NAME -o yaml
```

> ✅ **Expected Output:** The namespace should have all six `pod-security.kubernetes.io` labels set to `restricted`. Three modes are active: enforce (blocks violations), warn (shows warnings), and audit (logs violations).

> 📝 **Pod Security Standard Profiles:**
> - **Privileged:** Unrestricted (no enforcement)
> - **Baseline:** Prevents known privilege escalations
> - **Restricted:** Hardened, follows pod security best practices

---

## Step 9: Test Pod Security -- Violations

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

> ✅ **Expected Error:** Both pods are blocked. The restricted profile requires `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, and dropping all capabilities. Walk through the error messages to understand which checks failed.

---

## Step 10: Configure SecurityContext on a Pod

Create a pod that complies with the restricted security profile:

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
# Deploy the secure pod (should SUCCEED)
kubectl apply -f secure-pod.yaml

# Verify it is running
kubectl get pod secure-app -n lab07-restricted-$STUDENT_NAME

# Examine the security settings
kubectl get pod secure-app -n lab07-restricted-$STUDENT_NAME -o jsonpath='{.spec.securityContext}'
kubectl get pod secure-app -n lab07-restricted-$STUDENT_NAME -o jsonpath='{.spec.containers[0].securityContext}'
```

> ✅ **Expected Output:** The `secure-app` pod should be Running. It passes the restricted profile because it: runs as non-root, drops all capabilities, disallows privilege escalation, uses a read-only root filesystem, and has a RuntimeDefault seccomp profile.

### Verify Security Settings Inside the Pod

Confirm the security restrictions from inside the container:

```bash
# Check who the process is running as
kubectl exec secure-app -n lab07-restricted-$STUDENT_NAME -- id

# Try to write to the root filesystem (should FAIL)
kubectl exec secure-app -n lab07-restricted-$STUDENT_NAME -- \
  touch /test-file

# Writing to /tmp should work (emptyDir mount)
kubectl exec secure-app -n lab07-restricted-$STUDENT_NAME -- \
  touch /tmp/test-file

# Verify no extra capabilities
kubectl exec secure-app -n lab07-restricted-$STUDENT_NAME -- \
  cat /proc/1/status | grep -i cap
```

> ✅ **Expected Output:**
> - `id` --> `uid=1000 gid=1000 groups=1000`
> - `touch /test-file` --> **Read-only file system** error
> - `touch /tmp/test-file` --> succeeds (no output)
> - `CapEff` --> `0000000000000000` (no capabilities)

> 💡 **Key Point:** The combination of `runAsNonRoot`, `readOnlyRootFilesystem`, and dropping all capabilities creates a defense-in-depth posture. Even if an attacker compromises the application, they cannot escalate privileges, modify the container filesystem, or leverage Linux capabilities.

---

## Part 3: IRSA -- IAM Roles for Service Accounts

---

## Step 11: Create an IRSA-Annotated ServiceAccount

Retrieve the IAM role ARN and create a ServiceAccount linked to it:

```bash
# Capture the OIDC issuer and account ID
OIDC_ISSUER=$(aws eks describe-cluster --name platform-lab \
  --query "cluster.identity.oidc.issuer" --output text | sed 's|https://||')
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

# Build the IRSA role ARN (pre-created by the platform team)
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/irsa-s3-reader-$STUDENT_NAME"
echo "Role ARN: $ROLE_ARN"
```

```bash
# Create a namespace for the IRSA exercise
kubectl create namespace lab07-irsa-$STUDENT_NAME

# Create the annotated ServiceAccount
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: s3-reader-$STUDENT_NAME
  namespace: lab07-irsa-$STUDENT_NAME
  annotations:
    eks.amazonaws.com/role-arn: "${ROLE_ARN}"
EOF

# Verify the annotation is present
kubectl get sa s3-reader-$STUDENT_NAME -n lab07-irsa-$STUDENT_NAME -o yaml
```

> 📝 **How IRSA Works:** The `eks.amazonaws.com/role-arn` annotation tells the EKS mutating webhook to inject a projected service-account token and two environment variables (`AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`) into every pod that uses this ServiceAccount.

---

## Step 12: Deploy an IRSA Test Pod

Create a pod that uses the IRSA-annotated ServiceAccount:

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
# Apply and wait for the pod
kubectl apply -f irsa-test-pod.yaml
kubectl wait --for=condition=Ready \
  pod/irsa-test-$STUDENT_NAME -n lab07-irsa-$STUDENT_NAME --timeout=60s

# Confirm it is running
kubectl get pod irsa-test-$STUDENT_NAME -n lab07-irsa-$STUDENT_NAME
```

### Test S3 Access from the Pod

Verify the pod can read from the S3 bucket using its IRSA credentials:

```bash
# List the S3 bucket contents
kubectl exec irsa-test-$STUDENT_NAME -n lab07-irsa-$STUDENT_NAME \
  -- aws s3 ls s3://platform-lab-irsa-demo/

# Read a specific object
kubectl exec irsa-test-$STUDENT_NAME -n lab07-irsa-$STUDENT_NAME \
  -- aws s3 cp s3://platform-lab-irsa-demo/test-file.txt -
```

```bash
# Confirm the write is denied (read-only policy)
kubectl exec irsa-test-$STUDENT_NAME -n lab07-irsa-$STUDENT_NAME \
  -- bash -c 'echo "test" | aws s3 cp - \
    s3://platform-lab-irsa-demo/unauthorized-$STUDENT_NAME.txt'
# Expected: AccessDenied — the policy only allows read
```

> ✅ **Expected:** `s3 ls` and `s3 cp` (read) succeed. The write attempt returns **AccessDenied**. This confirms least-privilege enforcement through IRSA.

---

## Step 13: Inspect the IRSA Credential Chain

Examine the injected environment variables and token:

```bash
# Check the injected AWS environment variables
kubectl exec irsa-test-$STUDENT_NAME -n lab07-irsa-$STUDENT_NAME \
  -- env | grep AWS
# Expected:
#   AWS_ROLE_ARN=arn:aws:iam::ACCOUNT:role/irsa-s3-reader-$STUDENT_NAME
#   AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token

# Verify the assumed-role identity
kubectl exec irsa-test-$STUDENT_NAME -n lab07-irsa-$STUDENT_NAME \
  -- aws sts get-caller-identity
# Expected: Arn contains "assumed-role/irsa-s3-reader-$STUDENT_NAME"
```

```bash
# Peek at the projected token (a JWT issued by the OIDC provider)
kubectl exec irsa-test-$STUDENT_NAME -n lab07-irsa-$STUDENT_NAME \
  -- cat /var/run/secrets/eks.amazonaws.com/serviceaccount/token
# The token contains claims: iss (OIDC URL), sub (SA identity), aud (sts.amazonaws.com)
```

> 💡 **Key Point:** The credentials are *temporary* and automatically rotated. The pod never holds long-lived AWS keys. STS exchanges the projected JWT for short-lived credentials, and the SDK refreshes them transparently.

> ⚠️ **Troubleshooting:** If `aws sts get-caller-identity` shows the EC2 instance role instead of the IRSA role, then IRSA is not working. The SDK is falling back to the instance metadata service. Verify the `eks.amazonaws.com/role-arn` annotation is correct and the OIDC provider is configured.

---

## Step 14: Clean Up Resources

Remove all resources created during this lab:

```bash
# Delete cluster-scoped resources first
kubectl delete clusterrolebinding cluster-pod-reader-binding-$STUDENT_NAME
kubectl delete clusterrole cluster-pod-reader-$STUDENT_NAME

# Delete all lab namespaces (cascades to all resources within)
kubectl delete namespace lab07-$STUDENT_NAME
kubectl delete namespace lab07-restricted-$STUDENT_NAME
kubectl delete namespace lab07-irsa-$STUDENT_NAME

# Verify cleanup
kubectl get clusterrole cluster-pod-reader-$STUDENT_NAME 2>/dev/null \
  || echo "ClusterRole deleted"
kubectl get namespace lab07-$STUDENT_NAME 2>/dev/null \
  || echo "Namespace lab07-$STUDENT_NAME deleted"
kubectl get namespace lab07-restricted-$STUDENT_NAME 2>/dev/null \
  || echo "Namespace lab07-restricted-$STUDENT_NAME deleted"
kubectl get namespace lab07-irsa-$STUDENT_NAME 2>/dev/null \
  || echo "Namespace lab07-irsa-$STUDENT_NAME deleted"
```

> ✅ **Expected:** All verification commands should show the "deleted" messages. Deleting a namespace removes Roles, RoleBindings, ServiceAccounts, and Pods within it. ClusterRoles and ClusterRoleBindings are cluster-scoped and must be deleted separately.

---

## Summary -- Command Reference

| Command | Purpose |
|---------|---------|
| `kubectl get roles -n <ns>` | List namespace-scoped Roles |
| `kubectl get clusterroles` | List cluster-scoped Roles |
| `kubectl auth can-i <verb> <resource>` | Test current user permissions |
| `kubectl auth can-i --as=<sa>` | Test another identity's permissions |
| `kubectl create sa <name>` | Create a ServiceAccount |
| `kubectl label ns <ns> pod-security...` | Apply Pod Security Standards |
| `kubectl annotate sa <name> eks...role-arn=<ARN>` | Link a ServiceAccount to an IAM role (IRSA) |
| `aws sts get-caller-identity` | Verify assumed IAM identity inside a pod |

---

## Key Takeaways

- RBAC uses an additive model -- permissions are granted, never denied
- Roles are namespace-scoped; ClusterRoles are cluster-scoped
- RoleBindings and ClusterRoleBindings connect Roles to subjects
- `kubectl auth can-i` is essential for testing and auditing permissions
- Pod Security Standards (restricted, baseline, privileged) replace PodSecurityPolicies
- SecurityContext settings provide defense-in-depth at the container level
- IRSA provides pod-level IAM identities via projected service-account tokens
- Always verify IRSA with `aws sts get-caller-identity` from inside the pod

---

**Lab 7 Complete -- RBAC, Security, and IRSA**

Up Next: Lab 8 -- Network Policies
