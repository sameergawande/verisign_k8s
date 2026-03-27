# Lab 1: Exploring Your Kubernetes Cluster
### Hands-On Cluster Navigation and kubectl Fundamentals
**Intermediate Kubernetes — Module 1 of 13**

---

## Lab Overview

### Objectives

- Install and configure kubectl
- Connect to the shared EKS cluster
- Navigate cluster nodes, namespaces, and workloads
- Deploy, inspect, scale, and access an application
- Use essential kubectl commands confidently

### Prerequisites

- Terminal / shell access (macOS, Linux, or WSL)
- AWS CLI v2 installed
- AWS credentials provided by the instructor

> ⏱ **Duration:** ~45 minutes

---

## Step 1: Install kubectl

Install the Kubernetes CLI for your operating system.

**macOS:**

```bash
# Using Homebrew
brew install kubectl

# Or download directly
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/darwin/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
```

**Linux / WSL:**

```bash
# Download latest stable
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
```

Verify the installation:

```bash
kubectl version --client
# Expected: Client Version: v1.xx.x
```

> ✅ **Checkpoint:** `kubectl version --client` should display a version number (v1.28+). If you already have kubectl installed, you can skip the install step.

---

## Step 2: Connect to the Shared EKS Cluster

### Configure AWS Credentials

Set up your AWS CLI credentials (provided by the instructor):

```bash
# Configure the AWS CLI with your provided credentials
aws configure
# AWS Access Key ID:     <provided by instructor>
# AWS Secret Access Key: <provided by instructor>
# Default region name:   us-east-1
# Default output format: json
```

Verify your AWS identity:

```bash
# Confirm your credentials are working
aws sts get-caller-identity
```

> ✅ **Expected Output:** You should see your `UserId`, `Account`, and `Arn`. If you get an error, double-check the access key and secret key with the instructor.

### Generate kubeconfig for EKS

Use the AWS CLI to configure kubectl access to the shared EKS cluster:

```bash
# Update your kubeconfig with the shared EKS cluster
aws eks update-kubeconfig \
  --name verisign-k8s-lab \
  --region us-east-1

# Verify the context was added
kubectl config current-context
```

> ✅ **Expected Output:** The context should display something like `arn:aws:eks:us-east-1:<account-id>:cluster/verisign-k8s-lab`. This confirms kubectl is now configured to talk to the EKS cluster.

> 📝 **How it works:** `aws eks update-kubeconfig` writes a kubeconfig entry to `~/.kube/config` that uses the AWS CLI as an authentication plugin. Every kubectl command authenticates via your IAM credentials.

### Set Up Your Student Environment

Set your student identifier and verify full connectivity:

```bash
# Set your unique student name (use your first name or assigned number)
export STUDENT_NAME=<your-name>
echo "Student: $STUDENT_NAME"

# Verify cluster connectivity
kubectl cluster-info

# Verify client and server versions
kubectl version

# Confirm current context
kubectl config current-context
```

> ⚠️ **Important:** This shared cluster is used by all 22 students. Your `STUDENT_NAME` ensures your resources don't conflict with others. Set this variable at the start of every lab session.

> ✅ **Checkpoint:** You should see the Kubernetes control plane address and the CoreDNS service address. The `kubectl version` command should show both Client and Server versions.

> ⚠️ **Troubleshooting:** If you see "Unable to connect to the server", verify your AWS credentials with `aws sts get-caller-identity` and re-run the `aws eks update-kubeconfig` command.

---

## Step 3: Explore Cluster Nodes

Examine the nodes that form your cluster:

```bash
# List all nodes with extended information
kubectl get nodes -o wide

# Describe a specific node (replace with your node name)
kubectl describe node <NODE_NAME>
```

> ✅ **Expected Output:** You should see nodes listed with STATUS `Ready`, along with their ROLES, AGE, VERSION, INTERNAL-IP, OS-IMAGE, and CONTAINER-RUNTIME.

### Node Labels and Taints

Labels and taints control pod scheduling:

```bash
# View all labels on nodes
kubectl get nodes --show-labels

# View labels in a cleaner format for a specific node
kubectl describe node <NODE_NAME> | grep -A 20 "Labels:"

# Check for taints on nodes
kubectl describe node <NODE_NAME> | grep -A 5 "Taints:"
```

> 💡 **Key Concepts:**
> - **Labels** — key/value pairs for selecting and organizing nodes (e.g., `node.kubernetes.io/instance-type`)
> - **Taints** — repel pods unless they have matching tolerations (e.g., `NoSchedule`)

---

## Step 4: Explore Namespaces

Namespaces provide logical isolation within the cluster:

```bash
# List all namespaces
kubectl get namespaces

# View namespace details
kubectl describe namespace default
```

> ✅ **Expected Output:** You should see at least: `default`, `kube-system`, `kube-public`, and `kube-node-lease`.

Now explore the system namespace:

```bash
# List system components running in kube-system
kubectl get pods -n kube-system

# View system services
kubectl get services -n kube-system
```

> 📝 **Note:** The `kube-system` namespace contains critical cluster components like CoreDNS, kube-proxy, and the AWS VPC CNI plugin. Never modify resources here without understanding the impact.

---

## Step 5: Explore Running Workloads

Get a full picture of what is running in the cluster:

```bash
# List all pods across all namespaces
kubectl get pods -A

# List all deployments across all namespaces
kubectl get deployments -A

# List all services across all namespaces
kubectl get services -A

# View all resources in a single command
kubectl get all -A
```

> ✅ **Expected Output:** You should see system pods in `kube-system` and possibly workloads in other namespaces. All system pods should show `Running` status with all containers ready (e.g., `1/1`).

> 💡 **Key Point:** The `-A` flag (short for `--all-namespaces`) lets you see resources across the entire cluster. Without it, kubectl only shows the `default` namespace.

---

## Step 6: Deploy Your First Application

### Create a Namespace and Deploy nginx

Create an isolated namespace for your work:

```bash
# Create your personal namespace
kubectl create namespace lab01-$STUDENT_NAME

# Set it as your default context (optional but convenient)
kubectl config set-context --current --namespace=lab01-$STUDENT_NAME

# Verify you are in the correct namespace
kubectl config view --minify | grep namespace
```

Deploy an nginx application:

```bash
# Create an nginx deployment with 2 replicas
kubectl create deployment nginx-lab --image=nginx:1.25 --replicas=2

# Expose the deployment as a ClusterIP service
kubectl expose deployment nginx-lab --port=80 --target-port=80

# Verify resources were created
kubectl get all -n lab01-$STUDENT_NAME
```

> ✅ **Expected Output:** You should see 2 pods in `Running` state, 1 deployment with `2/2` ready, 1 replica set, and 1 ClusterIP service.

---

## Step 7: Examine Pod Details

Inspect your running pods in depth:

```bash
# Get pod names
kubectl get pods -n lab01-$STUDENT_NAME

# Describe a pod (replace with actual pod name)
kubectl describe pod <POD_NAME> -n lab01-$STUDENT_NAME
```

> 💡 **What to Look For in describe:**
> - **Status** — current pod phase (Running, Pending, etc.)
> - **Conditions** — Ready, Initialized, PodScheduled
> - **Events** — scheduling decisions, image pulls, container starts
> - **IP** — the pod's cluster-internal IP address

### Logs and Interactive Access

View container logs and exec into a running container:

```bash
# View logs from a pod
kubectl logs <POD_NAME> -n lab01-$STUDENT_NAME

# Follow logs in real-time (Ctrl+C to exit)
kubectl logs <POD_NAME> -n lab01-$STUDENT_NAME --follow

# Execute a command inside the container
kubectl exec -it <POD_NAME> -n lab01-$STUDENT_NAME -- /bin/bash

# Inside the container, explore:
cat /etc/nginx/nginx.conf
curl localhost:80
exit
```

> ✅ **Checkpoint:** You should be able to see the nginx welcome page HTML when running `curl localhost:80` from inside the container.

> 📝 **Note:** The `--` separator before `/bin/bash` is required. It tells kubectl that everything after it is the command to run inside the container, not a kubectl argument.

---

## Step 8: Scale the Deployment

Scale your deployment up and observe the changes:

```bash
# Scale up to 5 replicas
kubectl scale deployment nginx-lab --replicas=5 -n lab01-$STUDENT_NAME

# Watch pods come up in real-time (Ctrl+C to exit)
kubectl get pods -n lab01-$STUDENT_NAME -w

# Verify the deployment status
kubectl get deployment nginx-lab -n lab01-$STUDENT_NAME
```

> ✅ **Expected Output:** The deployment should show `5/5` ready replicas. All 5 pods should be in `Running` state within a few seconds.

Now scale back down:

```bash
# Scale down to 2 replicas
kubectl scale deployment nginx-lab --replicas=2 -n lab01-$STUDENT_NAME

# Watch pods terminate
kubectl get pods -n lab01-$STUDENT_NAME -w
```

> 💡 **Key Point:** Kubernetes uses the ReplicaSet controller to maintain the desired number of replicas. When you scale down, it selects pods for termination based on a defined algorithm (newest pods on nodes with the most replicas are terminated first).

---

## Step 9: Access the Application

Use port-forwarding to access your service locally:

```bash
# Forward local port 8080 to the service port 80
kubectl port-forward service/nginx-lab 8080:80 -n lab01-$STUDENT_NAME
```

Open a **second terminal** and test the connection:

```bash
# Test the application
curl http://localhost:8080

# View just the HTTP headers
curl -I http://localhost:8080
```

> ✅ **Expected Output:** You should see the default nginx welcome page HTML. The headers should show `HTTP/1.1 200 OK` and `Server: nginx/1.25.x`.

> 📝 **Note:** Press `Ctrl+C` in the first terminal to stop port-forwarding when done. Port-forwarding only lasts as long as the command is running.

---

## Step 10: Explore Resource Usage

Check resource consumption across the cluster:

```bash
# View node resource usage
kubectl top nodes

# View pod resource usage in your namespace
kubectl top pods -n lab01-$STUDENT_NAME

# View pod resource usage across all namespaces
kubectl top pods -A --sort-by=cpu
```

> ✅ **Expected Output:** You should see CPU (in millicores) and memory usage for each node and pod. Nodes will show both usage and percentage of allocatable capacity.

> ⚠️ **If kubectl top fails:** The metrics-server may not be installed. Check with:
>
> ```bash
> kubectl get pods -n kube-system | grep metrics-server
> ```
>
> If missing, this is expected in some environments. You can skip this step and proceed to cleanup.

---

## Step 11: Clean Up Resources

Remove all resources created during this lab:

```bash
# Reset your default namespace context
kubectl config set-context --current --namespace=default

# Delete the entire lab namespace (and everything in it)
kubectl delete namespace lab01-$STUDENT_NAME

# Verify it is gone
kubectl get namespaces
```

> ✅ **Checkpoint:** The `lab01-$STUDENT_NAME` namespace should no longer appear in the namespace list. All deployments, pods, and services within it are automatically deleted.

> 💡 **Key Point:** Deleting a namespace cascades the deletion to *all* resources within it. This is the cleanest way to tear down an environment, but be careful — it cannot be undone.

---

## Summary — Key Commands

| Command | Purpose |
|---------|---------|
| `aws eks update-kubeconfig` | Generate kubeconfig for EKS cluster |
| `kubectl cluster-info` | Verify cluster connectivity |
| `kubectl get nodes -o wide` | List nodes with details |
| `kubectl get pods -A` | List all pods in all namespaces |
| `kubectl describe <resource>` | Detailed info with events |
| `kubectl logs <pod>` | View container logs |
| `kubectl exec -it <pod> -- bash` | Interactive shell in container |
| `kubectl scale deployment <name>` | Adjust replica count |
| `kubectl port-forward` | Access services locally |
| `kubectl top nodes/pods` | View resource usage |
| `kubectl delete namespace` | Cascade-delete all resources |

---

## Key Takeaways

- `aws eks update-kubeconfig` connects kubectl to EKS using IAM authentication
- kubectl is your primary interface for interacting with Kubernetes clusters
- Namespaces provide logical isolation — always work in a dedicated namespace
- `describe`, `logs`, and `exec` are your core troubleshooting triad
- Deployments manage ReplicaSets which manage Pods — the hierarchy matters
- Port-forward is a development tool; production uses Ingress or LoadBalancer services
- Always clean up lab resources by deleting the namespace

---

*Lab 1 Complete — Up Next: Lab 2 — Configuring Autoscaling*
