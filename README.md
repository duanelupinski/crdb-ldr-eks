# CockroachDB on AWS EKS with Operator

This repository contains steps to deploy CockroachDB using the Cockroach Operator on AWS EKS. It also includes workarounds for adding the `ebs-gp3` StorageClass and fixing secret/tls syntax for the operator.

> Based on CockroachDB docs: https://www.cockroachlabs.com/docs/v26.2/deploy-cockroachdb-with-kubernetes?filters=manual

## Prerequisites

Verify your tools:

```bash
eksctl version
kubectl version
```

Example versions:

```text
Client Version: v1.32.11
Kustomize Version: v5.5.0
Server Version: v1.32.13-eks-bbe087e
```

Create a working directory:

```bash
mkdir eks-ldr
cd eks-ldr
```

## Create cluster

```bash
export AWS_PROFILE=CRLRevenue-337380398238
export AWS_REGION=us-east-1
export CLUSTER1=dlupinski-cockroach-east1
export REGION1=us-east-1

eksctl create cluster \
  --name "$CLUSTER1" \
  --region "$REGION1" \
  --nodegroup-name standard-workers \
  --node-type m5.xlarge \
  --nodes 3
```

Get cluster context and namespace:

```bash
kubectl config get-contexts | grep "$CLUSTER1"
export CONTEXT1=duane.lupinski@cockroachlabs.com@dlupinski-cockroach-east1.us-east-1.eksctl.io

kubectl create namespace "$REGION1" --context "$CONTEXT1"
```

## Generate certificates

```bash
mkdir certs1 my-safe-directory1
cockroach cert create-ca --certs-dir=certs1 --ca-key=my-safe-directory1/ca.key
cockroach cert create-client root --certs-dir=certs1 --ca-key=my-safe-directory1/ca.key

kubectl create secret generic cockroachdb.client.root \
  --from-file=certs1 \
  --namespace "$REGION1" \
  --context "$CONTEXT1"

cockroach cert create-node \
  localhost 127.0.0.1 cockroachdb-public "cockroachdb-public.$REGION1" \
  "cockroachdb-public.$REGION1.svc.cluster.local" "*.cockroachdb" \
  "*.cockroachdb.$REGION1" "*.cockroachdb.$REGION1.svc.cluster.local" \
  --certs-dir=certs1 \
  --ca-key=my-safe-directory1/ca.key

kubectl create secret generic cockroachdb.node \
  --from-file=certs1 \
  --namespace "$REGION1" \
  --context "$CONTEXT1"

kubectl get secrets --namespace "$REGION1" --context "$CONTEXT1"
```

## Install the Cockroach Operator

```bash
kubectl apply -f https://raw.githubusercontent.com/cockroachdb/cockroach-operator/v2.18.3/install/crds.yaml \
  -n "$REGION1" --context "$CONTEXT1"
```

## Resolve EBS CSI Driver issues

Set variables for your cluster:

```bash
CLUSTER_NAME=<your-cluster-name>
REGION=us-east-1
```

Get the nodegroup name:

```bash
aws eks list-nodegroups \
  --cluster-name "$CLUSTER_NAME" \
  --region "$REGION"
```

Get the node IAM role:

```bash
NODE_ROLE=$(aws eks describe-nodegroup \
  --cluster-name "$CLUSTER_NAME" \
  --nodegroup-name standard-workers \
  --region "$REGION" \
  --query "nodegroup.nodeRole" \
  --output text | cut -d'/' -f2)

echo "Node role: $NODE_ROLE"
```

Attach the AWS-managed EBS CSI policy:

```bash
aws iam attach-role-policy \
  --role-name "$NODE_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
```

Remove an existing broken addon (if present):

```bash
eksctl delete addon \
  --name aws-ebs-csi-driver \
  --cluster "$CLUSTER_NAME" \
  --region "$REGION"
```

Install the addon fresh:

```bash
eksctl create addon \
  --name aws-ebs-csi-driver \
  --cluster "$CLUSTER_NAME" \
  --region "$REGION"
```

Create the `ebs-gp3` StorageClass:

```bash
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
```

Set `ebs-gp3` as the default storage class:

```bash
kubectl patch storageclass ebs-gp3 \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

kubectl patch storageclass gp2 \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
```

Verify the storage classes:

```bash
kubectl get storageclass
```

Expected output includes `ebs-gp3 (default)`.

## Update CockroachDB cluster manifest

Ensure your `CrdbCluster` YAML uses `ebs-gp3`:

```yaml
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
        storageClassName: ebs-gp3
```

## Fix TLS secret naming for the operator

The operator expects `tls.crt`, `tls.key`, and `ca.crt` in secrets.

### Fix `cockroachdb.node`

```bash
kubectl get secret cockroachdb.node -n "$REGION1" --context "$CONTEXT1" -o json | jq -r '.data["node.crt"]' | base64 -d > /tmp/node.crt
kubectl get secret cockroachdb.node -n "$REGION1" --context "$CONTEXT1" -o json | jq -r '.data["node.key"]' | base64 -d > /tmp/node.key
kubectl get secret cockroachdb.node -n "$REGION1" --context "$CONTEXT1" -o json | jq -r '.data["ca.crt"]' | base64 -d > /tmp/ca.crt

kubectl delete secret cockroachdb.node -n "$REGION1" --context "$CONTEXT1"
kubectl create secret generic cockroachdb.node \
  --from-file=tls.crt=/tmp/node.crt \
  --from-file=tls.key=/tmp/node.key \
  --from-file=ca.crt=/tmp/ca.crt \
  -n "$REGION1" --context "$CONTEXT1"
```

### Fix `cockroachdb.client.root`

```bash
kubectl get secret cockroachdb.client.root -n "$REGION1" --context "$CONTEXT1" -o json | jq -r '.data["client.root.crt"]' | base64 -d > /tmp/client.root.crt
kubectl get secret cockroachdb.client.root -n "$REGION1" --context "$CONTEXT1" -o json | jq -r '.data["client.root.key"]' | base64 -d > /tmp/client.root.key
kubectl get secret cockroachdb.client.root -n "$REGION1" --context "$CONTEXT1" -o json | jq -r '.data["ca.crt"]' | base64 -d > /tmp/client-ca.crt

kubectl delete secret cockroachdb.client.root -n "$REGION1" --context "$CONTEXT1"
kubectl create secret generic cockroachdb.client.root \
  --from-file=tls.crt=/tmp/client.root.crt \
  --from-file=tls.key=/tmp/client.root.key \
  --from-file=ca.crt=/tmp/client-ca.crt \
  -n "$REGION1" --context "$CONTEXT1"
```

## Redeploy if needed

```bash
kubectl delete pvc \
  datadir-cockroachdb-0 \
  datadir-cockroachdb-1 \
  datadir-cockroachdb-2 \
  -n "$REGION1"

kubectl delete statefulset cockroachdb -n "$REGION1"
kubectl apply -f crdb-us-east-1.yaml -n "$REGION1"

kubectl get pods -n "$REGION1" -w
kubectl get pvc -n "$REGION1" -w
```

Verify EBS CSI components:

```bash
kubectl get pods -n kube-system | grep ebs-csi
```

## Install operator and example resources

```bash
curl -O https://raw.githubusercontent.com/cockroachdb/cockroach-operator/v2.18.3/install/operator.yaml
mv operator.yaml operator-us-east-1.yaml
kubectl apply -f operator-us-east-1.yaml -n "$REGION1" --context "$CONTEXT1"

curl -O https://raw.githubusercontent.com/cockroachdb/cockroach-operator/v2.18.3/examples/example.yaml
mv example.yaml crdb-us-east-1.yaml
kubectl apply -f crdb-us-east-1.yaml -n "$REGION1" --context "$CONTEXT1"

curl https://raw.githubusercontent.com/cockroachdb/cockroach-operator/v2.18.3/examples/client-secure-operator.yaml > client-secure-operator.yaml
kubectl apply -f client-secure-operator.yaml -n "$REGION1" --context "$CONTEXT1"
```

Run the built-in client:

```bash
kubectl exec -it cockroachdb-client-secure -n "$REGION1" --context "$CONTEXT1" -- \
  ./cockroach sql --certs-dir=/cockroach/cockroach-certs --host=cockroachdb-public
```
