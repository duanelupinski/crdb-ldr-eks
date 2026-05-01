# steps to setup cockroachdb via the operator on aws eks, includes some workarounds for 
#  adding the storageclass ebs-gp3 and fixing the syntax of the certs to work with the 
#  default operator settings 
# see https://www.cockroachlabs.com/docs/v26.2/deploy-cockroachdb-with-kubernetes?filters=manual


# pre-req's
eksctl version
0.215.0

kubectl version
Client Version: v1.32.11
Kustomize Version: v5.5.0
Server Version: v1.32.13-eks-bbe087e

mkdir eks-ldr; cd eks-ldr

# create cluster 1
export AWS_PROFILE=CRLRevenue-337380398238
export AWS_REGION=us-east-1
export CLUSTER1=dlupinski-cockroach-east1
export REGION1=us-east-1

eksctl create cluster --name $CLUSTER1 --region $REGION1 --nodegroup-name standard-workers --node-type m5.xlarge --nodes 3 

# get context to reference
kubectl config get-contexts | grep $CLUSTER1
export CONTEXT1=duane.lupinski@cockroachlabs.com@dlupinski-cockroach-east1.us-east-1.eksctl.io

kubectl create namespace $REGION1 --context $CONTEXT1

# certs
mkdir certs1 my-safe-directory1
cockroach cert create-ca --certs-dir=certs1 --ca-key=my-safe-directory1/ca.key 
cockroach cert create-client root --certs-dir=certs1 --ca-key=my-safe-directory1/ca.key

kubectl create secret generic cockroachdb.client.root --from-file=certs1 --namespace $REGION1 --context=$CONTEXT1

cockroach cert create-node \
  localhost 127.0.0.1 cockroachdb-public "cockroachdb-public.$REGION1" \
  "cockroachdb-public.$REGION1.svc.cluster.local" "*.cockroachdb" \
  "*.cockroachdb.$REGION1" "*.cockroachdb.$REGION1.svc.cluster.local" \
  --certs-dir=certs1 \
  --ca-key=my-safe-directory1/ca.key

kubectl create secret generic cockroachdb.node --from-file=certs1 --namespace=$REGION1 --context=$CONTEXT1

kubectl get secrets --namespace $REGION1

# using the operator
kubectl apply -f https://raw.githubusercontent.com/cockroachdb/cockroach-operator/v2.18.3/install/crds.yaml -n "$REGION1" --context "$CONTEXT1"

# steps to resolve EBS CSI Driver
# pre-reqs
CLUSTER_NAME=<your-cluster-name>
REGION=us-east-1

# Get node group name
aws eks list-nodegroups \
  --cluster-name $CLUSTER_NAME \
  --region $REGION

# Get the node IAM role name
NODE_ROLE=$(aws eks describe-nodegroup \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name standard-workers \
  --region $REGION \
  --query "nodegroup.nodeRole" \
  --output text | cut -d'/' -f2)

echo "Node role: $NODE_ROLE"

# Attach the AWS-managed EBS CSI policy
aws iam attach-role-policy \
  --role-name $NODE_ROLE \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy

# Remove existing broken addon if present
eksctl delete addon \
  --name aws-ebs-csi-driver \
  --cluster $CLUSTER_NAME \
  --region $REGION

# Install fresh — no --service-account-role-arn (uses node instance profile)
eksctl create addon \
  --name aws-ebs-csi-driver \
  --cluster $CLUSTER_NAME \
  --region $REGION

cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-gp3
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
allowVolumeExpansion: true
EOF

# Set ebs-gp3 as default
kubectl patch storageclass ebs-gp3 \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Remove default from legacy gp2
kubectl patch storageclass gp2 \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'

# Verify
kubectl get storageclass
# Expected: ebs-gp3 (default)   ebs.csi.aws.com   WaitForFirstConsumer

# update crdbcluster yaml:
spec:
  dataStore:
    pvc:
      spec:
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: "60Gi"
        volumeMode: Filesystem
        storageClassName: ebs-gp3    # ← required

# fix tls secret names (used incorrect convention (see above) for deploying via operator)
# --- cockroachdb.node ---
kubectl get secret cockroachdb.node -n "$REGION1" -o json | jq -r '.data["node.crt"]' | base64 -d > /tmp/node.crt
kubectl get secret cockroachdb.node -n "$REGION1" -o json | jq -r '.data["node.key"]' | base64 -d > /tmp/node.key
kubectl get secret cockroachdb.node -n "$REGION1" -o json | jq -r '.data["ca.crt"]'   | base64 -d > /tmp/ca.crt

kubectl delete secret cockroachdb.node -n "$REGION1"
kubectl create secret generic cockroachdb.node \
  --from-file=tls.crt=/tmp/node.crt \
  --from-file=tls.key=/tmp/node.key \
  --from-file=ca.crt=/tmp/ca.crt \
  -n "$REGION1"

# --- cockroachdb.client.root ---
kubectl get secret cockroachdb.client.root -n "$REGION1" -o json | jq -r '.data["client.root.crt"]' | base64 -d > /tmp/client.root.crt
kubectl get secret cockroachdb.client.root -n "$REGION1" -o json | jq -r '.data["client.root.key"]' | base64 -d > /tmp/client.root.key
kubectl get secret cockroachdb.client.root -n "$REGION1" -o json | jq -r '.data["ca.crt"]'           | base64 -d > /tmp/client-ca.crt

kubectl delete secret cockroachdb.client.root -n "$REGION1"
kubectl create secret generic cockroachdb.client.root \
  --from-file=tls.crt=/tmp/client.root.crt \
  --from-file=tls.key=/tmp/client.root.key \
  --from-file=ca.crt=/tmp/client-ca.crt \
  -n "$REGION1"

# IF NEEDED - clean up and redeploy
# Delete stuck PVCs
kubectl delete pvc \
  datadir-cockroachdb-0 \
  datadir-cockroachdb-1 \
  datadir-cockroachdb-2 \
  -n "$REGION1"

# Delete StatefulSet (operator will recreate it)
kubectl delete statefulset cockroachdb -n "$REGION1"

# Apply updated CrdbCluster manifest
kubectl apply -f crdb-us-east-1.yaml -n "$REGION1"

# Watch everything come up
kubectl get pods -n "$REGION1" -w
kubectl get pvc  -n "$REGION1" -w
    
# Verify all pods are healthy (controller should show 6/6)
kubectl get pods -n kube-system | grep ebs-csi

# download and change the namespace references accordingly
curl -O https://raw.githubusercontent.com/cockroachdb/cockroach-operator/v2.18.3/install/operator.yaml

mv operator.yaml operator-us-east-1.yaml 

kubectl apply -f operator-us-east-1.yaml -n "$REGION1" --context "$CONTEXT1"

# confirm the operator pod is running via:
kubectl get pods -n "$REGION1" --context "$CONTEXT1"

# download example.yaml, rename and update, then create statefulset
curl -O https://raw.githubusercontent.com/cockroachdb/cockroach-operator/v2.18.3/examples/example.yaml

mv example crdb-us-east-1.yaml

kubectl apply -f crdb-us-east-1.yaml -n $REGION1 --context $CONTEXT1

# get built-in client - update keys accordingly
kubectl create -f https://raw.githubusercontent.com/cockroachdb/cockroach-operator/v2.18.3/examples/client-secure-operator.yaml

kubectl exec -it cockroachdb-client-secure -n $REGION1 --context $CONTEXT1 -- ./cockroach sql --certs-dir=/cockroach/cockroach-certs --host=cockroachdb-public