#!/bin/bash

# confirmation ↓
read -p "Type NUKE to confirm: " CONFIRM
if [ "$CONFIRM" != "NUKE" ]; then
	echo "Aborted."
	exit 1
fi

# get instances ↓
INSTANCE_IDS=$(aws ec2 describe-instances \
--filters "Name=tag:Project,Values=Cloud-Security" "Name=instance-state-name,Values=running,stopped" \
--query "Reservations[].Instances[].InstanceId" \
--output text --region us-west-2 --profile lu)

# terminate instances + wait ↓
for INST in $INSTANCE_IDS; do
    echo "Terminating instance(s): $INST"
    aws ec2 terminate-instances --instance-ids "$INST" --region us-west-2 --profile lu
    aws ec2 wait instance-terminated --instance-ids "$INST" --region us-west-2 --profile lu
done


# get volumes ↓
VOLUME_IDS=$(aws ec2 describe-volumes \
--filters "Name=tag:Project,Values=Cloud-Security" \
--query "Volumes[].VolumeId" \
--output text --region us-west-2 --profile lu)

# delete volumes ↓
for VOL in $VOLUME_IDS; do
    echo "Deleting volume(s): $VOL"
    aws ec2 wait volume-available --volume-ids "$VOL" --region us-west-2 --profile lu
    aws ec2 delete-volume --volume-id "$VOL" --region us-west-2 --profile lu
done


# get elastic ips ↓
ALLOC_IDS=$(aws ec2 describe-addresses \
--filters "Name=tag:Project,Values=Cloud-Security" \
--query "Addresses[].AllocationId" \
--output text --region us-west-2 --profile lu)

# release elastic ips ↓
for ALLOC in $ALLOC_IDS; do
	echo "Releasing Elastic IP(s): $ALLOC"
	aws ec2 release-address --allocation-id "$ALLOC" --region us-west-2 --profile lu
done


# completion message ↓
echo "Nuke completed. Thank you."
