#!/bin/bash

# confirmation
read -p "Type NUKE to confirm: " CONFIRM
if [ "$CONFIRM" != "NUKE" ]; then
  echo "Nuke aborted"
  exit 1
fi

REGION="us-west-2"
PROFILE="lu"
VPC_ID="vpc-0fcdabdd703a28668"
LOG_GROUP="/vpc/flowlogs"
LOG_BUCKET="p3-alb-access-logs-677237768060-us-west-2-an"

# get ASG instance IDs before deleting the group
ASG_INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:aws:autoscaling:groupName,Values=p3-asg" \
            "Name=instance-state-name,Values=running,pending" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text --region $REGION --profile $PROFILE)

# terminate instances + delete auto scaling group
echo "Deleting auto scaling group: p3-asg"
aws autoscaling delete-auto-scaling-group \
  --auto-scaling-group-name p3-asg \
  --force-delete --region $REGION --profile $PROFILE \
  && echo "Auto scaling group deleted."

# wait for instances to fully terminate
if [ -z "$ASG_INSTANCE_IDS" ]; then
  echo "No instances to wait on."
else
  echo "Waiting for instances to terminate: $ASG_INSTANCE_IDS"
  aws ec2 wait instance-terminated --instance-ids $ASG_INSTANCE_IDS \
    --region $REGION --profile $PROFILE
  echo "Instances terminated."
fi

# get launch template
LT_IDS=$(aws ec2 describe-launch-templates \
  --filters "Name=tag:Project,Values=Cloud-Security" \
  --query "LaunchTemplates[].LaunchTemplateId" \
  --output text --region $REGION --profile $PROFILE)

# delete launch template
if [ -z "$LT_IDS" ]; then
  echo "No launch templates found."
else
  for LT in $LT_IDS; do
    echo "Deleting launch template: $LT"
    aws ec2 delete-launch-template --launch-template-id "$LT" \
      --region $REGION --profile $PROFILE \
      && echo "Launch template deleted."
  done
fi

# get ALB
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names p3-alb \
  --query "LoadBalancers[].LoadBalancerArn" \
  --output text --region $REGION --profile $PROFILE 2>/dev/null)

# delete ALB
if [ -z "$ALB_ARN" ]; then
  echo "No load balancer found."
else
  echo "Deleting ALB: $ALB_ARN"
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" \
    --region $REGION --profile $PROFILE \
    && echo "ALB deleted."
  echo "Waiting for ALB deletion to complete."
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" \
    --region $REGION --profile $PROFILE
fi

# get target group
TG_ARN=$(aws elbv2 describe-target-groups \
  --names p3-tg \
  --query "TargetGroups[].TargetGroupArn" \
  --output text --region $REGION --profile $PROFILE 2>/dev/null)

# delete target group
# retried because the ALB listener reference can outlive the ALB deletion wait
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
  echo "Target group deleted."
fi

# get VPC endpoints
VPCE_IDS=$(aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "VpcEndpoints[].VpcEndpointId" \
  --output text --region $REGION --profile $PROFILE)

# delete VPC endpoints
if [ -z "$VPCE_IDS" ]; then
  echo "No VPC endpoints found."
else
  echo "Deleting VPC endpoints: $VPCE_IDS"
  aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $VPCE_IDS \
    --region $REGION --profile $PROFILE \
    && echo "VPC endpoints deleted."
fi

# wait for all ENIs in the VPC to clear (max 10 minutes)
# endpoint deletion is asynchronous; subnets will not delete while an ENI is attached
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

# get flow logs
FL_IDS=$(aws ec2 describe-flow-logs \
  --filter "Name=resource-id,Values=$VPC_ID" \
  --query "FlowLogs[].FlowLogId" \
  --output text --region $REGION --profile $PROFILE)

# delete flow logs
if [ -z "$FL_IDS" ]; then
  echo "No flow logs found."
else
  echo "Deleting flow logs: $FL_IDS"
  aws ec2 delete-flow-logs --flow-log-ids $FL_IDS \
    --region $REGION --profile $PROFILE \
    && echo "Flow logs deleted."
fi

# get subnets
SUBNET_IDS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "Subnets[].SubnetId" \
  --output text --region $REGION --profile $PROFILE)

# delete subnets
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

# get route tables (main route table cannot be deleted, filtered out)
RT_IDS=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "RouteTables[?length(Associations[?Main==\`true\`])==\`0\`].RouteTableId" \
  --output text --region $REGION --profile $PROFILE)

# delete route tables
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

# get security groups (default SG cannot be deleted, filtered out)
SG_IDS=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[?GroupName!='default'].GroupId" \
  --output text --region $REGION --profile $PROFILE)

# revoke all cross-referencing rules before deleting
# SGs that reference each other cannot be deleted; the reference must be broken first
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

# get internet gateway
IGW_ID=$(aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query "InternetGateways[].InternetGatewayId" \
  --output text --region $REGION --profile $PROFILE)

# detach and delete internet gateway
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

# delete VPC
echo "Deleting VPC: $VPC_ID"
aws ec2 delete-vpc --vpc-id "$VPC_ID" \
  --region $REGION --profile $PROFILE \
  && echo "VPC deleted."

# delete flow log group (outside the VPC, not caught by VPC filters)
echo "Deleting log group: $LOG_GROUP"
aws logs delete-log-group --log-group-name "$LOG_GROUP" \
  --region $REGION --profile $PROFILE 2>/dev/null \
  && echo "Log group deleted."

# empty and delete ALB access log bucket
# Object Lock is enabled, so every version needs --bypass-governance-retention
echo "Emptying access log bucket: $LOG_BUCKET"
aws s3api list-object-versions --bucket "$LOG_BUCKET" \
  --region $REGION --profile $PROFILE \
  --query 'Versions[].[Key,VersionId]' --output text 2>/dev/null | \
while read -r key version; do
  [ -z "$key" ] && continue
  aws s3api delete-object --bucket "$LOG_BUCKET" --key "$key" --version-id "$version" \
    --bypass-governance-retention --region $REGION --profile $PROFILE > /dev/null
done

aws s3api list-object-versions --bucket "$LOG_BUCKET" \
  --region $REGION --profile $PROFILE \
  --query 'DeleteMarkers[].[Key,VersionId]' --output text 2>/dev/null | \
while read -r key version; do
  [ -z "$key" ] && continue
  aws s3api delete-object --bucket "$LOG_BUCKET" --key "$key" --version-id "$version" \
    --bypass-governance-retention --region $REGION --profile $PROFILE > /dev/null
done

echo "Deleting bucket: $LOG_BUCKET"
aws s3api delete-bucket --bucket "$LOG_BUCKET" \
  --region $REGION --profile $PROFILE 2>/dev/null \
  && echo "Bucket deleted."

echo "Nuke completed."
