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
brew install kubectl
```

**Linux / WSL:**

```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
```

Verify the installation:

```bash
kubectl version --client
```

> ✅ **Checkpoint:** `kubectl version --client` should display v1.28+.

---

## Step 2: Connect to the Shared EKS Cluster

Configure AWS credentials (provided by the instructor):

```bash
aws configure
# AWS Access Key ID:     <provided by instructor>
# AWS Secret Access Key: <provided by instructor>
# Default region name:   us-east-1
# Default output format: json
```

Generate kubeconfig and set up your student environment:

```bash
aws eks update-kubeconfig \
  --name verisign-k8s-lab \
  --region us-east-1

# Set your unique student name
export STUDENT_NAME=<your-name>
echo "Student: $STUDENT_NAME"

# Verify cluster connectivity
kubectl cluster-info
kubectl config current-context
```

> ⚠️ **Important:** This shared cluster is used by all 22 students. Your `STUDENT_NAME` ensures your resources don't conflict with others. Set this variable at the start of every lab session.

> ⚠️ **Troubleshooting:** If you see "Unable to connect to the server", verify credentials with `aws sts get-caller-identity` and re-run `aws eks update-kubeconfig`.

---

## Step 3: Explore Cluster Nodes

```bash
# List all nodes with extended information
kubectl get nodes -o wide

# Describe a specific node (replace with your node name)
kubectl describe node <NODE_NAME>

# View all labels on nodes
kubectl get nodes --show-labels

# Check for taints on nodes
kubectl describe node <NODE_NAME> | grep -A 5 "Taints:"
```

---

## Step 4: Explore Namespaces and Workloads

```bash
# List all namespaces
kubectl get namespaces

# List system components running in kube-system
kubectl get pods -n kube-system

# View all resources across all namespaces
kubectl get all -A
```

---

## Step 5: Deploy Your First Application

```bash
# Create your personal namespace
kubectl create namespace lab01-$STUDENT_NAME
kubectl config set-context --current --namespace=lab01-$STUDENT_NAME

# Create an nginx deployment with 2 replicas
kubectl create deployment nginx-lab --image=nginx:1.25 --replicas=2

# Expose the deployment as a ClusterIP service
kubectl expose deployment nginx-lab --port=80 --target-port=80

# Verify resources were created
kubectl get all -n lab01-$STUDENT_NAME
```

> ✅ **Checkpoint:** You should see 2 pods in `Running` state, 1 deployment with `2/2` ready, and 1 ClusterIP service.

---

## Step 6: Examine Pod Details

```bash
# Get pod names
kubectl get pods -n lab01-$STUDENT_NAME

# Describe a pod (replace with actual pod name)
kubectl describe pod <POD_NAME> -n lab01-$STUDENT_NAME

# View logs from a pod
kubectl logs <POD_NAME> -n lab01-$STUDENT_NAME

# Execute a command inside the container
kubectl exec -it <POD_NAME> -n lab01-$STUDENT_NAME -- /bin/bash

# Inside the container, explore:
cat /etc/nginx/nginx.conf
curl localhost:80
exit
```

> ✅ **Checkpoint:** You should see the nginx welcome page HTML when running `curl localhost:80` from inside the container.

---

## Step 7: Scale the Deployment

```bash
# Scale up to 5 replicas
kubectl scale deployment nginx-lab --replicas=5 -n lab01-$STUDENT_NAME

# Watch pods come up in real-time (Ctrl+C to exit)
kubectl get pods -n lab01-$STUDENT_NAME -w

# Scale down to 2 replicas
kubectl scale deployment nginx-lab --replicas=2 -n lab01-$STUDENT_NAME

# Watch pods terminate
kubectl get pods -n lab01-$STUDENT_NAME -w
```

---

## Step 8: Access the Application

Use port-forwarding to access your service locally:

```bash
# Forward local port 8080 to the service port 80
kubectl port-forward service/nginx-lab 8080:80 -n lab01-$STUDENT_NAME
```

Open a **second terminal** and test the connection:

```bash
curl http://localhost:8080
curl -I http://localhost:8080
```

> ✅ **Checkpoint:** You should see the default nginx welcome page. Press `Ctrl+C` in the first terminal to stop port-forwarding when done.

---

## Step 9: Explore Resource Usage

```bash
kubectl top nodes
kubectl top pods -n lab01-$STUDENT_NAME
```

> ⚠️ **If kubectl top fails:** Check if metrics-server is running: `kubectl get pods -n kube-system | grep metrics-server`. If missing, skip this step.

---

## Step 10: Clean Up

```bash
kubectl config set-context --current --namespace=default
kubectl delete namespace lab01-$STUDENT_NAME
```

> ✅ **Checkpoint:** The `lab01-$STUDENT_NAME` namespace should no longer appear in `kubectl get namespaces`.

---

## Summary

- `aws eks update-kubeconfig` connects kubectl to EKS using IAM authentication
- Namespaces provide logical isolation — always work in a dedicated namespace
- `describe`, `logs`, and `exec` are your core troubleshooting triad
- Deployments manage ReplicaSets which manage Pods
- Port-forward is a development tool; production uses Ingress or LoadBalancer services

---

*Lab 1 Complete — Up Next: Lab 2 — Configuring Autoscaling*
