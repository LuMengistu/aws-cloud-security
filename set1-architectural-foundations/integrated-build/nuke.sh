#!/bin/bash

# confirmation
read -p "Type NUKE to confirm: " CONFIRM
if [ "$CONFIRM" != "NUKE" ]; then
  echo "Nuke aborted"
  exit 1
fi

REGION="us-west-2"
PROFILE="lu"
VPC_ID="vpc-0ed7030446b7a511f"

ASG_NAME="p4-asg"
LT_NAME="p4-launch-template"
ALB_NAME="p4-alb"
TG_NAME="p4-tg"
DIST_ID="E2V4GPJUGBWJMP"

LOG_GROUP="/vpc/flow-log"

BUCKETS=(
  "p4-bucket-677237768060-us-west-2-an"
  "p4-alb-access-logs-677237768060-us-west-2-an"
  "p4-cloudfront-logs-677237768060-us-west-2-an"
  "aws-waf-logs-p4-677237768060-us-east-1-an"
  "p4-s3-access-logs-677237768060-us-west-2-an"
)

# edge first: nothing below can go while the distribution references it
DIST_EXISTS=$(aws cloudfront get-distribution --id "$DIST_ID" \
  --profile $PROFILE --query 'Distribution.Id' --output text 2>/dev/null)

if [ -z "$DIST_EXISTS" ]; then
  echo "No distribution found."
else
  echo "Reading distribution config: $DIST_ID"
  aws cloudfront get-distribution-config --id "$DIST_ID" \
    --profile $PROFILE > /tmp/dist-full.json

  ETAG=$(jq -r '.ETag' /tmp/dist-full.json)
  jq '.DistributionConfig | .Enabled = false | .WebACLId = ""' \
    /tmp/dist-full.json > /tmp/dist-config.json

  echo "Disabling distribution and clearing web ACL association"
  aws cloudfront update-distribution --id "$DIST_ID" \
    --distribution-config file:///tmp/dist-config.json \
    --if-match "$ETAG" --profile $PROFILE > /dev/null \
    && echo "Distribution disabled."

  echo "Waiting for distribution to finish deploying. Do not interrupt."
  aws cloudfront wait distribution-deployed --id "$DIST_ID" --profile $PROFILE

  # fresh ETag: the update above superseded the previous version
  NEW_ETAG=$(aws cloudfront get-distribution-config --id "$DIST_ID" \
    --profile $PROFILE --query 'ETag' --output text)

  echo "Deleting distribution: $DIST_ID"
  aws cloudfront delete-distribution --id "$DIST_ID" \
    --if-match "$NEW_ETAG" --profile $PROFILE \
    && echo "Distribution deleted."
fi

ACL_JSON=$(aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1 \
  --profile $PROFILE --query 'WebACLs[0].{Name:Name,Id:Id}' --output json 2>/dev/null)
ACL_NAME=$(echo "$ACL_JSON" | jq -r '.Name // empty')
ACL_ID=$(echo "$ACL_JSON" | jq -r '.Id // empty')

if [ -z "$ACL_ID" ]; then
  echo "No web ACL found."
else
  LOCK_TOKEN=$(aws wafv2 get-web-acl --name "$ACL_NAME" --scope CLOUDFRONT \
    --id "$ACL_ID" --region us-east-1 --profile $PROFILE \
    --query 'LockToken' --output text)

  echo "Deleting web ACL: $ACL_NAME"
  aws wafv2 delete-web-acl --name "$ACL_NAME" --scope CLOUDFRONT \
    --id "$ACL_ID" --lock-token "$LOCK_TOKEN" \
    --region us-east-1 --profile $PROFILE \
    && echo "Web ACL deleted."
fi

VPCO_IDS=$(aws cloudfront list-vpc-origins --profile $PROFILE \
  --query 'VpcOriginList.Items[].Id' --output text 2>/dev/null)

if [ -z "$VPCO_IDS" ]; then
  echo "No VPC origins found."
else
  for VPCO in $VPCO_IDS; do
    VPCO_ETAG=$(aws cloudfront get-vpc-origin --id "$VPCO" \
      --profile $PROFILE --query 'ETag' --output text)
    echo "Deleting VPC origin: $VPCO"
    aws cloudfront delete-vpc-origin --id "$VPCO" \
      --if-match "$VPCO_ETAG" --profile $PROFILE > /dev/null \
      && echo "VPC origin deleted."
  done
fi

ASG_INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:aws:autoscaling:groupName,Values=$ASG_NAME" \
            "Name=instance-state-name,Values=running,pending" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text --region $REGION --profile $PROFILE)

echo "Deleting auto scaling group: $ASG_NAME"
aws autoscaling delete-auto-scaling-group \
  --auto-scaling-group-name "$ASG_NAME" \
  --force-delete --region $REGION --profile $PROFILE 2>/dev/null \
  && echo "Auto scaling group deleted."

# force-delete returns before instances finish terminating
if [ -z "$ASG_INSTANCE_IDS" ]; then
  echo "No instances to wait on."
else
  echo "Waiting for instances to terminate: $ASG_INSTANCE_IDS"
  aws ec2 wait instance-terminated --instance-ids $ASG_INSTANCE_IDS \
    --region $REGION --profile $PROFILE
  echo "Instances terminated."
fi

LT_EXISTS=$(aws ec2 describe-launch-templates \
  --launch-template-names "$LT_NAME" \
  --query 'LaunchTemplates[0].LaunchTemplateId' \
  --output text --region $REGION --profile $PROFILE 2>/dev/null)

if [ -z "$LT_EXISTS" ]; then
  echo "No launch template found."
else
  echo "Deleting launch template: $LT_NAME"
  aws ec2 delete-launch-template --launch-template-name "$LT_NAME" \
    --region $REGION --profile $PROFILE > /dev/null \
    && echo "Launch template deleted."
fi

ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" \
  --query "LoadBalancers[].LoadBalancerArn" \
  --output text --region $REGION --profile $PROFILE 2>/dev/null)

if [ -z "$ALB_ARN" ]; then
  echo "No load balancer found."
else
  echo "Deleting load balancer: $ALB_ARN"
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" \
    --region $REGION --profile $PROFILE \
    && echo "Load balancer deleted."
  echo "Waiting for load balancer deletion to complete."
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" \
    --region $REGION --profile $PROFILE
fi

# the listener reference outlives the load balancer's own wait
TG_ARN=$(aws elbv2 describe-target-groups --names "$TG_NAME" \
  --query "TargetGroups[].TargetGroupArn" \
  --output text --region $REGION --profile $PROFILE 2>/dev/null)

if [ -z "$TG_ARN" ]; then
  echo "No target group found."
else
  TG_ATTEMPTS=0
  until aws elbv2 delete-target-group --target-group-arn "$TG_ARN" \
    --region $REGION --profile $PROFILE 2>/dev/null; do
    TG_ATTEMPTS=$((TG_ATTEMPTS + 1))
    if [ $TG_ATTEMPTS -ge 12 ]; then
      echo "Target group still in use after 3 minutes. Investigate."
      break
    fi
    echo "Target group still in use by a listener. Waiting."
    sleep 15
  done
  if [ $TG_ATTEMPTS -lt 12 ]; then
    echo "Target group deleted."
  fi
fi

VPCE_IDS=$(aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "VpcEndpoints[].VpcEndpointId" \
  --output text --region $REGION --profile $PROFILE)

if [ -z "$VPCE_IDS" ]; then
  echo "No VPC endpoints found."
else
  echo "Deleting VPC endpoints: $VPCE_IDS"
  aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $VPCE_IDS \
    --region $REGION --profile $PROFILE > /dev/null \
    && echo "VPC endpoints deleted."
fi

# subnets will not delete while an ENI is attached
echo "Waiting for ENIs to clear."
ATTEMPTS=0
MAX_ATTEMPTS=40
while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
  ENI_COUNT=$(aws ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "length(NetworkInterfaces)" \
    --output text --region $REGION --profile $PROFILE)
  if [ "$ENI_COUNT" = "0" ]; then
    echo "ENIs cleared."
    break
  fi
  echo "$ENI_COUNT ENI(s) still attached. Waiting."
  sleep 15
  ATTEMPTS=$((ATTEMPTS + 1))
done

if [ $ATTEMPTS -eq $MAX_ATTEMPTS ]; then
  echo "ENIs did not clear after 10 minutes. Investigate before continuing."
  exit 1
fi

FL_IDS=$(aws ec2 describe-flow-logs \
  --filter "Name=resource-id,Values=$VPC_ID" \
  --query "FlowLogs[].FlowLogId" \
  --output text --region $REGION --profile $PROFILE)

if [ -z "$FL_IDS" ]; then
  echo "No flow logs found."
else
  echo "Deleting flow logs: $FL_IDS"
  aws ec2 delete-flow-logs --flow-log-ids $FL_IDS \
    --region $REGION --profile $PROFILE > /dev/null \
    && echo "Flow logs deleted."
fi

SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "Subnets[].SubnetId" \
  --output text --region $REGION --profile $PROFILE)

if [ -z "$SUBNET_IDS" ]; then
  echo "No subnets found."
else
  for SUBNET in $SUBNET_IDS; do
    echo "Deleting subnet: $SUBNET"
    aws ec2 delete-subnet --subnet-id "$SUBNET" \
      --region $REGION --profile $PROFILE \
      && echo "Subnet deleted."
  done
fi

# main route table excluded, it cannot be deleted
RT_IDS=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "RouteTables[?length(Associations[?Main==\`true\`])==\`0\`].RouteTableId" \
  --output text --region $REGION --profile $PROFILE)

if [ -z "$RT_IDS" ]; then
  echo "No route tables found."
else
  for RT in $RT_IDS; do
    echo "Deleting route table: $RT"
    aws ec2 delete-route-table --route-table-id "$RT" \
      --region $REGION --profile $PROFILE \
      && echo "Route table deleted."
  done
fi

# groups reference each other, so revoke all rules before deleting any
SG_IDS=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[?GroupName!='default'].GroupId" \
  --output text --region $REGION --profile $PROFILE)

if [ -z "$SG_IDS" ]; then
  echo "No security groups found."
else
  for SG in $SG_IDS; do
    echo "Revoking rules on: $SG"

    INGRESS=$(aws ec2 describe-security-group-rules \
      --filters "Name=group-id,Values=$SG" \
      --query "SecurityGroupRules[?IsEgress==\`false\`].SecurityGroupRuleId" \
      --output text --region $REGION --profile $PROFILE)
    if [ -n "$INGRESS" ]; then
      aws ec2 revoke-security-group-ingress --group-id "$SG" \
        --security-group-rule-ids $INGRESS \
        --region $REGION --profile $PROFILE > /dev/null \
        && echo "Ingress rules revoked."
    fi

    EGRESS=$(aws ec2 describe-security-group-rules \
      --filters "Name=group-id,Values=$SG" \
      --query "SecurityGroupRules[?IsEgress==\`true\`].SecurityGroupRuleId" \
      --output text --region $REGION --profile $PROFILE)
    if [ -n "$EGRESS" ]; then
      aws ec2 revoke-security-group-egress --group-id "$SG" \
        --security-group-rule-ids $EGRESS \
        --region $REGION --profile $PROFILE > /dev/null \
        && echo "Egress rules revoked."
    fi
  done

  for SG in $SG_IDS; do
    echo "Deleting security group: $SG"
    aws ec2 delete-security-group --group-id "$SG" \
      --region $REGION --profile $PROFILE > /dev/null \
      && echo "Security group deleted."
  done
fi

IGW_ID=$(aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query "InternetGateways[].InternetGatewayId" \
  --output text --region $REGION --profile $PROFILE)

if [ -z "$IGW_ID" ]; then
  echo "No internet gateway found."
else
  echo "Detaching internet gateway: $IGW_ID"
  aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" \
    --vpc-id "$VPC_ID" --region $REGION --profile $PROFILE \
    && echo "Internet gateway detached."
  echo "Deleting internet gateway: $IGW_ID"
  aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" \
    --region $REGION --profile $PROFILE \
    && echo "Internet gateway deleted."
fi

echo "Deleting VPC: $VPC_ID"
aws ec2 delete-vpc --vpc-id "$VPC_ID" \
  --region $REGION --profile $PROFILE \
  && echo "VPC deleted."

echo "Deleting log group: $LOG_GROUP"
aws logs delete-log-group --log-group-name "$LOG_GROUP" \
  --region $REGION --profile $PROFILE 2>/dev/null \
  && echo "Log group deleted."

# Object Lock on the access log bucket needs the governance bypass
for BUCKET in "${BUCKETS[@]}"; do
  BUCKET_REGION=$(aws s3api get-bucket-location --bucket "$BUCKET" \
    --profile $PROFILE --query 'LocationConstraint' --output text 2>/dev/null)
  if [ -z "$BUCKET_REGION" ]; then
    echo "Bucket not found: $BUCKET"
    continue
  fi
  [ "$BUCKET_REGION" = "None" ] && BUCKET_REGION="us-east-1"

  echo "Emptying bucket: $BUCKET"

  aws s3 rm "s3://$BUCKET" --recursive \
    --region "$BUCKET_REGION" --profile $PROFILE > /dev/null 2>&1

  aws s3api list-object-versions --bucket "$BUCKET" \
    --region "$BUCKET_REGION" --profile $PROFILE \
    --query '[Versions,DeleteMarkers][][].[Key,VersionId]' \
    --output text 2>/dev/null | \
  while read -r key version; do
    [ -z "$key" ] && continue
    aws s3api delete-object --bucket "$BUCKET" --key "$key" \
      --version-id "$version" --bypass-governance-retention \
      --region "$BUCKET_REGION" --profile $PROFILE > /dev/null 2>&1
  done

  echo "Deleting bucket: $BUCKET"
  aws s3api delete-bucket --bucket "$BUCKET" \
    --region "$BUCKET_REGION" --profile $PROFILE \
    && echo "Bucket deleted."
done

echo "Nuke completed."
