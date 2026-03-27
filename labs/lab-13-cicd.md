# Lab 13: CI/CD and GitOps with FluxCD
### Building, Pushing, and Deploying with GitOps Pipelines
**Intermediate Kubernetes — Module 13 of 13**

---

## Lab Overview

### Objectives

- Understand CI/CD pipeline structure for Kubernetes
- Build, tag, and push container images to ECR
- Deploy using kubectl and GitOps tools

### Prerequisites

- kubectl, Docker, and AWS CLI configured
- Access to a Kubernetes cluster (EKS)
- ArgoCD CLI (optional)
- Completed Labs 1-12

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

## Step 1: Explore the CI/CD Pipeline Structure

### Sample GitHub Actions Workflow

Examine a typical CI/CD pipeline for Kubernetes:

```yaml
name: Build and Deploy
on: { push: { branches: [main] } }
env:
  ECR_REGISTRY: ${{ secrets.AWS_ACCOUNT_ID }}.dkr.ecr.us-east-1.amazonaws.com
  ECR_REPOSITORY: my-app
jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
    - name: Configure AWS credentials
      uses: aws-actions/configure-aws-credentials@v4
      with: { aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }},
        aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }},
        aws-region: us-east-1 }
    - name: Build and push image
      run: |
        IMAGE_TAG=$(git rev-parse --short HEAD)
        docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG .
```

### Pipeline Stages

A Kubernetes CI/CD pipeline typically has these stages:

**Build & Push (CI):**
- Run tests
- Build container image
- Tag with git SHA
- Scan for vulnerabilities
- Push image to ECR
- Sign image (optional)

**Deploy (CD):**
- Update manifest or Helm values
- Apply via kubectl or GitOps
- Verify rollout status
- Run smoke tests
- Monitor metrics and alerts
- Rollback on failure

---

## Step 2: Build and Tag a Container Image

### Create a Sample Application

Set up a simple application to build and deploy:

```bash
mkdir -p ~/cicd-lab && cd ~/cicd-lab && git init

cat <<'EOF' > index.html
<html><body>
  <h1>CI/CD Demo Application</h1>
  <p>Build: __BUILD_SHA__</p>
  <p>Deployed: __DEPLOY_TIME__</p>
</body></html>
EOF

cat <<'EOF' > Dockerfile
FROM nginx:1.25-alpine
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 80
EOF

git add . && git commit -m "Initial application"
```

### Build and Tag with Git SHA

Build the image and tag it with the current git commit SHA:

```bash
GIT_SHA=$(git rev-parse --short HEAD)
echo "Building with SHA: $GIT_SHA"

sed -i.bak "s/__BUILD_SHA__/$GIT_SHA/g" index.html
sed -i.bak "s/__DEPLOY_TIME__/$(date -u +%Y-%m-%dT%H:%M:%SZ)/g" index.html

docker build -t my-app:$GIT_SHA .
docker build -t my-app:latest .

docker images my-app

mv index.html.bak index.html
```

> ✅ **Expected Output:** Two tagged images: `my-app:<sha>` and `my-app:latest`. The SHA tag provides immutable, traceable references.

> 💡 **Best Practice:** Never rely solely on `:latest` for production deployments. Always use a specific, immutable tag like the git SHA. It creates a direct link between the running container and the exact source code.

---

## Step 3: Push to Container Registry (ECR)

### Authenticate and Push to ECR

Login to ECR and push the built image:

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query \
  Account --output text)
export ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"
export ECR_REPO="cicd-lab-app-$STUDENT_NAME"

aws ecr create-repository --repository-name $ECR_REPO \
  --region us-east-1 || echo "Repository already exists"

aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin $ECR_REGISTRY

docker tag my-app:$GIT_SHA $ECR_REGISTRY/$ECR_REPO:$GIT_SHA
docker push $ECR_REGISTRY/$ECR_REPO:$GIT_SHA

aws ecr describe-images --repository-name $ECR_REPO --region us-east-1
```

> ✅ **Expected Output:** The image should appear in the ECR repository with the git SHA as the image tag. The `describe-images` output shows the image digest and tags.

> ⚠️ **Troubleshooting:** If authentication fails, verify your AWS credentials: `aws sts get-caller-identity`. Ensure your IAM role has `ecr:GetAuthorizationToken` and `ecr:BatchCheckLayerAvailability` permissions.

> 📝 **Note:** ECR login tokens expire after 12 hours. In CI/CD pipelines, the login step runs every time. For local development, you may need to re-authenticate periodically.

---

## Step 4: Create a Deployment Manifest

Write a Kubernetes Deployment manifest referencing the ECR image:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cicd-demo
  namespace: cicd-lab-$STUDENT_NAME
  annotations: { git-commit: "${GIT_SHA}" }
spec:
  replicas: 3
  selector:
    matchLabels: { app: cicd-demo }
  template:
    metadata:
      labels: { app: cicd-demo }
    spec:
      containers:
      - name: app
        image: ${ECR_REGISTRY}/${ECR_REPO}:${GIT_SHA}
        ports: [{containerPort: 80}]
---
```

> 💡 **Key Concept:** The `git-commit` annotation embeds the source commit reference directly in the Kubernetes resource, making it easy to trace back from a running deployment to the exact code version.

---

## Step 5: Deploy Using kubectl apply

Substitute variables and apply the manifest:

```bash
kubectl create namespace cicd-lab-$STUDENT_NAME

mkdir -p ~/cicd-lab/k8s

envsubst < k8s/deployment.yaml | kubectl apply -f -

kubectl rollout status deployment/cicd-demo -n cicd-lab-$STUDENT_NAME

kubectl get pods -n cicd-lab-$STUDENT_NAME -l app=cicd-demo
kubectl get svc -n cicd-lab-$STUDENT_NAME

kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never \
  -n cicd-lab-$STUDENT_NAME -- curl -s cicd-demo-svc
```

> ✅ **Expected Output:** 3 pods running with the ECR image. The curl test should return the HTML page showing the build SHA.

> 💡 **Why Not kubectl in Production?** Imperative deployments lack auditability, drift detection, and automated reconciliation. GitOps tools address all of these concerns.

> 📝 **Note:** If `envsubst` is not available, you can manually replace the variables in the YAML. This step demonstrates the simplest deployment method before introducing GitOps patterns.

---

## Step 6: Set Up ArgoCD Application

### Verify ArgoCD Installation

Check if ArgoCD is available in the cluster:

```bash
# ArgoCD is pre-installed by the instructor
kubectl get pods -n argocd

# Check the ArgoCD CLI
argocd version
```

> ⚠️ **Important:** ArgoCD has been pre-installed on the cluster. Do not reinstall or delete the `argocd` namespace.

### Create an ArgoCD Application

Define an ArgoCD Application CRD:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: cicd-demo-$STUDENT_NAME, namespace: argocd }
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/cicd-demo.git
    targetRevision: main
    path: k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: cicd-lab-$STUDENT_NAME
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

> 💡 **Key ArgoCD Concepts:**
> - **Source** -- the git repository and path containing manifests
> - **Destination** -- the target cluster and namespace
> - **Sync Policy** -- `automated` means ArgoCD syncs on git changes; `prune` removes deleted resources; `selfHeal` reverts manual drift
>
> The automated sync policy is what makes this GitOps. Any change pushed to the `main` branch in the specified path will automatically be applied to the cluster.

---

## Step 7: Observe ArgoCD Sync

Use the ArgoCD CLI and UI to observe the sync:

```bash
kubectl apply -f argocd-app.yaml

argocd app get cicd-demo-$STUDENT_NAME

argocd app sync cicd-demo-$STUDENT_NAME

argocd app wait cicd-demo-$STUDENT_NAME --health

kubectl get svc argocd-server -n argocd
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

> ✅ **Expected Output:** The application status should show `Health: Healthy` and `Sync: Synced`. All resources should show a green checkmark in the UI.

> 📝 **Note:** If using the web UI, port-forward the ArgoCD server: `kubectl port-forward svc/argocd-server -n argocd 8080:443`. The UI provides a visual dependency graph of all resources in the application.

---

## Step 8: Trigger Pipeline with Code Change

### Simulate a Pipeline Trigger

Make a code change, rebuild, and update the manifest:

```bash
cd ~/cicd-lab
sed -i 's/CI\/CD Demo Application/CI\/CD Demo v2/' index.html
git add . && git commit -m "Update application to v2"

NEW_SHA=$(git rev-parse --short HEAD)
echo "New SHA: $NEW_SHA"
docker build -t my-app:$NEW_SHA .

sed -i "s|image: .*|image: \
${ECR_REGISTRY}/${ECR_REPO}:${NEW_SHA}|" \
  k8s/deployment.yaml
sed -i "s|git-commit: .*|git-commit: \"${NEW_SHA}\"|" k8s/deployment.yaml

git add k8s/deployment.yaml
git commit -m "Deploy image $NEW_SHA"
```

> 📝 **Note:** In a real pipeline, the CI system would build the image and a separate step or tool would update the manifest. Some teams use image updater tools that automatically detect new images in the registry.

### Apply and Verify the Update

Apply the updated manifest and observe the rollout:

```bash
docker tag my-app:$NEW_SHA $ECR_REGISTRY/$ECR_REPO:$NEW_SHA
docker push $ECR_REGISTRY/$ECR_REPO:$NEW_SHA

envsubst < k8s/deployment.yaml | kubectl apply -f -

kubectl rollout status deployment/cicd-demo -n cicd-lab-$STUDENT_NAME


kubectl run curl-test2 --image=curlimages/curl --rm -it --restart=Never \
  -n cicd-lab-$STUDENT_NAME -- curl -s cicd-demo-svc
```

> ✅ **Expected Output:** The curl response should show "CI/CD Demo v2" with the new build SHA. The deployment annotation should show the new git commit.

> 💡 **Key Concept:** With ArgoCD automated sync, pushing the manifest change to git would trigger the deployment automatically. Without ArgoCD, we use `kubectl apply` manually. The key point is that the manifest in git is the source of truth.

---

## Step 9: Rollback via ArgoCD

### Rollback Strategies

**Git Revert (Preferred):**

```bash
# Revert the last commit
git revert HEAD --no-edit

# Push to trigger ArgoCD sync
git push origin main
```

Maintains full audit trail in git history. ArgoCD detects the change and syncs automatically.

**ArgoCD Rollback (Quick):**

```bash
# View sync history
argocd app history cicd-demo-$STUDENT_NAME

# Rollback to previous version
argocd app rollback cicd-demo-$STUDENT_NAME 1
```

Faster but creates drift between git and cluster. ArgoCD will eventually re-sync from git.

> ⚠️ **Important:** ArgoCD rollback creates temporary drift between the cluster and git. If automated sync is enabled, ArgoCD will re-sync from git within the poll interval (default 3 minutes). Use `git revert` for a permanent rollback.

> 💡 **Key Concept:** The git revert approach is the true GitOps way. It maintains the audit trail and ensures git remains the source of truth. ArgoCD rollback is useful for emergency situations where speed is critical.

---

## Step 10: Explore FluxCD Reconciliation

If FluxCD is available, explore its reconciliation model:

```bash
# Check if Flux is installed
flux check

# View git sources
flux get sources git

# View kustomizations
flux get kustomizations

# Trigger a manual reconciliation
flux reconcile kustomization flux-system --with-source
```

### FluxCD CRDs

- `GitRepository` -- watches a git repo
- `Kustomization` -- reconciles manifests from source
- `HelmRelease` -- manages Helm releases
- `HelmRepository` -- watches a chart repo

### ArgoCD vs FluxCD

- ArgoCD: web UI, app-of-apps pattern
- FluxCD: CLI-first, Kubernetes-native CRDs
- Both: GitOps, pull-based, reconciliation
- Choose based on team preferences

> 📝 **Note:** Flux is CNCF graduated and deeply integrated with Kubernetes. It uses the same reconciliation pattern as Kubernetes controllers. ArgoCD provides a richer UI experience. Both are excellent choices for GitOps.

---

## Step 11: Explore Flux Resources in the Cluster

> ⚠️ **Important:** Flux is pre-installed on the cluster. Do not run `flux bootstrap` or `flux uninstall`.

Confirm FluxCD is healthy and explore existing resources:

```bash
# Check Flux installation health
flux check

# View Flux controller pods
kubectl get pods -n flux-system

# List Flux CRDs installed in the cluster
kubectl get crds | grep flux
```

```bash
# List all Git sources and Helm repository sources
flux get sources git
flux get sources helm

# List existing Kustomizations managed by Flux
flux get kustomizations

# Get detailed YAML for Git sources
kubectl get gitrepository -n flux-system -o yaml
```

> ✅ **Observe:** Note the `REVISION` column showing the current Git commit SHA, the `READY` status, and the `spec.interval` controlling how often Flux checks for changes.

> ✅ **Expected:** All four Flux controllers (source, kustomize, helm, notification) should show Ready. You should see CRDs including `gitrepositories`, `kustomizations`, `helmreleases`.

---

## Step 12: Create a FluxCD HelmRelease

### Part 1 -- Create the HelmRepository Source

Create your namespace and a HelmRepository source:

```bash
# Create your student namespace for Flux resources
kubectl create namespace flux-lab-$STUDENT_NAME
```

```yaml
# Save as helm-source.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: bitnami-$STUDENT_NAME
  namespace: flux-system
spec:
  interval: 30m
  url: https://charts.bitnami.com/bitnami
```

```bash
# Apply the Helm source
kubectl apply -f helm-source.yaml

# Verify it becomes Ready
flux get sources helm bitnami-$STUDENT_NAME
```

> 💡 **Key Concept:** The HelmRepository source is similar to running `helm repo add`. It tells Flux where to find Helm charts. The interval for Helm repos can be longer since chart indexes are updated less frequently.

### Part 2 -- Create the HelmRelease

Create a HelmRelease to deploy nginx using the Bitnami chart:

```yaml
# Save as helm-release.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: lab-nginx-$STUDENT_NAME
  namespace: flux-lab-$STUDENT_NAME
spec:
  interval: 15m
  chart:
    spec:
      chart: nginx
      version: ">=15.0.0 <16.0.0"
      sourceRef:
        kind: HelmRepository
        name: bitnami-$STUDENT_NAME
        namespace: flux-system
  values:
    replicaCount: 2
    service: { type: ClusterIP }
  install:
    remediation: { retries: 3 }
  upgrade:
    remediation: { retries: 3, remediationStrategy: rollback }
```

> 📝 **Note:** The chart version uses a semver range -- Flux auto-selects the latest patch within 15.x. The remediation section ensures retries and rollback on failure.

### Part 3 -- Verify the HelmRelease

```bash
# Apply the HelmRelease
kubectl apply -f helm-release.yaml

# Watch the release become Ready
flux get helmreleases -n flux-lab-$STUDENT_NAME lab-nginx-$STUDENT_NAME --watch

# Confirm it appears in Helm (Flux uses the Helm SDK internally)
helm list -n flux-lab-$STUDENT_NAME

# Check the deployed resources
kubectl get all -n flux-lab-$STUDENT_NAME \
  -l app.kubernetes.io/instance=lab-nginx-$STUDENT_NAME

# View detailed release info
flux get helmreleases -n flux-lab-$STUDENT_NAME lab-nginx-$STUDENT_NAME -o wide
```

> ✅ **Checkpoint:** The HelmRelease shows `Ready: True` and appears in `helm list`. Nginx pods are running in `flux-lab-$STUDENT_NAME` with the configured replica count. Running `helm upgrade` manually would create drift that Flux reverts on the next reconciliation.

---

## Step 13: Observe Reconciliation & Drift Detection

### Force Reconciliation

Trigger a manual reconciliation and observe Flux applying changes:

```bash
# Check current nginx replica count
kubectl get deployment -n flux-lab-$STUDENT_NAME \
  -l app.kubernetes.io/instance=lab-nginx-$STUDENT_NAME

# Force an immediate reconciliation of the HelmRelease
flux reconcile helmrelease lab-nginx-$STUDENT_NAME \
  -n flux-lab-$STUDENT_NAME

# Watch reconciliation events
flux events --for HelmRelease/lab-nginx-$STUDENT_NAME \
  -n flux-lab-$STUDENT_NAME
```

> 📝 **Note:** Even if nothing changed, reconciliation verifies the cluster state matches the desired state. The events show the reconciliation cycle: fetching the chart, running `helm upgrade --install`, and verifying health checks.

### Test Drift Detection

Introduce manual drift and watch Flux correct it:

```bash
# Scale nginx to 5 replicas manually (creating drift)
kubectl scale deployment -n flux-lab-$STUDENT_NAME \
  -l app.kubernetes.io/instance=lab-nginx-$STUDENT_NAME \
  --replicas=5

# Confirm the manual change took effect
kubectl get deployment -n flux-lab-$STUDENT_NAME

# Now force reconciliation -- Flux will revert to 2 replicas
flux reconcile helmrelease lab-nginx-$STUDENT_NAME \
  -n flux-lab-$STUDENT_NAME

# Watch Flux correct the drift
kubectl get deployment -n flux-lab-$STUDENT_NAME --watch
```

> ✅ **Checkpoint:** After manually scaling to 5 replicas and triggering reconciliation, Flux reverted the count to 2 (the value declared in the HelmRelease). This confirms drift detection and correction. In production, this happens automatically at the reconciliation interval.

> 💡 **Key Concept:** What if you need to truly change replicas? Update the HelmRelease values in Git, commit, and push. Git is the single source of truth.

---

## Step 14: Clean Up

Remove all CI/CD resources:

```bash
# ArgoCD resources
kubectl delete application cicd-demo-$STUDENT_NAME -n argocd --ignore-not-found

# CI/CD namespace and ECR
kubectl delete namespace cicd-lab-$STUDENT_NAME
aws ecr delete-repository --repository-name cicd-lab-app-$STUDENT_NAME \
  --region us-east-1 --force || echo "Skipping ECR cleanup"
rm -rf ~/cicd-lab
docker rmi $(docker images my-app -q) 2>/dev/null || true
```

Remove all FluxCD resources:

```bash
# Delete the HelmRelease (triggers helm uninstall automatically)
kubectl delete helmrelease lab-nginx-$STUDENT_NAME \
  -n flux-lab-$STUDENT_NAME --ignore-not-found

# Delete the HelmRepository source
kubectl delete helmrepository bitnami-$STUDENT_NAME \
  -n flux-system --ignore-not-found

# Delete the Flux student namespace
kubectl delete namespace flux-lab-$STUDENT_NAME

# Verify cleanup
kubectl get namespace cicd-lab-$STUDENT_NAME 2>/dev/null || echo "cicd namespace gone"
kubectl get namespace flux-lab-$STUDENT_NAME 2>/dev/null || echo "flux namespace gone"
```

> ⚠️ **Do NOT delete the `argocd` or `flux-system` namespaces** -- they are shared by all students. Only delete your own resources and namespaces.

> 📝 **Note:** The order matters: delete HelmReleases before HelmRepositories so Flux can properly uninstall the Helm chart. Deleting the HelmRelease triggers a `helm uninstall` automatically.

---

## Step 15: Summary & Patterns Reference

### CI/CD Patterns Comparison

| Pattern | Push vs Pull | Audit Trail | Drift Detection | Complexity |
|---------|-------------|-------------|-----------------|------------|
| **kubectl apply** | Push | Limited | None | Low |
| **ArgoCD** | Pull | Full (git) | Automatic | Medium |
| **FluxCD** | Pull | Full (git) | Automatic | Medium |
| **Helm + CI** | Push | Release history | Manual | Medium |

> 💡 **Key Takeaway:** GitOps (ArgoCD/FluxCD) provides the strongest guarantees: git as single source of truth, automatic drift detection, and full auditability. Start with kubectl for learning, adopt GitOps for production.

---

## Lab 13 Complete -- Key Takeaways

- **Image Building** -- tag with git SHA for traceability, never rely on `:latest` in production
- **Registry Push** -- authenticate to ECR, push immutable image tags
- **Deployment** -- kubectl apply for learning, GitOps for production
- **ArgoCD** -- Application CRD defines source, destination, and sync policy
- **FluxCD Hands-On** -- HelmRelease CRD for declarative Helm chart lifecycle, reconciliation loop, and automatic drift correction
- **Rollback** -- git revert for permanent rollback, tool-specific commands for emergencies
