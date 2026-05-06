# background: initial setup of 2 aws eks clusters ended up incompatible for bi-directional LDR
#   due to overlapping CIDRs:

# Get VPC IDs for each cluster
VPC_EAST=$(aws eks describe-cluster \
  --name $CLUSTER_EAST --region us-east-1 \
  --query "cluster.resourcesVpcConfig.vpcId" --output text)

VPC_WEST=$(aws eks describe-cluster \
  --name $CLUSTER_WEST --region us-west-2 \
  --query "cluster.resourcesVpcConfig.vpcId" --output text)

echo "East VPC: $VPC_EAST"
echo "West VPC: $VPC_WEST"

# Get CIDRs
CIDR_EAST=$(aws ec2 describe-vpcs --vpc-ids $VPC_EAST \
  --region us-east-1 \
  --query "Vpcs[0].CidrBlock" --output text)

CIDR_WEST=$(aws ec2 describe-vpcs --vpc-ids $VPC_WEST \
  --region us-west-2 \
  --query "Vpcs[0].CidrBlock" --output text)

echo "East CIDR: $CIDR_EAST"
echo "West CIDR: $CIDR_WEST"


# as this follows a new deployment, best option is to drop and recreate one of the clusters:

kubectl delete crdbcluster cockroachdb -n $REGION2 --context $CONTEXT2 

kubectl delete pvc \
  datadir-cockroachdb-0 \
  datadir-cockroachdb-1 \
  datadir-cockroachdb-2 \
  -n "$REGION2" --context "$CONTEXT2"

# this errored with "tls: failed to verify cert" deleted via console instead
eksctl delete cluster \
  --name $CLUSTER_WEST \
  --region us-west-2

# in addition to the previous step, had to delete the stacks using:
aws cloudformation delete-stack \
  --stack-name eksctl-dlupinski-cockroach-west2-nodegroup-standard-workers \
  --region us-west-2

aws cloudformation delete-stack \
  --stack-name eksctl-dlupinski-cockroach-west2-cluster \
  --region us-west-2

# recreate eks cluster note vpc-cidr assignment:
# previous step took an excessive amount of time to release the stack name, creating with new name

export CLUSTER_WEST=dlupinski-cockroach-west2b

eksctl create cluster \
  --name $CLUSTER_WEST \
  --region us-west-2 \
  --vpc-cidr 10.0.0.0/16 \
  --nodegroup-name standard-workers \
  --node-type m5.xlarge \
  --nodes 3 

# see README.md for remaining tasks




# validate

kubectl exec -it cockroachdb-0 \
  -n "$REGION1" --context "$CONTEXT1" \
  -- /cockroach/cockroach sql \
  --certs-dir=/cockroach/cockroach-certs/ \
  --url="postgresql://root@${WEST_LB}:26257/defaultdb?sslmode=verify-ca&sslrootcert=/cockroach/cockroach-certs/ca.crt&sslcert=/cockroach/cockroach-certs/tls.crt&sslkey=/cockroach/cockroach-certs/tls.key" \
  -e "SELECT 'cross-cluster trust OK';"

  kubectl exec -it cockroachdb-0 \
  -n "$REGION2" --context "$CONTEXT2" \
  -- /cockroach/cockroach sql \
  --certs-dir=/cockroach/cockroach-certs/ \
  --url="postgresql://root@${EAST_LB}:26257/defaultdb?sslmode=verify-ca&sslrootcert=/cockroach/cockroach-certs/ca.crt&sslcert=/cockroach/cockroach-certs/tls.crt&sslkey=/cockroach/cockroach-certs/tls.key" \
  -e "SELECT 'cross-cluster trust OK';"