NODE_ROLE=$(aws eks describe-nodegroup \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name "standard-workers" \
  --region $REGION \
  --query "nodegroup.nodeRole" \
  --output text | cut -d'/' -f2)
