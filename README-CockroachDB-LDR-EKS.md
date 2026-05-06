# CockroachDB Logical Data Replication (LDR) on AWS EKS

> Author: Duane Lupinski (duane.lupinski@cockroachlabs.com)  
> Prepared with Mica  
> Version: CockroachDB v25.4.2 | CockroachDB Operator | AWS EKS

---

## Overview

This document describes the end-to-end process for setting up bi-directional Logical Data Replication (LDR) between two CockroachDB clusters deployed on AWS EKS in separate regions using the CockroachDB Kubernetes Operator.

**Architecture:**
- **East cluster:** `us-east-1` VPC CIDR `192.168.0.0/16`
- **West cluster:** `us-west-2` VPC CIDR `10.0.0.0/16`
- Both clusters connected via **VPC Peering**
- Cross-cluster traffic routed via **internal AWS NLB (Network Load Balancer)**
- LDR streams use `crdb_route=gateway` to ensure all traffic routes through the NLB gateway node

> ⚠️ **Prerequisites:**
> - Both EKS clusters deployed and all pods `1/1 Running`
> - Enterprise license available
> - TLS certs with correct SANs for each region
> - VPC CIDRs must NOT overlap (use VPC Peering) or use AWS Transit Gateway
> - `kv.rangefeed.enabled = true` on both clusters
> - `GRANT SYSTEM REPLICATION TO root` on both clusters

---

## Environment Variables

Set these before running any commands:

```bash
# East cluster
CLUSTER_EAST=<east-cluster-name>        # e.g. dlupinski-cockroach-east1
REGION1=us-east-1
CONTEXT1=<east-kube-context>

# West cluster
CLUSTER_WEST=<west-cluster-name>        # e.g. dlupinski-cockroach-west2
REGION2=us-west-2
CONTEXT2=<west-kube-context>
```

---

## Phase 1 — VPC Networking

### Step 1.1 — Get VPC and CIDR Information

```bash
VPC_EAST=$(aws eks describe-cluster \
  --name $CLUSTER_EAST --region us-east-1 \
  --query "cluster.resourcesVpcConfig.vpcId" --output text)

VPC_WEST=$(aws eks describe-cluster \
  --name $CLUSTER_WEST --region us-west-2 \
  --query "cluster.resourcesVpcConfig.vpcId" --output text)

CIDR_EAST=$(aws ec2 describe-vpcs --vpc-ids $VPC_EAST \
  --region us-east-1 \
  --query "Vpcs[0].CidrBlock" --output text)

CIDR_WEST=$(aws ec2 describe-vpcs --vpc-ids $VPC_WEST \
  --region us-west-2 \
  --query "Vpcs[0].CidrBlock" --output text)

echo "East VPC: $VPC_EAST  CIDR: $CIDR_EAST"
echo "West VPC: $VPC_WEST  CIDR: $CIDR_WEST"
```

> ⚠️ **CIDRs must not overlap.** If they do, VPC Peering will not work. Rebuild the cluster with a different CIDR before proceeding.

### Step 1.2 — Verify or Create VPC Peering

```bash
# Check if peering already exists
aws ec2 describe-vpc-peering-connections \
  --region us-east-1 \
  --query "VpcPeeringConnections[*].{ID:VpcPeeringConnectionId,Status:Status.Code,Requester:RequesterVpcInfo.CidrBlock,Accepter:AccepterVpcInfo.CidrBlock}" \
  --output table
```

If peering doesn't exist between your two VPC CIDRs, create it:

```bash
PEERING_ID=$(aws ec2 create-vpc-peering-connection \
  --vpc-id $VPC_EAST \
  --peer-vpc-id $VPC_WEST \
  --peer-region us-west-2 \
  --region us-east-1 \
  --query "VpcPeeringConnection.VpcPeeringConnectionId" \
  --output text)

echo "Peering ID: $PEERING_ID"

# Accept from west side
aws ec2 accept-vpc-peering-connection \
  --vpc-peering-connection-id $PEERING_ID \
  --region us-west-2

# Verify active
aws ec2 describe-vpc-peering-connections \
  --vpc-peering-connection-ids $PEERING_ID \
  --region us-east-1 \
  --query "VpcPeeringConnections[0].Status.Code" \
  --output text
# Expected: active
```

> **If peering already exists**, set `PEERING_ID` manually from the describe output above.

### Step 1.3 — Update Route Tables on Both VPCs

> ⚠️ EKS creates multiple subnets across AZs — each has its own route table. You must add the peering route to ALL route tables in each VPC, not just one.

```bash
# Get ALL route table IDs for each VPC
RTB_EAST=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_EAST" \
  --region us-east-1 \
  --query "RouteTables[*].RouteTableId" \
  --output text)

RTB_WEST=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_WEST" \
  --region us-west-2 \
  --query "RouteTables[*].RouteTableId" \
  --output text)

# Add/replace west route in all east route tables
for RTB in $RTB_EAST; do
  echo "Updating east route table $RTB..."
  aws ec2 replace-route \
    --route-table-id $RTB \
    --destination-cidr-block $CIDR_WEST \
    --vpc-peering-connection-id $PEERING_ID \
    --region us-east-1 2>/dev/null || \
  aws ec2 create-route \
    --route-table-id $RTB \
    --destination-cidr-block $CIDR_WEST \
    --vpc-peering-connection-id $PEERING_ID \
    --region us-east-1 2>/dev/null || \
  echo "  Skipped $RTB"
done

# Add/replace east route in all west route tables
for RTB in $RTB_WEST; do
  echo "Updating west route table $RTB..."
  aws ec2 replace-route \
    --route-table-id $RTB \
    --destination-cidr-block $CIDR_EAST \
    --vpc-peering-connection-id $PEERING_ID \
    --region us-west-2 2>/dev/null || \
  aws ec2 create-route \
    --route-table-id $RTB \
    --destination-cidr-block $CIDR_EAST \
    --vpc-peering-connection-id $PEERING_ID \
    --region us-west-2 2>/dev/null || \
  echo "  Skipped $RTB"
done
```

Verify routes are present on ALL route tables:

```bash
# East — all route tables should show 10.0.0.0/16 (or your west CIDR)
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_EAST" \
  --region us-east-1 \
  --query "RouteTables[*].{RTBID:RouteTableId,Routes:Routes[?DestinationCidrBlock=='$CIDR_WEST']}" \
  --output table

# West — all route tables should show 192.168.0.0/16 (or your east CIDR)
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_WEST" \
  --region us-west-2 \
  --query "RouteTables[*].{RTBID:RouteTableId,Routes:Routes[?DestinationCidrBlock=='$CIDR_EAST']}" \
  --output table
```

### Step 1.4 — Update Security Groups

```bash
SG_EAST=$(aws eks describe-cluster \
  --name $CLUSTER_EAST --region us-east-1 \
  --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)

SG_WEST=$(aws eks describe-cluster \
  --name $CLUSTER_WEST --region us-west-2 \
  --query "cluster.resourcesVpcConfig.clusterSecurityGroupId" --output text)

# Allow west → east on SQL (26257) and internal gRPC (26258)
aws ec2 authorize-security-group-ingress \
  --group-id $SG_EAST --protocol tcp --port 26257 \
  --cidr $CIDR_WEST --region us-east-1

aws ec2 authorize-security-group-ingress \
  --group-id $SG_EAST --protocol tcp --port 26258 \
  --cidr $CIDR_WEST --region us-east-1

# Allow east → west on SQL (26257) and internal gRPC (26258)
aws ec2 authorize-security-group-ingress \
  --group-id $SG_WEST --protocol tcp --port 26257 \
  --cidr $CIDR_EAST --region us-west-2

aws ec2 authorize-security-group-ingress \
  --group-id $SG_WEST --protocol tcp --port 26258 \
  --cidr $CIDR_EAST --region us-west-2
```

---

## Phase 2 — Internal Load Balancer Setup

LDR requires a stable, routable endpoint for each cluster. Internal NLBs provide this across VPC peering. ClusterIP and headless services are NOT routable across VPCs.

### Step 2.1 — Create Internal NLB Service on East

```bash
cat <<EOF | kubectl apply -f - -n "$REGION1" --context "$CONTEXT1"
apiVersion: v1
kind: Service
metadata:
  name: cockroachdb-ldr
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-internal: "true"
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: cockroachdb
    app.kubernetes.io/instance: cockroachdb
  ports:
    - name: sql
      port: 26257
      targetPort: 26257
    - name: grpc
      port: 26258
      targetPort: 26258
EOF
```

### Step 2.2 — Create Internal NLB Service on West

```bash
cat <<EOF | kubectl apply -f - -n "$REGION2" --context "$CONTEXT2"
apiVersion: v1
kind: Service
metadata:
  name: cockroachdb-ldr
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-internal: "true"
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: cockroachdb
    app.kubernetes.io/instance: cockroachdb
  ports:
    - name: sql
      port: 26257
      targetPort: 26257
    - name: grpc
      port: 26258
      targetPort: 26258
EOF
```

### Step 2.3 — Get NLB Hostnames (wait ~2-3 min for provisioning)

```bash
EAST_LB=$(kubectl get svc cockroachdb-ldr \
  -n "$REGION1" --context "$CONTEXT1" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

WEST_LB=$(kubectl get svc cockroachdb-ldr \
  -n "$REGION2" --context "$CONTEXT2" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "East LB: $EAST_LB"
echo "West LB: $WEST_LB"
```

### Step 2.4 — Increase NLB Idle Timeout

LDR uses long-lived rangefeed connections. The default NLB idle timeout (350s) will silently drop idle streams. Increase to 3600s:

```bash
EAST_NLB_ARN=$(aws elbv2 describe-load-balancers \
  --region us-east-1 \
  --query "LoadBalancers[?contains(DNSName,'$(echo $EAST_LB | cut -c1-8)')].LoadBalancerArn" \
  --output text)

WEST_NLB_ARN=$(aws elbv2 describe-load-balancers \
  --region us-west-2 \
  --query "LoadBalancers[?contains(DNSName,'$(echo $WEST_LB | cut -c1-8)')].LoadBalancerArn" \
  --output text)

aws elbv2 modify-load-balancer-attributes \
  --load-balancer-arn $EAST_NLB_ARN \
  --region us-east-1 \
  --attributes \
    Key=load_balancing.cross_zone.enabled,Value=true \
    Key=idle_timeout.timeout_seconds,Value=3600

aws elbv2 modify-load-balancer-attributes \
  --load-balancer-arn $WEST_NLB_ARN \
  --region us-west-2 \
  --attributes \
    Key=load_balancing.cross_zone.enabled,Value=true \
    Key=idle_timeout.timeout_seconds,Value=3600
```

### Step 2.5 — Verify Cross-Cluster TCP Connectivity

```bash
# From east pod → west NLB
kubectl exec -it cockroachdb-0 \
  -n "$REGION1" --context "$CONTEXT1" \
  -- bash -c "
    timeout 5 bash -c 'cat /dev/null > /dev/tcp/${WEST_LB}/26257' \
    && echo 'Port 26257: OK' || echo 'Port 26257: FAILED'
    timeout 5 bash -c 'cat /dev/null > /dev/tcp/${WEST_LB}/26258' \
    && echo 'Port 26258: OK' || echo 'Port 26258: FAILED'
  "

# From west pod → east NLB
kubectl exec -it cockroachdb-0 \
  -n "$REGION2" --context "$CONTEXT2" \
  -- bash -c "
    timeout 5 bash -c 'cat /dev/null > /dev/tcp/${EAST_LB}/26257' \
    && echo 'Port 26257: OK' || echo 'Port 26257: FAILED'
    timeout 5 bash -c 'cat /dev/null > /dev/tcp/${EAST_LB}/26258' \
    && echo 'Port 26258: OK' || echo 'Port 26258: FAILED'
  "
```

Both ports should return `OK` in both directions before proceeding.

---

## Phase 3 — TLS Certificate Setup (Cross-Cluster Trust)

If each cluster was provisioned with its own CA, they won't trust each other's certificates. A combined CA bundle must be created and deployed to both clusters.

### Step 3.1 — Extract Both CA Certs

```bash
kubectl get secret cockroachdb.node \
  -n "$REGION1" --context "$CONTEXT1" \
  -o json | jq -r '.data["ca.crt"]' | base64 -d > /tmp/ca-east.crt

kubectl get secret cockroachdb.node \
  -n "$REGION2" --context "$CONTEXT2" \
  -o json | jq -r '.data["ca.crt"]' | base64 -d > /tmp/ca-west.crt

# Verify they are different
diff /tmp/ca-east.crt /tmp/ca-west.crt
# If output is empty, CAs are identical — skip to Step 3.3
```

### Step 3.2 — Create Combined CA Bundle

```bash
cat /tmp/ca-east.crt /tmp/ca-west.crt > /tmp/ca-bundle.crt

# Verify contains 2 certificates
grep -c "BEGIN CERTIFICATE" /tmp/ca-bundle.crt
# Should return: 2
```

### Step 3.3 — Update Secrets on East

```bash
# Extract current node cert (keep as-is, only ca.crt changes)
kubectl get secret cockroachdb.node \
  -n "$REGION1" --context "$CONTEXT1" \
  -o json | jq -r '.data["tls.crt"] // .data["node.crt"]' | base64 -d > /tmp/east-node.crt
kubectl get secret cockroachdb.node \
  -n "$REGION1" --context "$CONTEXT1" \
  -o json | jq -r '.data["tls.key"] // .data["node.key"]' | base64 -d > /tmp/east-node.key

# Recreate with combined CA
kubectl delete secret cockroachdb.node -n "$REGION1" --context "$CONTEXT1"
kubectl create secret generic cockroachdb.node \
  --from-file=tls.crt=/tmp/east-node.crt \
  --from-file=tls.key=/tmp/east-node.key \
  --from-file=ca.crt=/tmp/ca-bundle.crt \
  -n "$REGION1" --context "$CONTEXT1"

# Extract client cert
kubectl get secret cockroachdb.client.root \
  -n "$REGION1" --context "$CONTEXT1" \
  -o json | jq -r '.data["tls.crt"] // .data["client.root.crt"]' | base64 -d > /tmp/east-client.crt
kubectl get secret cockroachdb.client.root \
  -n "$REGION1" --context "$CONTEXT1" \
  -o json | jq -r '.data["tls.key"] // .data["client.root.key"]' | base64 -d > /tmp/east-client.key

# Recreate with combined CA
kubectl delete secret cockroachdb.client.root -n "$REGION1" --context "$CONTEXT1"
kubectl create secret generic cockroachdb.client.root \
  --from-file=tls.crt=/tmp/east-client.crt \
  --from-file=tls.key=/tmp/east-client.key \
  --from-file=ca.crt=/tmp/ca-bundle.crt \
  -n "$REGION1" --context "$CONTEXT1"
```

### Step 3.4 — Update Secrets on West

```bash
kubectl get secret cockroachdb.node \
  -n "$REGION2" --context "$CONTEXT2" \
  -o json | jq -r '.data["tls.crt"] // .data["node.crt"]' | base64 -d > /tmp/west-node.crt
kubectl get secret cockroachdb.node \
  -n "$REGION2" --context "$CONTEXT2" \
  -o json | jq -r '.data["tls.key"] // .data["node.key"]' | base64 -d > /tmp/west-node.key

kubectl delete secret cockroachdb.node -n "$REGION2" --context "$CONTEXT2"
kubectl create secret generic cockroachdb.node \
  --from-file=tls.crt=/tmp/west-node.crt \
  --from-file=tls.key=/tmp/west-node.key \
  --from-file=ca.crt=/tmp/ca-bundle.crt \
  -n "$REGION2" --context "$CONTEXT2"

kubectl get secret cockroachdb.client.root \
  -n "$REGION2" --context "$CONTEXT2" \
  -o json | jq -r '.data["tls.crt"] // .data["client.root.crt"]' | base64 -d > /tmp/west-client.crt
kubectl get secret cockroachdb.client.root \
  -n "$REGION2" --context "$CONTEXT2" \
  -o json | jq -r '.data["tls.key"] // .data["client.root.key"]' | base64 -d > /tmp/west-client.key

kubectl delete secret cockroachdb.client.root -n "$REGION2" --context "$CONTEXT2"
kubectl create secret generic cockroachdb.client.root \
  --from-file=tls.crt=/tmp/west-client.crt \
  --from-file=tls.key=/tmp/west-client.key \
  --from-file=ca.crt=/tmp/ca-bundle.crt \
  -n "$REGION2" --context "$CONTEXT2"
```

### Step 3.5 — Bounce Pods to Pick Up New Secrets

```bash
kubectl delete pods cockroachdb-0 cockroachdb-1 cockroachdb-2 \
  -n "$REGION1" --context "$CONTEXT1"
kubectl delete pods cockroachdb-0 cockroachdb-1 cockroachdb-2 \
  -n "$REGION2" --context "$CONTEXT2"

# Wait for all pods to return to 1/1 Running
kubectl get pods -n "$REGION1" --context "$CONTEXT1" -w
kubectl get pods -n "$REGION2" --context "$CONTEXT2" -w
```

### Step 3.6 — Verify Cross-Cluster SQL Connectivity

```bash
# East → West
kubectl exec -it cockroachdb-0 \
  -n "$REGION1" --context "$CONTEXT1" \
  -- /cockroach/cockroach sql \
  --certs-dir=/cockroach/cockroach-certs/ \
  --url="postgresql://root@${WEST_LB}:26257/defaultdb?sslmode=verify-ca&sslrootcert=/cockroach/cockroach-certs/ca.crt&sslcert=/cockroach/cockroach-certs/client.root.crt&sslkey=/cockroach/cockroach-certs/client.root.key" \
  -e "SELECT 'east->west OK';"

# West → East
kubectl exec -it cockroachdb-0 \
  -n "$REGION2" --context "$CONTEXT2" \
  -- /cockroach/cockroach sql \
  --certs-dir=/cockroach/cockroach-certs/ \
  --url="postgresql://root@${EAST_LB}:26257/defaultdb?sslmode=verify-ca&sslrootcert=/cockroach/cockroach-certs/ca.crt&sslcert=/cockroach/cockroach-certs/client.root.crt&sslkey=/cockroach/cockroach-certs/client.root.key" \
  -e "SELECT 'west->east OK';"
```

> **Note:** Using `sslmode=verify-ca` instead of `verify-full` because the NLB hostname is not in the node certificate SANs. This is acceptable for private VPC connectivity.

---

## Phase 4 — Log Configuration (REPLICATION Channel)

The CockroachDB Operator supports a `logConfigMap` field for log configuration. This avoids editing StatefulSets directly (which the operator will revert).

### Step 4.1 — Create Log ConfigMap on East

```bash
cat <<EOF | kubectl apply -f - -n "$REGION1" --context "$CONTEXT1"
apiVersion: v1
kind: ConfigMap
metadata:
  name: crdb-log-config
data:
  logs.yaml: |
    sinks:
      stderr:
        channels: [OPS, HEALTH, REPLICATION, DEV]
        redact: true
EOF
```

### Step 4.2 — Create Log ConfigMap on West

```bash
cat <<EOF | kubectl apply -f - -n "$REGION2" --context "$CONTEXT2"
apiVersion: v1
kind: ConfigMap
metadata:
  name: crdb-log-config
data:
  logs.yaml: |
    sinks:
      stderr:
        channels: [OPS, HEALTH, REPLICATION, DEV]
        redact: true
EOF
```

### Step 4.3 — Update CrdbCluster to Reference ConfigMap

Add `logConfigMap: crdb-log-config` to the spec of both CrdbCluster manifests:

```yaml
apiVersion: crdb.cockroachlabs.com/v1alpha1
kind: CrdbCluster
metadata:
  name: cockroachdb
spec:
  logConfigMap: crdb-log-config    # ← add this line
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
  ...
```

Apply to both clusters:

```bash
kubectl apply -f crdb-us-east-1.yaml -n "$REGION1" --context "$CONTEXT1"
kubectl apply -f crdb-us-west-2.yaml -n "$REGION2" --context "$CONTEXT2"
```

The operator will perform a rolling restart automatically. Once complete, validate replication logs:

```bash
# Should now show REPLICATION channel output
kubectl exec -it cockroachdb-0 \
  -n "$REGION1" --context "$CONTEXT1" \
  -- grep -i "replication\|logical\|LDR" \
  /cockroach/cockroach-data/logs/cockroach.log | tail -20
```

---

## Phase 5 — CockroachDB LDR Configuration

### Step 5.1 — Apply Enterprise License (Required)

LDR requires an Enterprise license. Apply to both clusters:

```sql
-- Run on BOTH clusters
SET CLUSTER SETTING cluster.organization = 'Cockroach Labs';
SET CLUSTER SETTING enterprise.license = '<your-license-key>';

-- Verify
SHOW CLUSTER SETTING enterprise.license;
-- Must return a non-empty value
```

### Step 5.2 — Enable Required Cluster Settings

```sql
-- Run on BOTH clusters
SET CLUSTER SETTING kv.rangefeed.enabled = true;
SET CLUSTER SETTING server.grpc.keepalive.time = '10s';
SET CLUSTER SETTING server.grpc.keepalive.timeout = '5s';
SET CLUSTER SETTING kv.closed_timestamp.target_duration = '1s';
SET CLUSTER SETTING kv.closed_timestamp.side_transport_interval = '200ms';
```

### Step 5.3 — Grant REPLICATION Privilege

```sql
-- Run on BOTH clusters
GRANT SYSTEM REPLICATION TO root;

-- Verify
SHOW SYSTEM GRANTS;
-- Should show: root | REPLICATION
```

### Step 5.4 — Create Target Database and Table

```sql
-- Run on BOTH clusters
CREATE DATABASE IF NOT EXISTS mydb;
USE mydb;

CREATE TABLE IF NOT EXISTS mytable (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  data TEXT,
  updated_at TIMESTAMPTZ DEFAULT now()
);
```

> **Note:** The table schema must be identical on both clusters.

### Step 5.5 — Create External Connections

> ⚠️ **Critical:** Include `&crdb_route=gateway` in the connection string.  
> Without it, CockroachDB will attempt to redirect rangefeed traffic to internal pod addresses  
> (`cockroachdb-0.cockroachdb.us-west-2`) which are not reachable across VPCs.  
> The job will show `running` but `high_water_timestamp` will remain `NULL` indefinitely.

```sql
-- On EAST — pointing to WEST
CREATE EXTERNAL CONNECTION west_cluster AS
  'postgresql://root@<WEST_LB>:26257/mydb?sslmode=verify-ca&sslrootcert=/cockroach/cockroach-certs/ca.crt&sslcert=/cockroach/cockroach-certs/client.root.crt&sslkey=/cockroach/cockroach-certs/client.root.key&crdb_route=gateway';

-- On WEST — pointing to EAST
CREATE EXTERNAL CONNECTION east_cluster AS
  'postgresql://root@<EAST_LB>:26257/mydb?sslmode=verify-ca&sslrootcert=/cockroach/cockroach-certs/ca.crt&sslcert=/cockroach/cockroach-certs/client.root.crt&sslkey=/cockroach/cockroach-certs/client.root.key&crdb_route=gateway';
```

Verify external connections:

```sql
-- On BOTH clusters
SHOW EXTERNAL CONNECTIONS;
```

### Step 5.6 — Create LDR Streams

> ⚠️ **Order matters.** Create the east stream first and wait for it to show `running` before creating the west stream.

**On EAST first:**

```sql
-- On EAST
CREATE LOGICAL REPLICATION STREAM
  FROM TABLE mydb.public.mytable
  ON 'external://west_cluster'
  INTO TABLE mydb.public.mytable;
```

Wait for BOTH a `LOGICAL REPLICATION` consumer AND a `REPLICATION STREAM PRODUCER` to show `running`:

```sql
-- On EAST — poll every 10 seconds until both show running
SELECT job_id, job_type, status, error
FROM crdb_internal.jobs
WHERE job_type LIKE '%REPLICATION%'
ORDER BY created DESC
LIMIT 5;
```

**Only after east shows both jobs running — create west stream:**

```sql
-- On WEST
CREATE LOGICAL REPLICATION STREAM
  FROM TABLE mydb.public.mytable
  ON 'external://east_cluster'
  INTO TABLE mydb.public.mytable;
```

---

## Phase 6 — Validation

### Step 6.1 — Monitor high_water_timestamp

`high_water_timestamp` should transition from `NULL` to a real timestamp within 60 seconds of both streams being created. It should advance toward `now()` continuously.

```sql
-- Run on BOTH clusters every 15 seconds
SELECT
  job_id,
  job_type,
  status,
  error,
  high_water_timestamp,
  now()::timestamp AS current_time
FROM crdb_internal.jobs
WHERE job_type = 'LOGICAL REPLICATION'
  AND status = 'running';
```

### Step 6.2 — Test East → West Replication

```sql
-- On EAST — insert a row
INSERT INTO mydb.public.mytable (data)
VALUES ('from east ' || now()::string);

-- On EAST — verify row exists
SELECT * FROM mydb.public.mytable ORDER BY updated_at DESC LIMIT 5;
```

After ~5 seconds, check west:

```sql
-- On WEST — row from east should appear
SELECT * FROM mydb.public.mytable ORDER BY updated_at DESC LIMIT 5;
```

### Step 6.3 — Test West → East Replication

```sql
-- On WEST — insert a row
INSERT INTO mydb.public.mytable (data)
VALUES ('from west ' || now()::string);
```

After ~5 seconds, check east:

```sql
-- On EAST — row from west should appear
SELECT * FROM mydb.public.mytable ORDER BY updated_at DESC LIMIT 5;
```

---

## Troubleshooting Reference

### Check All Replication Jobs

```sql
-- Full job status on either cluster
SELECT
  job_id,
  job_type,
  status,
  error,
  high_water_timestamp,
  now()::timestamp AS current_time
FROM crdb_internal.jobs
WHERE job_type LIKE '%REPLICATION%'
ORDER BY created DESC;
```

### Check Protected Timestamps

LDR sets a protected timestamp on the source to prevent GC from removing data the rangefeed needs:

```sql
-- On BOTH clusters — should show entries for LDR jobs
SELECT
  id,
  decoded_meta,
  decoded_target,
  verified
FROM crdb_internal.kv_protected_ts_records;
-- verified = t means KV has confirmed the protection
```

### Check Active Stream Data Flow

```sql
-- On BOTH clusters — shows active rangefeed stream processors
SELECT * FROM crdb_internal.cluster_replication_node_streams;
-- Empty = stream is connected at job level but no data processor active
```

### Check Enterprise License

```sql
-- On BOTH clusters
SHOW CLUSTER SETTING enterprise.license;
SHOW CLUSTER SETTING cluster.organization;
-- Both must be non-empty for LDR to function
```

### Pause and Resume a Job

```sql
PAUSE JOB <job_id>;
-- Wait 5 seconds
RESUME JOB <job_id>;
```

### Cancel Orphaned Producer Jobs

When a consumer job is cancelled, the producer on the source cluster becomes orphaned. Cancel it:

```sql
-- Find orphaned producers (running but no matching consumer)
SELECT job_id, job_type, status, error
FROM crdb_internal.jobs
WHERE job_type LIKE '%REPLICATION%'
  AND status IN ('running', 'paused')
ORDER BY created DESC;

CANCEL JOB <orphaned_producer_job_id>;
```

### Verify gRPC Keepalive Settings

```sql
SHOW CLUSTER SETTING server.grpc.keepalive.time;
SHOW CLUSTER SETTING server.grpc.keepalive.timeout;
```

### TCP Connectivity Test From Pod

```bash
kubectl exec -it cockroachdb-0 \
  -n "$REGION1" --context "$CONTEXT1" \
  -- bash -c "
    timeout 5 bash -c 'cat /dev/null > /dev/tcp/${WEST_LB}/26257' \
    && echo 'Port 26257: OK' || echo 'Port 26257: FAILED'
    timeout 5 bash -c 'cat /dev/null > /dev/tcp/${WEST_LB}/26258' \
    && echo 'Port 26258: OK' || echo 'Port 26258: FAILED'
  "
```

### Check Pod Logs for Replication Errors

```bash
# Check log files inside pod
kubectl exec -it cockroachdb-0 \
  -n "$REGION1" --context "$CONTEXT1" \
  -- ls -la /cockroach/cockroach-data/logs/

# Tail log file for replication entries
kubectl exec -it cockroachdb-0 \
  -n "$REGION1" --context "$CONTEXT1" \
  -- grep -i "replication\|logical\|LDR\|rangefeed\|error" \
  /cockroach/cockroach-data/logs/cockroach.log | tail -30
```

---

## Common Errors and Fixes

| Error / Symptom | Root Cause | Fix |
|---|---|---|
| `high_water_timestamp` stuck at `NULL` | Missing `crdb_route=gateway` in connection string | Recreate external connections with `&crdb_route=gateway` |
| `high_water_timestamp` stuck at `NULL` | No enterprise license | Apply license via `SET CLUSTER SETTING enterprise.license` |
| Job auto-pauses with `history retention job is no longer active` | Producer job died, usually due to missing license | Apply license, cancel all jobs, recreate streams |
| `connection refused` / timeout | VPC peering route missing from some subnets | Add peering route to ALL route tables in both VPCs |
| `x509: certificate is valid for ... not <NLB hostname>` | NLB hostname not in node cert SANs | Use `sslmode=verify-ca` instead of `verify-full` |
| `AccessDenied: sts:AssumeRoleWithWebIdentity` | IRSA trust policy misconfigured | Attach `AmazonEBSCSIDriverPolicy` to node group IAM role directly |
| Jobs running but no data flowing | NLB idle timeout dropping rangefeed connections | Set NLB idle timeout to 3600s and enable gRPC keepalives |
| `GRANT SYSTEM REPLICATION` needed | root user lacks REPLICATION privilege | `GRANT SYSTEM REPLICATION TO root` on both clusters |
| Duplicate `--log` flags crashing pods | `additionalArgs` in CrdbCluster conflicts with operator's log flag | Remove `additionalArgs`, use `logConfigMap` field instead |

