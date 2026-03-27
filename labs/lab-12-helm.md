# Lab 12: Helm and Templating
### Package Management for Kubernetes
**Intermediate Kubernetes — Module 12 of 13**

---

## Lab Overview

### Objectives

- Install and manage Helm charts from repositories
- Upgrade and rollback releases
- Create a custom Helm chart with templating
- Validate, debug, and package charts

### Prerequisites

- `kubectl` configured, Helm v3 installed
- Access to a Kubernetes cluster (EKS)
- Completed Labs 1–11

> ⏱ **Duration:** ~45 minutes

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

## Step 1: Verify Helm Installation

Confirm Helm is installed and check the version:

```bash
# Check Helm version
helm version

# Check if any repos are already configured
helm repo list

# Check for any existing releases
helm list --all-namespaces
```

> ✅ **Expected Output:** `version.BuildInfo{Version:"v3.x.x", ...}` — The repo list may show `Error: no repositories to show` if no repos have been added yet. Verify that the version starts with `v3`.

> ⚠️ **Troubleshooting:** If `helm` is not found, install it:
> ```bash
> curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
> ```

> 💡 **Key Concept:** Helm v3 does not require Tiller. It communicates directly with the Kubernetes API using the kubeconfig.

---

## Step 2: Add Bitnami Repository and Search

Add the Bitnami chart repository and explore available charts:

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami

helm repo update

helm search repo nginx

helm search repo bitnami/nginx --versions | head -10

helm show chart bitnami/nginx
```

> ✅ **Expected Output:** The `repo add` should confirm `"bitnami" has been added to your repositories`. The search should show multiple nginx-related charts with versions and descriptions.

> 📝 **Helm Repository Commands:**
> - `helm repo add` — register a new chart repository
> - `helm repo update` — refresh the local cache
> - `helm search repo` — search charts in added repositories
> - `helm search hub` — search Artifact Hub for charts across all registries
>
> The `--versions` flag shows all available chart versions, not just the latest.

---

## Step 3: Install a Chart

Install the Bitnami nginx chart with custom values:

```bash
kubectl create namespace helm-lab-$STUDENT_NAME

helm show values bitnami/nginx | head -50

helm install my-nginx bitnami/nginx \
  --namespace helm-lab-$STUDENT_NAME \
  --set replicaCount=2 \
  --set service.type=ClusterIP

kubectl get pods -n helm-lab-$STUDENT_NAME -w
```

> ✅ **Expected Output:**
> ```
> NAME: my-nginx
> STATUS: deployed
> REVISION: 1
> ```
> Two nginx pods should reach `Running` state.

> 💡 **Key Concept:** The install command anatomy: release name (`my-nginx`), chart reference (`bitnami/nginx`), namespace, and value overrides. The `--set` flag overrides individual values from the chart's `values.yaml`.

---

## Step 4: Explore the Release

Use Helm commands to examine the installed release:

```bash
helm list -n helm-lab-$STUDENT_NAME

helm get values my-nginx -n helm-lab-$STUDENT_NAME

helm get values my-nginx -n helm-lab-$STUDENT_NAME --all

helm get manifest my-nginx -n helm-lab-$STUDENT_NAME

helm get notes my-nginx -n helm-lab-$STUDENT_NAME
```

> ✅ **Expected Output:** `helm get values` should show the overrides you specified (`replicaCount: 2`, `service.type: ClusterIP`). The manifest shows the actual YAML applied to the cluster.

> 💡 **Key Concept:** Use `helm get manifest` to see exactly what Kubernetes resources were created. This is invaluable for debugging chart behavior. The `--all` flag on `get values` shows every value including defaults.

---

## Step 5: Upgrade the Release

Upgrade the release to change the replica count:

```bash
# Upgrade the release with more replicas
helm upgrade my-nginx bitnami/nginx \
  --namespace helm-lab-$STUDENT_NAME \
  --set replicaCount=3 \
  --set service.type=ClusterIP

# Verify the upgrade
helm list -n helm-lab-$STUDENT_NAME
kubectl get pods -n helm-lab-$STUDENT_NAME

# Check the revision number has incremented
helm status my-nginx -n helm-lab-$STUDENT_NAME
```

> ✅ **Expected Output:** The release should now be at `REVISION: 2` with 3 nginx pods running.

> ⚠️ **Important:** When using `--set` during upgrade, previous `--set` values are **not** preserved unless you include them again or use `--reuse-values`. For production, use values files instead of `--set`.

---

## Step 6: Release History and Rollback

Explore release history and perform a rollback:

```bash
# View release history
helm history my-nginx -n helm-lab-$STUDENT_NAME

# Rollback to revision 1
helm rollback my-nginx 1 -n helm-lab-$STUDENT_NAME

# Verify the rollback
helm list -n helm-lab-$STUDENT_NAME
kubectl get pods -n helm-lab-$STUDENT_NAME

# Check history again (rollback creates a new revision)
helm history my-nginx -n helm-lab-$STUDENT_NAME
```

> ✅ **Expected Output:** After rollback, the release is at `REVISION: 3` with 2 replicas (matching revision 1 values). The history shows all three revisions.

> 💡 **Release Storage:** Helm stores release information as Kubernetes Secrets in the release namespace. Run the following to see them:
> ```bash
> kubectl get secrets -n helm-lab-$STUDENT_NAME -l owner=helm
> ```

> 📝 **Note:** A rollback creates a new revision — it does not delete history. The history shows the rollback description. Helm stores each revision as a Secret, so the revision history limit is controlled by the Helm `max-history` setting.

---

## Step 7: Create a Custom Chart

Use `helm create` to generate a chart skeleton:

```bash
# Create a new chart called mychart
helm create mychart

# View the generated structure
tree mychart/
# If tree is not installed:
find mychart/ -type f | sort
```

> ✅ **Expected Output:**
> ```
> mychart/
> ├── Chart.yaml            # Chart metadata
> ├── charts/               # Dependencies
> ├── templates/            # Template files
> │   ├── NOTES.txt         # Post-install notes
> │   ├── _helpers.tpl      # Template helpers
> │   ├── deployment.yaml
> │   ├── hpa.yaml
> │   ├── ingress.yaml
> │   ├── service.yaml
> │   ├── serviceaccount.yaml
> │   └── tests/
> │       └── test-connection.yaml
> └── values.yaml           # Default configuration
> ```

> 💡 **Key Concept:** `Chart.yaml` defines the chart metadata. `values.yaml` provides defaults. The `templates/` directory contains Go templates that render into Kubernetes manifests.

---

## Step 8: Examine Chart Structure

Examine the chart metadata and default values:

```bash
# View chart metadata
cat mychart/Chart.yaml

# View default values
cat mychart/values.yaml
```

### Chart.yaml Key Fields

- `apiVersion` — `v2` for Helm 3
- `name` / `version` — chart identity (SemVer)
- `appVersion` — app version
- `type` — `application` or `library`

### values.yaml Purpose

- Provides default configuration
- Overridden by `--set` or `-f`
- Accessed via `.Values` in templates

> 📝 **Note:** The chart `version` changes when the chart templates change. The `appVersion` changes when the packaged application changes. Both follow SemVer.

### Explore the Templates

Examine the deployment template to understand Go templating:

```bash
# View the deployment template
cat mychart/templates/deployment.yaml

# View the helper templates
cat mychart/templates/_helpers.tpl
```

> 💡 **Go Template Syntax:**
> - `{{ .Values.replicaCount }}` — access values from values.yaml
> - `{{ .Release.Name }}` — built-in release name
> - `{{ include "mychart.fullname" . }}` — call a named template
> - `{{- with .Values.nodeSelector }}` — conditional blocks
> - `{{ toYaml . | nindent 8 }}` — format YAML with indentation

---

## Step 9: Customize Templates

### Add a ConfigMap Template

Create a new template for a ConfigMap:

```yaml
# Save as mychart/templates/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "mychart.fullname" . }}-config
  labels:
    {{- include "mychart.labels" . | nindent 4 }}
data:
  APP_ENV: {{ .Values.appConfig.environment | quote }}
  APP_LOG_LEVEL: {{ .Values.appConfig.logLevel | quote }}
  {{- if .Values.appConfig.customMessage }}
  CUSTOM_MESSAGE: {{ .Values.appConfig.customMessage | quote }}
  {{- end }}
```

> 💡 **Template Functions:** The `include` function calls the fullname helper. The `quote` function wraps values in quotes. The `if` block conditionally renders the `customMessage` field.

### Update values.yaml

Add the new configuration values to `values.yaml`:

```yaml
# Add to the end of mychart/values.yaml

appConfig:
  environment: production
  logLevel: info
  customMessage: "Hello from Helm!"
```

### Update Deployment Template

Update the deployment template to mount the ConfigMap. Add the following to the container spec in `mychart/templates/deployment.yaml`, inside the `containers` section:

```yaml
          envFrom:
          - configMapRef:
              name: {{ include "mychart.fullname" . }}-config
```

> ⚠️ **Indentation Matters:** YAML indentation in Helm templates must be precise. Use `nindent` to control indentation levels in template output. Go template whitespace control with dashes (`{{-` and `-}}`) is important for clean YAML output.

---

## Step 10: Validate and Debug

Use Helm's validation tools to check the chart:

```bash
# Lint the chart for errors and best practices
helm lint mychart/

# Render templates locally (without connecting to cluster)
helm template my-release mychart/

# Render with custom values
helm template my-release mychart/ --set appConfig.environment=staging

# Dry-run install (connects to cluster but does not install)
helm install my-release mychart/ \
  --namespace helm-lab-$STUDENT_NAME \
  --dry-run --debug
```

> ✅ **Expected Output:** `helm lint` should show `==> Linting mychart/` followed by `1 chart(s) linted, 0 chart(s) failed`. Template output shows rendered YAML.

> 💡 **Validation Workflow:**
> - `helm lint` — checks chart structure and template syntax
> - `helm template` — renders templates locally for review
> - `helm install --dry-run` — validates against the cluster API without installing
>
> The `--debug` flag with `--dry-run` produces verbose output including the computed values and rendered templates.

---

## Step 11: Package and Install Custom Chart

Package the chart and install it from the archive:

```bash
helm package mychart/

ls mychart-*.tgz

helm install my-custom-app mychart-0.1.0.tgz \
  --namespace helm-lab-$STUDENT_NAME \
  --set appConfig.environment=development \
  --set appConfig.logLevel=debug

helm list -n helm-lab-$STUDENT_NAME
kubectl get all -n helm-lab-$STUDENT_NAME -l app.kubernetes.io/instance=my-custom-app
```

> ✅ **Expected Output:** The package command creates `mychart-0.1.0.tgz`. The install creates a new release `my-custom-app` with the custom values.

> 📝 **Note:** In production, packaged charts are typically pushed to a chart repository (ChartMuseum, Harbor, or an OCI registry) for team-wide access. Helm 3 supports OCI registries natively.

### Verify ConfigMap and Environment

Confirm the custom ConfigMap was created with correct values:

```bash
# Check the ConfigMap
kubectl get configmap -n helm-lab-$STUDENT_NAME -l app.kubernetes.io/instance=my-custom-app
kubectl describe configmap my-custom-app-mychart-config -n helm-lab-$STUDENT_NAME

# Verify environment variables in the pod
kubectl exec -n helm-lab-$STUDENT_NAME \
  $(kubectl get pod -n helm-lab-$STUDENT_NAME -l \
    app.kubernetes.io/instance=my-custom-app \
    -o jsonpath='{.items[0].metadata.name}') \
  -- env | grep -E "APP_|CUSTOM"
```

> ✅ **Expected Output:**
> ```
> APP_ENV=development
> APP_LOG_LEVEL=debug
> CUSTOM_MESSAGE=Hello from Helm!
> ```

> 💡 **Key Concept:** This confirms the full pipeline: values override defaults, templates render with those values, and the resulting Kubernetes resources contain the expected configuration.

---

## Step 12: Clean Up

Remove all Helm releases and lab resources:

```bash
# Uninstall all releases
helm uninstall my-nginx -n helm-lab-$STUDENT_NAME
helm uninstall my-custom-app -n helm-lab-$STUDENT_NAME

# Verify releases are removed
helm list -n helm-lab-$STUDENT_NAME

# Delete the namespace
kubectl delete namespace helm-lab-$STUDENT_NAME

# Clean up local files
rm -rf mychart/ mychart-*.tgz
```

> ✅ **Expected Output:**
> ```
> release "my-nginx" uninstalled
> release "my-custom-app" uninstalled
> namespace "helm-lab-$STUDENT_NAME" deleted
> ```

> 📝 **Note:** `helm uninstall` removes all Kubernetes resources created by the release. Use `--keep-history` if you want to preserve release history for auditing. In production, consider keeping history for compliance.

---

## Summary and Key Takeaways

- **Helm Repositories** — add, search, and install charts from community registries
- **Release Management** — install, upgrade, rollback, and uninstall releases with full history
- **Custom Charts** — scaffold, structure, and organize chart templates and values
- **Go Templates** — use `.Values`, conditionals, and helpers to render dynamic manifests
- **Validation** — lint, template, and dry-run before deploying to production

> 💡 **Key Takeaway:** Helm transforms Kubernetes manifest management from copy-paste YAML into parameterized, versioned, and reusable packages. It is the foundation for GitOps workflows covered in the next lab.
