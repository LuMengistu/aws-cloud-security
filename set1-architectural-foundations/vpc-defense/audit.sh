#!/bin/bash
aws ec2 describe-instances \
--filters "Name=tag:Project,Values=Cloud-Security" \
--query "Reservations[].Instances[].[InstanceId, MetadataOptions.HttpTokens, MetadataOptions.HttpPutResponseHopLimit]" \
--output text --profile lu --region us-west-2 | while read -r id token hop; do
  if [ "$token" = "required" ] && [ "$hop" = "1" ]; then
    echo "$id PASS"
  else
    echo "$id FAIL: tokens=$token hop=$hop"
  fi
done
