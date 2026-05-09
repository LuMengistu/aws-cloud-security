#!/bin/bash

#confirmation
read -p "Type NUKE to confirm: " CONFIRM
if [ "$CONFIRM" != "NUKE" ]; then
    echo "Aborted."
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

# get volumes
VOL_IDS=$(aws ec2 describe-volumes \
--filters "Name=tag:Project,Values=Cloud-Security" \
--query "Volumes[].VolumeId" \
--output text --region us-west-2 --profile lu)

# delete volumes
if [ -z "$VOL_IDS" ]; then
    echo "No volumes found."
else
    for VOL in $VOL_IDS; do
        aws ec2 wait volume-available --volume-ids "$VOL" --region us-west-2 --profile lu
        echo "Deleting volume(s): $VOL"
        aws ec2 delete-volume --volume-id "$VOL" --region us-west-2 --profile lu
        echo "Volume(s) deleted."
    done
fi

# get elastic ips
ALLOC_IDS=$(aws ec2 describe-addresses \
--filters "Name=tag:Project,Values=Cloud-Security" \
--query "Addresses[].AllocationId" \
--output text --region us-west-2 --profile lu)

# release elastic ips
if [ -z "$ALLOC_IDS" ]; then
    echo "No Elastic IPs found."
else
    for ALLOC in $ALLOC_IDS; do
        echo "Releasing Elastic IP(s): $ALLOC"
        aws ec2 release-address --allocation-id "$ALLOC" --region us-west-2 --profile lu
        echo "Elastic IP(s) deleted."
    done
fi

# completion message
echo "Nuke completed. Thank you."