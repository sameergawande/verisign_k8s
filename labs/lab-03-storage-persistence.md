# Lab 3: Storage and StatefulSets
### Persistent Volumes, Claims, and Stateful Workloads
**Intermediate Kubernetes — Module 3 of 13**

---

## Lab Overview

### Objectives

- Explore StorageClasses and provisioners
- Create PersistentVolumeClaims and mount volumes in pods
- Deploy and manage StatefulSets with stable identities
- Scale StatefulSets and expand volumes

### Prerequisites

- Access to the EKS cluster via `kubectl`
- Completion of Labs 1 and 2

> **Duration:** ~45 minutes

---

## Environment Setup

```bash
export STUDENT_NAME=<your-name>
echo "Student: $STUDENT_NAME"
```

> ⚠️ **Important:** This shared cluster is used by all 22 students. Your `$STUDENT_NAME` ensures your resources don't conflict with others.

---

## Step 1: Explore StorageClasses

```bash
kubectl create namespace lab03-$STUDENT_NAME
kubectl get storageclass
kubectl describe storageclass gp2
```

> ✅ **Checkpoint:** You should see a `gp2` StorageClass with `WaitForFirstConsumer` binding mode, which defers volume creation until a pod needs it.

---

## Step 2: Create a PersistentVolumeClaim

```yaml
# Save as lab-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: lab-data-pvc
  namespace: lab03-$STUDENT_NAME
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: gp2
  resources:
    requests:
      storage: 1Gi
```

```bash
envsubst < lab-pvc.yaml | kubectl apply -f -
kubectl get pvc -n lab03-$STUDENT_NAME
```

> 📝 **Note:** Status will be Pending until a pod mounts this PVC.

---

## Step 3: Deploy a Pod with the PVC Mounted

```yaml
# Save as lab-writer-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: data-writer
  namespace: lab03-$STUDENT_NAME
spec:
  containers:
    - name: writer
      image: busybox:1.36
      command: ["sh", "-c"]
      args:
        - |
          echo "Written at $(date)" > /data/testfile.txt
          echo "Hostname: $(hostname)" >> /data/testfile.txt
          sleep 3600
      volumeMounts:
        - name: lab-data
          mountPath: /data
  volumes:
    - name: lab-data
      persistentVolumeClaim:
        claimName: lab-data-pvc
```

```bash
envsubst < lab-writer-pod.yaml | kubectl apply -f -
kubectl get pod data-writer -n lab03-$STUDENT_NAME -w
```

Verify the volume is bound and data was written:

```bash
kubectl get pvc -n lab03-$STUDENT_NAME
kubectl exec data-writer -n lab03-$STUDENT_NAME -- cat /data/testfile.txt
```

> ✅ **Checkpoint:** PVC status should be `Bound` and the file should contain your timestamp.

Examine the dynamically created PV:

```bash
PV_NAME=$(kubectl get pvc lab-data-pvc -n lab03-$STUDENT_NAME \
  -o jsonpath='{.spec.volumeName}')
kubectl describe pv $PV_NAME
```

> ✅ **Checkpoint:** Note the PV is bound to a specific AWS availability zone via Node Affinity.

---

## Step 4: Verify Data Persistence

Delete the pod, create a reader pod, and verify data survives:

```bash
kubectl delete pod data-writer -n lab03-$STUDENT_NAME
kubectl get pvc -n lab03-$STUDENT_NAME
```

```yaml
# Save as lab-reader-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: data-reader
  namespace: lab03-$STUDENT_NAME
spec:
  containers:
    - name: reader
      image: busybox:1.36
      command: ["sh", "-c"]
      args:
        - cat /data/testfile.txt && sleep 3600
      volumeMounts:
        - name: lab-data
          mountPath: /data
  volumes:
    - name: lab-data
      persistentVolumeClaim:
        claimName: lab-data-pvc
```

```bash
envsubst < lab-reader-pod.yaml | kubectl apply -f -
kubectl wait --for=condition=Ready pod/data-reader -n lab03-$STUDENT_NAME --timeout=120s
kubectl logs data-reader -n lab03-$STUDENT_NAME
```

> ✅ **Checkpoint:** The original timestamp from `data-writer` should appear, proving data persists across pod deletion.

---

## Step 5: Deploy a StatefulSet

Create the headless Service and StatefulSet:

```yaml
# Save as lab-headless-svc.yaml
apiVersion: v1
kind: Service
metadata:
  name: web-headless
  namespace: lab03-$STUDENT_NAME
spec:
  clusterIP: None
  selector:
    app: web
  ports:
    - port: 80
      targetPort: 80
```

```yaml
# Save as lab-statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: web
  namespace: lab03-$STUDENT_NAME
spec:
  serviceName: "web-headless"
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: nginx
          image: nginx:1.25
          ports:
            - containerPort: 80
          volumeMounts:
            - name: web-data
              mountPath: /usr/share/nginx/html
  volumeClaimTemplates:
    - metadata:
        name: web-data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: gp2
        resources:
          requests:
            storage: 1Gi
```

```bash
envsubst < lab-headless-svc.yaml | kubectl apply -f -
envsubst < lab-statefulset.yaml | kubectl apply -f -
kubectl get pods -n lab03-$STUDENT_NAME -l app=web -w
```

> ✅ **Checkpoint:** Pods are created sequentially: `web-0` must be Running before `web-1` starts. Press `Ctrl+C` once all three are Running.

---

## Step 6: Verify Stable Identities

```bash
kubectl get pods -n lab03-$STUDENT_NAME -l app=web -o wide
kubectl get pvc -n lab03-$STUDENT_NAME

# Test DNS resolution for a StatefulSet pod
kubectl run dns-test --image=busybox:1.36 -n lab03-$STUDENT_NAME --rm -it \
  --restart=Never -- nslookup web-0.web-headless.lab03-$STUDENT_NAME.svc.cluster.local
```

> ✅ **Checkpoint:** Each pod has a predictable name (`web-0`, `web-1`, `web-2`) and its own PVC (`web-data-web-0`, etc.). DNS resolves each pod individually.

---

## Step 7: Test Data Persistence Per Replica

Write unique content to each pod's volume:

```bash
kubectl exec web-0 -n lab03-$STUDENT_NAME -- \
  sh -c 'echo "Hello from web-0" > /usr/share/nginx/html/index.html'
kubectl exec web-1 -n lab03-$STUDENT_NAME -- \
  sh -c 'echo "Hello from web-1" > /usr/share/nginx/html/index.html'
kubectl exec web-2 -n lab03-$STUDENT_NAME -- \
  sh -c 'echo "Hello from web-2" > /usr/share/nginx/html/index.html'

for i in 0 1 2; do
    echo "--- web-$i ---"
    kubectl exec web-$i -n lab03-$STUDENT_NAME -- curl -s localhost
done
```

Delete a pod and verify its data survives:

```bash
kubectl delete pod web-1 -n lab03-$STUDENT_NAME
kubectl get pods -n lab03-$STUDENT_NAME -l app=web -w

# Once web-1 is Running again:
kubectl exec web-1 -n lab03-$STUDENT_NAME -- curl -s localhost
```

> ✅ **Checkpoint:** The recreated `web-1` still serves "Hello from web-1" because it reattached to the same PVC.

---

## Step 8: Scale the StatefulSet

```bash
# Scale up to 5 replicas (ordered creation)
kubectl scale statefulset web -n lab03-$STUDENT_NAME --replicas=5
kubectl get pods -n lab03-$STUDENT_NAME -l app=web -w

# Verify new PVCs
kubectl get pvc -n lab03-$STUDENT_NAME

# Scale down to 2 replicas (reverse order termination)
kubectl scale statefulset web -n lab03-$STUDENT_NAME --replicas=2
kubectl get pods -n lab03-$STUDENT_NAME -l app=web -w

# PVCs persist after scale-down
kubectl get pvc -n lab03-$STUDENT_NAME
```

> ⚠️ **Important:** PVCs are **not** deleted when a StatefulSet scales down. This protects data and allows reattachment on scale-up.

---

## Step 9: Test Volume Expansion

```bash
kubectl get storageclass gp2 -o jsonpath='{.allowVolumeExpansion}'

# Expand the PVC for web-0 from 1Gi to 2Gi
kubectl patch pvc web-data-web-0 -n lab03-$STUDENT_NAME \
  -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'

kubectl get pvc web-data-web-0 -n lab03-$STUDENT_NAME -w
```

> ⚠️ Volume expansion is a one-way operation -- you cannot shrink a PVC after expanding it.

---

## Step 10: Clean Up

```bash
kubectl delete statefulset web -n lab03-$STUDENT_NAME
kubectl delete pvc --all -n lab03-$STUDENT_NAME
kubectl delete namespace lab03-$STUDENT_NAME
```

---

## Summary

- `WaitForFirstConsumer` ensures EBS volumes are created in the correct availability zone
- PVCs persist independently of pods -- data survives pod deletion and rescheduling
- StatefulSets provide stable network identity, ordered operations, and per-replica storage
- PVCs are retained on scale-down to protect data
- Volume expansion is supported but is a one-way operation
