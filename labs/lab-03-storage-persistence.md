# Lab 3: Storage and StatefulSets
### Persistent Volumes, Claims, and Stateful Workloads
**Intermediate Kubernetes — Module 3 of 13**

---

## Lab Overview

### What You Will Do

- Explore StorageClasses and provisioners
- Create PersistentVolumeClaims
- Mount volumes in pods and verify persistence
- Deploy and manage StatefulSets
- Test stable identities and ordered operations
- Scale StatefulSets and expand volumes

### Prerequisites

- Access to the EKS cluster via `kubectl`
- Completion of Labs 1 and 2
- Familiarity with pods and deployments

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

## Step 1: Explore StorageClasses

List all StorageClasses available on the cluster:

```bash
# Create a namespace for this lab
kubectl create namespace lab03-$STUDENT_NAME

# List all StorageClasses
kubectl get storageclass
```

> ✅ **Expected Output:**
> ```
> NAME            PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
> gp2 (default)  kubernetes.io/aws-ebs   Delete          WaitForFirstConsumer
> gp3-encrypted  ebs.csi.aws.com         Delete          WaitForFirstConsumer
> ```

### Describe the Default StorageClass

Examine the default StorageClass in detail:

```bash
# Describe the default StorageClass
kubectl describe storageclass gp2
```

> ✅ **Expected Output (key fields):**
> ```
> Name:            gp2
> IsDefaultClass:  Yes
> Annotations:     storageclass.kubernetes.io/is-default-class=true
> Provisioner:     kubernetes.io/aws-ebs
> Parameters:      fsType=ext4,type=gp2
> ReclaimPolicy:   Delete
> VolumeBindingMode:  WaitForFirstConsumer
> ```

> 💡 **Key Concepts:** The `Provisioner` tells Kubernetes which driver creates the actual storage. `WaitForFirstConsumer` means the volume is not created until a pod actually needs it, ensuring it is provisioned in the correct availability zone.

---

## Step 2: Create a PersistentVolumeClaim

Create a PVC requesting 1Gi of storage:

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
# Apply the PVC
kubectl apply -f lab-pvc.yaml

# Check the PVC status
kubectl get pvc -n lab03-$STUDENT_NAME
```

> 📝 **Note:** The PVC status will show **Pending** because the binding mode is `WaitForFirstConsumer`. The volume will not be provisioned until a pod references this PVC. This is expected behavior. `ReadWriteOnce` means only one node can mount the volume at a time, which is the standard mode for EBS volumes.

---

## Step 3: Deploy a Pod with the PVC Mounted

Create a pod that mounts the PVC and writes data:

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
          echo "Lab 3 persistence test" >> /data/testfile.txt
          echo "Data written successfully"
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
# Apply the pod
kubectl apply -f lab-writer-pod.yaml

# Wait for the pod to be running
kubectl get pod data-writer -n lab03-$STUDENT_NAME -w
```

### Verify the Volume is Bound

Check that the PVC is now bound and the data was written:

```bash
# Check PVC status - should now be Bound
kubectl get pvc -n lab03-$STUDENT_NAME

# Verify the data was written
kubectl exec data-writer -n lab03-$STUDENT_NAME -- cat /data/testfile.txt

# Check the pod logs
kubectl logs data-writer -n lab03-$STUDENT_NAME
```

> ✅ **Expected Output:**
> ```
> NAME           STATUS   VOLUME                                     CAPACITY
> lab-data-pvc   Bound    pvc-a1b2c3d4-e5f6-7890-abcd-ef1234567890   1Gi
>
> Written at Thu Mar 13 14:30:00 UTC 2026
> Hostname: data-writer
> Lab 3 persistence test
> ```

---

## Step 4: Verify Data Persistence

Delete the pod, create a reader pod, and verify data survives:

```bash
# Delete the writer pod and verify PVC is still Bound
kubectl delete pod data-writer -n lab03-$STUDENT_NAME
kubectl get pvc -n lab03-$STUDENT_NAME
```

Create a reader pod that mounts the same PVC:

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
        - |
          echo "=== Reading persisted data ==="
          cat /data/testfile.txt
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
kubectl apply -f lab-reader-pod.yaml
kubectl logs data-reader -n lab03-$STUDENT_NAME
```

> ✅ **Success:** The file written by `data-writer` is still present in the volume, even though that pod no longer exists. The original timestamp proves this is the same data. The PVC and its underlying PV persist independently of any pod.

---

## Step 5: Explore the Dynamically Provisioned PV

Examine the dynamically created PV:

```bash
# List all PersistentVolumes
kubectl get pv

# Describe the PV (use the name from the output above)
PV_NAME=$(kubectl get pvc lab-data-pvc -n lab03-$STUDENT_NAME \
  -o jsonpath='{.spec.volumeName}')
kubectl describe pv $PV_NAME
```

> ✅ **Key Fields in the Output:**
> ```
> Source:
>   Type:       AWSElasticBlockStore (or CSI)
>   VolumeID:   vol-0abc123def456789
>   FSType:     ext4
> Claim:        lab03-$STUDENT_NAME/lab-data-pvc
> Node Affinity:
>   Required Terms:
>     topology.kubernetes.io/zone: us-east-1a
> ```

> 💡 **Key Insight:** The PV is bound to a specific AWS availability zone. This is why `WaitForFirstConsumer` is essential — it ensures the volume is created in the same AZ as the pod.

---

## Step 6: Deploy a StatefulSet

Create a StatefulSet with volumeClaimTemplates:

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

> 💡 **Key Differences from a Deployment:** The `serviceName` field links to a headless Service, and `volumeClaimTemplates` automatically creates a unique PVC for each replica. Each pod gets its own dedicated volume rather than sharing one. The naming convention is predictable: `web-data-web-0`, `web-data-web-1`, `web-data-web-2`.

### Create the Headless Service and Apply

A StatefulSet requires a headless Service (`clusterIP: None`) for DNS-based pod discovery:

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

```bash
kubectl apply -f lab-headless-svc.yaml
kubectl apply -f lab-statefulset.yaml
kubectl get pods -n lab03-$STUDENT_NAME -l app=web -w
```

> ✅ **Observe:** Pods are created sequentially: `web-0` must be Running and Ready before `web-1` starts, and so on. This ordered startup is a key StatefulSet guarantee. Press `Ctrl+C` to exit the watch once all three pods are Running.

---

## Step 7: Verify Stable Identities

Examine the predictable naming and DNS records:

```bash
# List pods - note the sequential naming
kubectl get pods -n lab03-$STUDENT_NAME -l app=web -o wide

# List the auto-created PVCs
kubectl get pvc -n lab03-$STUDENT_NAME

# Test DNS resolution for each pod
kubectl run dns-test --image=busybox:1.36 -n lab03-$STUDENT_NAME --rm -it \
  --restart=Never -- nslookup web-0.web-headless.lab03-$STUDENT_NAME.svc.cluster.local
```

> ✅ **Expected Output:**
> ```
> NAME    READY   STATUS    IP
> web-0   1/1     Running   10.0.1.15
> web-1   1/1     Running   10.0.2.22
> web-2   1/1     Running   10.0.3.18
>
> NAME                STATUS   VOLUME        CAPACITY
> web-data-web-0      Bound    pvc-...       1Gi
> web-data-web-1      Bound    pvc-...       1Gi
> web-data-web-2      Bound    pvc-...       1Gi
> ```

> 💡 **Key Insight:** Each pod has a predictable name (`web-0`, `web-1`, `web-2`) and its own dedicated PVC (`web-data-web-0`, etc.). Even if a pod is deleted and rescheduled, it reconnects to the same PVC and gets the same DNS name. The DNS pattern is `pod-name.service-name.namespace.svc.cluster.local`.

---

## Step 8: Test Data Persistence Per Replica

### Write Unique Data to Each Replica

Write unique content to each pod's volume:

```bash
# Write unique data to each pod
kubectl exec web-0 -n lab03-$STUDENT_NAME -- \
  sh -c 'echo "Hello from web-0" > /usr/share/nginx/html/index.html'

kubectl exec web-1 -n lab03-$STUDENT_NAME -- \
  sh -c 'echo "Hello from web-1" > /usr/share/nginx/html/index.html'

kubectl exec web-2 -n lab03-$STUDENT_NAME -- \
  sh -c 'echo "Hello from web-2" > /usr/share/nginx/html/index.html'

# Verify each pod serves its own content
for i in 0 1 2; do
    echo "--- web-$i ---"
    kubectl exec web-$i -n lab03-$STUDENT_NAME -- curl -s localhost
done
```

> ✅ **Expected:** Each pod returns its own unique content, confirming that volumes are not shared between replicas.

### Verify Persistence After Pod Deletion

Delete a pod and verify its data survives:

```bash
# Delete web-1
kubectl delete pod web-1 -n lab03-$STUDENT_NAME

# Watch it get recreated with the same name
kubectl get pods -n lab03-$STUDENT_NAME -l app=web -w

# Once web-1 is Running again, verify data persisted
kubectl exec web-1 -n lab03-$STUDENT_NAME -- curl -s localhost
```

> ✅ **Success:** The recreated `web-1` pod still serves "Hello from web-1" because it reattached to the same PVC (`web-data-web-1`).

> ⚠️ **Common Mistake:** Do not confuse this with a Deployment. In a Deployment, the replacement pod gets a random name and may get a different volume. StatefulSets guarantee identity and storage affinity.

---

## Step 9: Scale the StatefulSet

### Scale Up

Scale from 3 to 5 replicas and observe ordered creation:

```bash
# Scale up to 5 replicas
kubectl scale statefulset web -n lab03-$STUDENT_NAME --replicas=5

# Watch the ordered scale-up
kubectl get pods -n lab03-$STUDENT_NAME -l app=web -w
```

> ✅ **Expected:** `web-3` is created first, then `web-4` after `web-3` is Running. New PVCs `web-data-web-3` and `web-data-web-4` are also created.

```bash
# Verify new PVCs were created
kubectl get pvc -n lab03-$STUDENT_NAME
```

### Scale Down

Scale down from 5 to 2 replicas and observe ordered termination:

```bash
# Scale down to 2 replicas
kubectl scale statefulset web -n lab03-$STUDENT_NAME --replicas=2

# Watch the ordered scale-down
kubectl get pods -n lab03-$STUDENT_NAME -l app=web -w
```

> ✅ **Expected:** Pods are removed in reverse order: `web-4` terminates first, then `web-3`, then `web-2`.

```bash
# Check PVCs - they persist even after scale-down!
kubectl get pvc -n lab03-$STUDENT_NAME
```

> ⚠️ **Important:** PVCs are **not** deleted when a StatefulSet scales down. This is by design — it protects data. The PVCs for `web-2`, `web-3`, and `web-4` still exist and will be reattached if you scale back up.

---

## Step 10: Test Volume Expansion

Check if the StorageClass supports volume expansion:

```bash
# Check if expansion is allowed
kubectl get storageclass gp2 -o jsonpath='{.allowVolumeExpansion}'
```

> 📝 **Note:** The StorageClass has been pre-configured by the instructor to allow volume expansion.

```bash
# Expand the PVC for web-0 from 1Gi to 2Gi
kubectl patch pvc web-data-web-0 -n lab03-$STUDENT_NAME \
  -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'

# Monitor the expansion
kubectl get pvc web-data-web-0 -n lab03-$STUDENT_NAME -w
```

> ✅ **Expected:** The PVC capacity will update to 2Gi. The underlying EBS volume is resized by the CSI driver.

> ⚠️ **Warning:** Volume expansion is a one-way operation. You cannot shrink a PVC after expanding it. Always verify the target size before applying.

---

## Step 11: Clean Up

Remove all resources created during this lab:

```bash
# Delete the StatefulSet first
kubectl delete statefulset web -n lab03-$STUDENT_NAME

# Delete remaining pods
kubectl delete pod data-reader -n lab03-$STUDENT_NAME --ignore-not-found

# Delete all PVCs in the namespace
kubectl delete pvc --all -n lab03-$STUDENT_NAME

# Delete the namespace (cleans up services and any remaining resources)
kubectl delete namespace lab03-$STUDENT_NAME

# Verify PVs are also deleted (due to Delete reclaim policy)
kubectl get pv
```

> 📝 **Note:** Deleting the PVCs triggers deletion of the underlying PersistentVolumes and their AWS EBS volumes because the reclaim policy is `Delete`. Always verify PV cleanup to avoid orphaned EBS volumes that incur cost.

---

## Lab 3 Summary

### Storage Concepts Reference

| Concept | What You Learned |
|---------|-----------------|
| `StorageClass` | Defines the provisioner, parameters, and reclaim policy for dynamic volumes |
| `PersistentVolumeClaim` | Requests storage; binds to a dynamically provisioned PV |
| `PersistentVolume` | The actual storage resource (EBS volume in AWS) |
| `StatefulSet` | Manages stateful pods with stable names, DNS, and per-replica storage |
| `volumeClaimTemplates` | Automatically creates a unique PVC for each StatefulSet replica |
| Volume Expansion | PVCs can be resized if the StorageClass allows it (one-way only) |

### StatefulSet vs Deployment

**StatefulSet Guarantees:**
- **Stable names and DNS** — `web-0`, `web-1` with predictable DNS
- **Ordered operations** — create/delete in sequence
- **Per-replica storage** — each pod gets its own PVC, retained on scale-down

**When to Use StatefulSets:**
- Databases (PostgreSQL, MySQL, MongoDB)
- Message queues and distributed caches (Kafka, Redis Cluster)
- Search engines (Elasticsearch)
- Any workload needing stable identity

> 💡 **Rule of Thumb:** If your application needs to know "who it is" or needs data to survive pod restarts, use a StatefulSet. If it is stateless and interchangeable, use a Deployment.

### Key Takeaways

- StorageClasses enable **dynamic provisioning** — no manual PV creation needed
- `WaitForFirstConsumer` ensures EBS volumes are created in the **correct availability zone**
- PVCs persist independently of pods — data survives pod deletion and rescheduling
- StatefulSets provide **stable network identity**, **ordered operations**, and **per-replica storage**
- PVCs are **retained on scale-down** to protect data
- Volume expansion is supported but is a **one-way operation**
