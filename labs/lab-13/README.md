# Lab 13: CI/CD and GitOps with FluxCD
### Building, Pushing, and Deploying with GitOps Pipelines
**Intermediate Kubernetes — Module 13 of 13**

---

## Lab Overview

### Objectives

- Build, tag, and push container images to ECR
- Deploy using kubectl and GitOps tools
- Observe ArgoCD sync and rollback
- *Optional:* Explore FluxCD reconciliation and drift detection

### Prerequisites

- Completion of Lab 1 with `kubectl` and cluster access configured. Helm installed.
- Docker and AWS CLI configured
- Access to a Kubernetes cluster (EKS)
- ArgoCD CLI (optional)

> **Duration:** ~45-55 minutes (core), 70+ with FluxCD
>
> **Note:** Steps 9-11 (FluxCD) are optional stretch goals for students who finish early.

---

## Environment Setup

```bash
export STUDENT_NAME=<your-name>
echo "Student: $STUDENT_NAME"
kubectl config set-context --current --namespace=default
```

> ⚠️ **Important:** Your `$STUDENT_NAME` ensures your resources don't conflict with other students.

---

## Step 1: Explore the CI/CD Pipeline Structure

Examine a typical GitHub Actions workflow for Kubernetes:

```yaml
name: Build and Deploy
on: { push: { branches: [main] } }
env:
  ECR_REGISTRY: ${{ secrets.AWS_ACCOUNT_ID }}.dkr.ecr.us-east-2.amazonaws.com
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
        aws-region: us-east-2 }
    - name: Build and push image
      run: |
        IMAGE_TAG=$(git rev-parse --short HEAD)
        docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG .
```

---

## Step 2: Build and Tag a Container Image

Create a sample application:

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

Build and tag with the git SHA:

```bash
export GIT_SHA=$(git rev-parse --short HEAD)
echo "Building with SHA: $GIT_SHA"

cp index.html index.html.orig
sed -i "s/__BUILD_SHA__/$GIT_SHA/g" index.html
sed -i "s/__DEPLOY_TIME__/$(date -u +%Y-%m-%dT%H:%M:%SZ)/g" index.html

docker build -t my-app:$GIT_SHA .
docker build -t my-app:latest .

mv index.html.orig index.html
```

---

## Step 3: Push to ECR

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query \
  Account --output text)
export ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.us-east-2.amazonaws.com"
export ECR_REPO="cicd-lab-app-$STUDENT_NAME"

aws ecr create-repository --repository-name $ECR_REPO \
  --region us-east-2 || echo "Repository already exists"

aws ecr get-login-password --region us-east-2 | \
  docker login --username AWS --password-stdin $ECR_REGISTRY

docker tag my-app:$GIT_SHA $ECR_REGISTRY/$ECR_REPO:$GIT_SHA
docker push $ECR_REGISTRY/$ECR_REPO:$GIT_SHA
```

---

## Step 4: Deploy with kubectl

```bash
mkdir -p ~/cicd-lab/k8s
```

Save as `k8s/deployment.yaml`:

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
apiVersion: v1
kind: Service
metadata:
  name: cicd-demo-svc
  namespace: cicd-lab-$STUDENT_NAME
spec:
  selector: { app: cicd-demo }
  ports:
  - port: 80
```

```bash
kubectl create namespace cicd-lab-$STUDENT_NAME

envsubst < k8s/deployment.yaml | kubectl apply -f -
kubectl rollout status deployment/cicd-demo -n cicd-lab-$STUDENT_NAME

kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never \
  -n cicd-lab-$STUDENT_NAME -- curl -s cicd-demo-svc
```

> ✅ 3 pods running. The curl test should return the HTML page with the build SHA.

---

## Step 5: Set Up ArgoCD Application

> ⚠️ ArgoCD is pre-installed on the cluster. Do not reinstall or delete the `argocd` namespace.

```bash
kubectl get pods -n argocd
argocd version
```

> ⚠️ **Replace `your-org`** with your GitHub organization or username. If you don't have a Git repo for this exercise, the ArgoCD sync will show a connection error — this is expected. The goal is to understand the Application manifest structure.

Review `argocd-app.yaml` — it defines an ArgoCD Application that syncs from a Git repo to your namespace with automated pruning and self-healing.

---

## Step 6: Observe ArgoCD Sync

```bash
envsubst < argocd-app.yaml | kubectl apply -f -

argocd app get cicd-demo-$STUDENT_NAME
argocd app sync cicd-demo-$STUDENT_NAME
argocd app wait cicd-demo-$STUDENT_NAME --health
```

> **Optional — ArgoCD UI via Cloud9 Preview:** `kubectl port-forward svc/argocd-server -n argocd 8080:443 &` then **Preview → Preview Running Application**.
> Default password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo`

---

## Step 7: Trigger Pipeline with Code Change

Make a code change, rebuild, and update the manifest:

```bash
cd ~/cicd-lab
sed -i 's/CI\/CD Demo Application/CI\/CD Demo v2/' index.html
git add . && git commit -m "Update application to v2"

NEW_SHA=$(git rev-parse --short HEAD)
docker build -t my-app:$NEW_SHA .

docker tag my-app:$NEW_SHA $ECR_REGISTRY/$ECR_REPO:$NEW_SHA
docker push $ECR_REGISTRY/$ECR_REPO:$NEW_SHA

sed -i "s|image: .*|image: \
${ECR_REGISTRY}/${ECR_REPO}:${NEW_SHA}|" \
  k8s/deployment.yaml
sed -i "s|git-commit: .*|git-commit: \"${NEW_SHA}\"|" k8s/deployment.yaml
git add k8s/deployment.yaml
git commit -m "Deploy image $NEW_SHA"

envsubst < k8s/deployment.yaml | kubectl apply -f -
kubectl rollout status deployment/cicd-demo -n cicd-lab-$STUDENT_NAME

kubectl run curl-test2 --image=curlimages/curl --rm -it --restart=Never \
  -n cicd-lab-$STUDENT_NAME -- curl -s cicd-demo-svc
```

> ✅ The curl response should show "CI/CD Demo v2" with the new build SHA.

---

## Step 8: Rollback via ArgoCD

**Git Revert (Preferred)** -- maintains full audit trail:

```bash
git revert HEAD --no-edit
```

> **Note:** In a real GitOps workflow, you would `git push origin main` to trigger the pipeline. Since we are using a local git repo without a configured remote, the push is not needed here — ArgoCD concepts are demonstrated via the local manifests.

**ArgoCD Rollback (Quick)** -- faster but creates drift until next sync:

```bash
argocd app history cicd-demo-$STUDENT_NAME
argocd app rollback cicd-demo-$STUDENT_NAME 1
```

---

---

## Optional Stretch Goals

> These exercises cover additional topics from the presentation. Complete them if you finish the core lab early.

### Step 9: Explore FluxCD

> ⚠️ Flux is pre-installed on the cluster. Do not run `flux bootstrap` or `flux uninstall`.

```bash
flux check

kubectl get pods -n flux-system
kubectl get crds | grep flux

flux get sources git
flux get sources helm
flux get kustomizations
```

---

### Step 10: Create a FluxCD HelmRelease

Create your namespace and a HelmRepository source:

```bash
kubectl create namespace flux-lab-$STUDENT_NAME
```

Review `helm-source.yaml` — it creates a HelmRepository pointing to the Bitnami chart registry. Review `helm-release.yaml` — it defines a HelmRelease for nginx with 2 replicas and automatic remediation on install/upgrade failures.

Apply and verify:

```bash
envsubst < helm-source.yaml | kubectl apply -f -
envsubst < helm-release.yaml | kubectl apply -f -

flux get helmreleases -n flux-lab-$STUDENT_NAME lab-nginx-$STUDENT_NAME --watch

helm list -n flux-lab-$STUDENT_NAME

kubectl get all -n flux-lab-$STUDENT_NAME \
  -l app.kubernetes.io/instance=lab-nginx-$STUDENT_NAME
```

> ✅ The HelmRelease shows `Ready: True` and nginx pods are running with 2 replicas.

---

### Step 11: Test Drift Detection

```bash
# Scale manually to create drift
kubectl scale deployment -n flux-lab-$STUDENT_NAME \
  -l app.kubernetes.io/instance=lab-nginx-$STUDENT_NAME \
  --replicas=5

kubectl get deployment -n flux-lab-$STUDENT_NAME

# Force reconciliation -- Flux reverts to 2 replicas
flux reconcile helmrelease lab-nginx-$STUDENT_NAME \
  -n flux-lab-$STUDENT_NAME

kubectl get deployment -n flux-lab-$STUDENT_NAME --watch
```

> ✅ After reconciliation, Flux reverts replicas to 2. To truly change replicas, update the HelmRelease values in Git.

---

## Step 12: Clean Up

```bash
# ArgoCD resources
kubectl delete application cicd-demo-$STUDENT_NAME -n argocd --ignore-not-found

# CI/CD namespace and ECR
kubectl delete namespace cicd-lab-$STUDENT_NAME
aws ecr delete-repository --repository-name cicd-lab-app-$STUDENT_NAME \
  --region us-east-2 --force || echo "Skipping ECR cleanup"
rm -rf ~/cicd-lab
docker rmi $(docker images my-app -q) 2>/dev/null || true

# FluxCD resources
kubectl delete helmrelease lab-nginx-$STUDENT_NAME \
  -n flux-lab-$STUDENT_NAME --ignore-not-found
kubectl delete helmrepository bitnami-$STUDENT_NAME \
  -n flux-system --ignore-not-found
kubectl delete namespace flux-lab-$STUDENT_NAME
```

> ⚠️ Do NOT delete the `argocd` or `flux-system` namespaces -- they are shared by all students.

---

## Key Takeaways

- **Image Building** -- tag with git SHA for traceability, never use `:latest` in production
- **ArgoCD** -- Application CRD defines source, destination, and sync policy
- **FluxCD** -- HelmRelease CRD for declarative Helm lifecycle with automatic drift correction
- **Rollback** -- git revert for permanent rollback, tool-specific commands for emergencies
