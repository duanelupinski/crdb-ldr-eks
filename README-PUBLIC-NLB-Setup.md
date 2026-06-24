# Public NLB Setup — Query CockroachDB on EKS from Your Mac

> Author: Duane Lupinski  
> Complements: `README-CockroachDB-EKS.md`, `README-CockroachDB-LDR-EKS.md`

This guide adds an **internet-facing Network Load Balancer (NLB)** so you can connect to CockroachDB from your MacBook over the public internet.

**Important:** This creates a **separate** service (`cockroachdb-public-lb`). Do **not** modify the internal `cockroachdb-ldr` service used for Logical Data Replication (LDR) across VPCs.

---

## Overview

```
MacBook (your public IP /32)
        │
        ▼
Public NLB (internet-facing)  ← cockroachdb-public-lb
        │
        ▼
CockroachDB pods on EKS nodes

Internal NLB (cockroachdb-ldr) — unchanged, still used for LDR
```

You will:

1. Create a new public NLB Kubernetes service
2. Restrict inbound traffic to your Mac's public IP
3. Copy client TLS certs from the cluster to your Mac
4. Connect with `sslmode=verify-ca` (NLB hostname is not in node cert SANs by default)

Repeat per region if you want access to both east and west clusters.

---

## Phase 0 — Set environment variables

```bash
# Use a profile that exists on your machine (NOT the literal string "your-profile")
export AWS_PROFILE=CRLRevenue-337380398238   # adjust to your profile
export CLUSTER_EAST=dlupinski-cockroach-east1
export CLUSTER_WEST=dlupinski-cockroach-west2b   # adjust if different
export REGION1=us-east-1
export REGION2=us-west-2

export CONTEXT1=$(kubectl config get-contexts -o name | grep "$CLUSTER_EAST" | head -1)
export CONTEXT2=$(kubectl config get-contexts -o name | grep "$CLUSTER_WEST" | head -1)

echo "East context: $CONTEXT1"
echo "West context: $CONTEXT2"
```

Verify AWS credentials and cluster access:

```bash
aws sts get-caller-identity
aws eks list-clusters --region "$REGION1"
```

If you use SSO and get a token error:

```bash
aws sso login --profile "$AWS_PROFILE"
```

To list available profiles:

```bash
aws configure list-profiles
```

---

## Phase 1 — Get your Mac's public IP

The NLB must only accept traffic from your current public IP.

```bash
MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '\n')
echo "Your public IP: $MY_IP"
```

If your home IP changes, update the security group and Kubernetes service (see Phase 8).

---

## Phase 2 — Create a dedicated security group for the public NLB

Create an SG in the **same VPC as the EKS cluster**, allowing only your IP on SQL port 26257.

### East (`us-east-1`)

```bash
VPC_EAST=$(aws eks describe-cluster \
  --name "$CLUSTER_EAST" --region "$REGION1" \
  --query "cluster.resourcesVpcConfig.vpcId" --output text)

NLB_SG_EAST=$(aws ec2 create-security-group \
  --region "$REGION1" \
  --group-name "crdb-public-nlb-east" \
  --description "Public NLB access to CockroachDB east - restricted to admin IP" \
  --vpc-id "$VPC_EAST" \
  --query GroupId --output text)

aws ec2 authorize-security-group-ingress \
  --region "$REGION1" \
  --group-id "$NLB_SG_EAST" \
  --protocol tcp \
  --port 26257 \
  --cidr "${MY_IP}/32"

# Optional: DB Console UI
aws ec2 authorize-security-group-ingress \
  --region "$REGION1" \
  --group-id "$NLB_SG_EAST" \
  --protocol tcp \
  --port 8080 \
  --cidr "${MY_IP}/32"

echo "East NLB SG: $NLB_SG_EAST"
```

### West (`us-west-2`) — if you want west access too

```bash
VPC_WEST=$(aws eks describe-cluster \
  --name "$CLUSTER_WEST" --region "$REGION2" \
  --query "cluster.resourcesVpcConfig.vpcId" --output text)

NLB_SG_WEST=$(aws ec2 create-security-group \
  --region "$REGION2" \
  --group-name "crdb-public-nlb-west" \
  --description "Public NLB access to CockroachDB west - restricted to admin IP" \
  --vpc-id "$VPC_WEST" \
  --query GroupId --output text)

aws ec2 authorize-security-group-ingress \
  --region "$REGION2" \
  --group-id "$NLB_SG_WEST" \
  --protocol tcp \
  --port 26257 \
  --cidr "${MY_IP}/32"

aws ec2 authorize-security-group-ingress \
  --region "$REGION2" \
  --group-id "$NLB_SG_WEST" \
  --protocol tcp \
  --port 8080 \
  --cidr "${MY_IP}/32"

echo "West NLB SG: $NLB_SG_WEST"
```

---

## Phase 3 — Allow NLB → node traffic on cluster/node security groups

The NLB forwards to your CockroachDB pods/nodes. Those security groups must accept traffic **from the NLB security group**.

### East

```bash
SG_EAST=$(aws eks describe-cluster \
  --name "$CLUSTER_EAST" --region "$REGION1" \
  --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)

aws ec2 authorize-security-group-ingress \
  --region "$REGION1" \
  --group-id "$SG_EAST" \
  --protocol tcp \
  --port 26257 \
  --source-group "$NLB_SG_EAST"

aws ec2 authorize-security-group-ingress \
  --region "$REGION1" \
  --group-id "$SG_EAST" \
  --protocol tcp \
  --port 26258 \
  --source-group "$NLB_SG_EAST"

aws ec2 authorize-security-group-ingress \
  --region "$REGION1" \
  --group-id "$SG_EAST" \
  --protocol tcp \
  --port 8080 \
  --source-group "$NLB_SG_EAST"
```

Also check **node security groups** (eksctl often adds a separate one):

```bash
NODE_SG_EAST=$(aws ec2 describe-instances \
  --region "$REGION1" \
  --filters "Name=tag:eks:cluster-name,Values=$CLUSTER_EAST" \
  --query "Reservations[0].Instances[0].SecurityGroups[?GroupId!='$SG_EAST'].GroupId | [0]" \
  --output text)

echo "Node SG east: $NODE_SG_EAST"

if [ "$NODE_SG_EAST" != "None" ] && [ -n "$NODE_SG_EAST" ]; then
  aws ec2 authorize-security-group-ingress \
    --region "$REGION1" \
    --group-id "$NODE_SG_EAST" \
    --protocol tcp \
    --port 26257 \
    --source-group "$NLB_SG_EAST" 2>/dev/null || true

  aws ec2 authorize-security-group-ingress \
    --region "$REGION1" \
    --group-id "$NODE_SG_EAST" \
    --protocol tcp \
    --port 26258 \
    --source-group "$NLB_SG_EAST" 2>/dev/null || true
fi
```

### West

Repeat the same pattern for west with `$NLB_SG_WEST`, `$SG_WEST`, and `$CLUSTER_WEST`.

```bash
SG_WEST=$(aws eks describe-cluster \
  --name "$CLUSTER_WEST" --region "$REGION2" \
  --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)

aws ec2 authorize-security-group-ingress \
  --region "$REGION2" \
  --group-id "$SG_WEST" \
  --protocol tcp \
  --port 26257 \
  --source-group "$NLB_SG_WEST"

aws ec2 authorize-security-group-ingress \
  --region "$REGION2" \
  --group-id "$SG_WEST" \
  --protocol tcp \
  --port 26258 \
  --source-group "$NLB_SG_WEST"

aws ec2 authorize-security-group-ingress \
  --region "$REGION2" \
  --group-id "$SG_WEST" \
  --protocol tcp \
  --port 8080 \
  --source-group "$NLB_SG_WEST"

NODE_SG_WEST=$(aws ec2 describe-instances \
  --region "$REGION2" \
  --filters "Name=tag:eks:cluster-name,Values=$CLUSTER_WEST" \
  --query "Reservations[0].Instances[0].SecurityGroups[?GroupId!='$SG_WEST'].GroupId | [0]" \
  --output text)

if [ "$NODE_SG_WEST" != "None" ] && [ -n "$NODE_SG_WEST" ]; then
  aws ec2 authorize-security-group-ingress \
    --region "$REGION2" \
    --group-id "$NODE_SG_WEST" \
    --protocol tcp \
    --port 26257 \
    --source-group "$NLB_SG_WEST" 2>/dev/null || true

  aws ec2 authorize-security-group-ingress \
    --region "$REGION2" \
    --group-id "$NODE_SG_WEST" \
    --protocol tcp \
    --port 26258 \
    --source-group "$NLB_SG_WEST" 2>/dev/null || true
fi
```

---

## Phase 4 — Create the public NLB Kubernetes service

**Do not modify** `cockroachdb-ldr`. Create a new service:

### East

```bash
cat <<EOF | kubectl apply -f - -n "$REGION1" --context "$CONTEXT1"
apiVersion: v1
kind: Service
metadata:
  name: cockroachdb-public-lb
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    service.beta.kubernetes.io/aws-load-balancer-security-groups: "$NLB_SG_EAST"
    service.beta.kubernetes.io/aws-load-balancer-manage-backend-security-group-rules: "true"
spec:
  type: LoadBalancer
  loadBalancerSourceRanges:
    - "${MY_IP}/32"
  selector:
    app.kubernetes.io/name: cockroachdb
    app.kubernetes.io/instance: cockroachdb
  ports:
    - name: sql
      port: 26257
      targetPort: 26257
    - name: http
      port: 8080
      targetPort: 8080
EOF
```

### West (optional)

```bash
cat <<EOF | kubectl apply -f - -n "$REGION2" --context "$CONTEXT2"
apiVersion: v1
kind: Service
metadata:
  name: cockroachdb-public-lb
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    service.beta.kubernetes.io/aws-load-balancer-security-groups: "$NLB_SG_WEST"
    service.beta.kubernetes.io/aws-load-balancer-manage-backend-security-group-rules: "true"
spec:
  type: LoadBalancer
  loadBalancerSourceRanges:
    - "${MY_IP}/32"
  selector:
    app.kubernetes.io/name: cockroachdb
    app.kubernetes.io/instance: cockroachdb
  ports:
    - name: sql
      port: 26257
      targetPort: 26257
    - name: http
      port: 8080
      targetPort: 8080
EOF
```

Notes:

- **`internet-facing`** and no `aws-load-balancer-internal: "true"` → public NLB
- **`loadBalancerSourceRanges`** adds IP restriction at the Kubernetes level
- **`manage-backend-security-group-rules`** auto-adds node SG rules in many EKS setups; Phase 3 is a manual fallback if needed
- Same pod selector as the internal LDR service

Wait for the NLB to provision (~2–3 minutes):

```bash
kubectl get svc cockroachdb-public-lb -n "$REGION1" --context "$CONTEXT1" -w
```

---

## Phase 5 — Get the public NLB hostname

```bash
EAST_PUBLIC_LB=$(kubectl get svc cockroachdb-public-lb \
  -n "$REGION1" --context "$CONTEXT1" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "East public NLB: $EAST_PUBLIC_LB"

# West (if created)
WEST_PUBLIC_LB=$(kubectl get svc cockroachdb-public-lb \
  -n "$REGION2" --context "$CONTEXT2" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "West public NLB: $WEST_PUBLIC_LB"
```

Verify it resolves to **public** IPs (not `192.168.x.x` or `10.x.x.x`):

```bash
dig +short "$EAST_PUBLIC_LB"
```

Test TCP from your Mac:

```bash
nc -zv "$EAST_PUBLIC_LB" 26257
```

Expected: `Connection to ... port 26257 [tcp/*] succeeded!`

If `nc` fails, see Troubleshooting before continuing.

---

## Phase 6 — Copy client TLS certs to your Mac

### East

```bash
mkdir -p ~/crdb-certs-east

kubectl get secret cockroachdb.client.root -n "$REGION1" --context "$CONTEXT1" \
  -o json | jq -r '.data["tls.crt"] // .data["client.root.crt"]' | base64 -d \
  > ~/crdb-certs-east/client.root.crt

kubectl get secret cockroachdb.client.root -n "$REGION1" --context "$CONTEXT1" \
  -o json | jq -r '.data["tls.key"] // .data["client.root.key"]' | base64 -d \
  > ~/crdb-certs-east/client.root.key

kubectl get secret cockroachdb.client.root -n "$REGION1" --context "$CONTEXT1" \
  -o json | jq -r '.data["ca.crt"]' | base64 -d \
  > ~/crdb-certs-east/ca.crt

chmod 600 ~/crdb-certs-east/client.root.key
```

### West (if needed)

```bash
mkdir -p ~/crdb-certs-west

kubectl get secret cockroachdb.client.root -n "$REGION2" --context "$CONTEXT2" \
  -o json | jq -r '.data["tls.crt"] // .data["client.root.crt"]' | base64 -d \
  > ~/crdb-certs-west/client.root.crt

kubectl get secret cockroachdb.client.root -n "$REGION2" --context "$CONTEXT2" \
  -o json | jq -r '.data["tls.key"] // .data["client.root.key"]' | base64 -d \
  > ~/crdb-certs-west/client.root.key

kubectl get secret cockroachdb.client.root -n "$REGION2" --context "$CONTEXT2" \
  -o json | jq -r '.data["ca.crt"]' | base64 -d \
  > ~/crdb-certs-west/ca.crt

chmod 600 ~/crdb-certs-west/client.root.key
```

Install the CockroachDB CLI if needed:

```bash
brew install cockroachdb/tap/cockroach
```

---

## Phase 7 — Connect from your Mac

Node certs were created with cluster-internal SANs (not the NLB hostname). Use **`sslmode=verify-ca`**, same as cross-cluster LDR connectivity in `README-CockroachDB-LDR-EKS.md`.

### East

```bash
cockroach sql \
  --url="postgresql://root@${EAST_PUBLIC_LB}:26257/defaultdb?sslmode=verify-ca&sslrootcert=${HOME}/crdb-certs-east/ca.crt&sslcert=${HOME}/crdb-certs-east/client.root.crt&sslkey=${HOME}/crdb-certs-east/client.root.key" \
  -e "SELECT 'connected from macbook via public nlb' AS status;"
```

### West

```bash
cockroach sql \
  --url="postgresql://root@${WEST_PUBLIC_LB}:26257/defaultdb?sslmode=verify-ca&sslrootcert=${HOME}/crdb-certs-west/ca.crt&sslcert=${HOME}/crdb-certs-west/client.root.crt&sslkey=${HOME}/crdb-certs-west/client.root.key" \
  -e "SELECT 'west cluster OK' AS status;"
```

### DB Console (optional)

Open in a browser:

```
https://${EAST_PUBLIC_LB}:8080
```

You may need to accept a certificate warning in the browser.

---

## Phase 8 — Update your IP when it changes

If your ISP assigns a new public IP, connections will stop until you update rules.

```bash
MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '\n')

# Add new rule (revoke the old /32 rule in the AWS console or by rule ID)
aws ec2 authorize-security-group-ingress \
  --region "$REGION1" \
  --group-id "$NLB_SG_EAST" \
  --protocol tcp \
  --port 26257 \
  --cidr "${MY_IP}/32"

# Update the Kubernetes service source range
kubectl patch svc cockroachdb-public-lb -n "$REGION1" --context "$CONTEXT1" \
  --type='json' \
  -p="[{\"op\": \"replace\", \"path\": \"/spec/loadBalancerSourceRanges\", \"value\": [\"${MY_IP}/32\"]}]"
```

Repeat for port 8080 and west region if applicable.

---

## Phase 9 (Optional) — Use `verify-full` by adding NLB hostname to node certs

For stricter TLS hostname verification, regenerate node certs **with the public NLB DNS name** and roll pods. Optional — `verify-ca` works for a restricted admin endpoint.

```bash
# From the directory where you still have ca.key from initial cluster setup
cd ~/path-to/my-safe-directory1

cockroach cert create-node \
  localhost 127.0.0.1 \
  cockroachdb-public "cockroachdb-public.$REGION1" \
  "cockroachdb-public.$REGION1.svc.cluster.local" \
  "*.cockroachdb" "*.cockroachdb.$REGION1" \
  "*.cockroachdb.$REGION1.svc.cluster.local" \
  "$EAST_PUBLIC_LB" \
  --certs-dir=/tmp/certs-regen \
  --ca-key=ca.key \
  --overwrite

kubectl get secret cockroachdb.node -n "$REGION1" --context "$CONTEXT1" \
  -o json | jq -r '.data["ca.crt"]' | base64 -d > /tmp/ca.crt

kubectl delete secret cockroachdb.node -n "$REGION1" --context "$CONTEXT1"
kubectl create secret generic cockroachdb.node \
  --from-file=tls.crt=/tmp/certs-regen/node.crt \
  --from-file=tls.key=/tmp/certs-regen/node.key \
  --from-file=ca.crt=/tmp/ca.crt \
  -n "$REGION1" --context "$CONTEXT1"

kubectl delete pods cockroachdb-0 cockroachdb-1 cockroachdb-2 \
  -n "$REGION1" --context "$CONTEXT1"
```

Then connect with `sslmode=verify-full` instead of `verify-ca`.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `The config profile (your-profile) could not be found` | Placeholder `AWS_PROFILE` | Set `AWS_PROFILE` to a real profile from `aws configure list-profiles` |
| `nc` times out | SG not allowing your IP | Re-run Phase 1; confirm `${MY_IP}/32` on NLB SG |
| `nc` works from wrong IP | SG too permissive | Audit NLB SG inbound rules; remove `0.0.0.0/0` if present |
| TLS handshake fails | Wrong client certs | Re-extract from `cockroachdb.client.root` secret |
| `x509: certificate is valid for ... not <NLB>` | NLB hostname not in node cert SANs | Use `verify-ca`, or complete Phase 9 |
| Service stuck `<pending>` | Subnet/tagging/IAM issue | `kubectl describe svc cockroachdb-public-lb -n $REGION1 --context $CONTEXT1` |
| Connection drops on long queries | NLB idle timeout | Increase idle timeout (see below) |
| LDR breaks after changes | Modified `cockroachdb-ldr` | Restore internal service; public LB must stay separate |

### Increase NLB idle timeout (long-running queries)

```bash
EAST_PUB_NLB_ARN=$(aws elbv2 describe-load-balancers \
  --region "$REGION1" \
  --query "LoadBalancers[?contains(DNSName,'$(echo $EAST_PUBLIC_LB | cut -d'.' -f1)')].LoadBalancerArn" \
  --output text)

aws elbv2 modify-load-balancer-attributes \
  --load-balancer-arn "$EAST_PUB_NLB_ARN" \
  --region "$REGION1" \
  --attributes \
    Key=load_balancing.cross_zone.enabled,Value=true \
    Key=idle_timeout.timeout_seconds,Value=3600
```

---

## Security reminders

- You are exposing **SQL (26257)** to the internet, even if IP-restricted. Treat this as an **admin/dev endpoint**, not a production application connection path.
- Keep **`cockroachdb-ldr` internal** for LDR — do not make that service public.
- Remove the public NLB when not in use:

```bash
kubectl delete svc cockroachdb-public-lb -n "$REGION1" --context "$CONTEXT1"
aws ec2 delete-security-group --group-id "$NLB_SG_EAST" --region "$REGION1"
```

---

## Daily workflow

1. Confirm your public IP has not changed: `curl -s https://checkip.amazonaws.com`
2. Run `cockroach sql` against `$EAST_PUBLIC_LB` (or west)
3. Optionally open `https://$EAST_PUBLIC_LB:8080` for the DB Console
