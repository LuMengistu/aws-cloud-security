#!/bin/bash

# confirmation
read -p "Type NUKE to confirm: " CONFIRM
if [ "$CONFIRM" != "NUKE" ]; then
  echo "Nuke aborted."
  exit 1
fi

# get instances
INST_IDS=$(aws ec2 describe-instances \
--filters "Name=tag:Project,Values=Cloud-Security" "Name=instance-state-name,Values=running,stopped" \
--query "Reservations[].Instances[].InstanceId" \
--output text --region us-west-2 --profile lu)

# terminate instances
if [ -z "$INST_IDS" ]; then
  echo "No instances found."
else
  echo "Terminating instance(s): $INST_IDS"
  aws ec2 terminate-instances --instance-ids "$INST_IDS" --region us-west-2 --profile lu
  aws ec2 wait instance-terminated --instance-ids "$INST_IDS" --region us-west-2 --profile lu
  echo "Instance(s) terminated."
fi

# get elastic ips
ALLOC_IDS=$(aws ec2 describe-addresses \
--filters "Name=tag:Project,Values=Cloud-Security" \
--query "Addresses[].AllocationId" \
--output text --region us-west-2 --profile lu)

# release elastic ips
if [ -z "$ALLOC_IDS" ]; then
  echo "No elastic IPs found."
else
  for ALLOC in $ALLOC_IDS; do
    echo "Releasing elastic IP: $ALLOC"
    aws ec2 release-address --allocation-id "$ALLOC" --region us-west-2 --profile lu
    echo "Elastic IP released."
  done
fi

# completion message
echo "Nuke completed."
