#!/bin/bash

# Substitute your own values before running:
#   <ACCOUNT_ID>   your 12-digit AWS account ID (appears in every bucket name)
# and set CF_ID below to your current distribution ID (changes on every rebuild).

# confirmation
read -p "Type NUKE to confirm: " CONFIRM
if [ "$CONFIRM" != "NUKE" ]; then
  echo "Nuke aborted."
  exit 1
fi

# update CF_ID after each rebuild
CF_ID="<DISTRIBUTION_ID>"

# get cloudfront etag
CF_ETAG=$(aws cloudfront get-distribution-config \
--id "$CF_ID" \
--query "ETag" \
--output text --profile lu)

# disassociate web acl from cloudfront
echo "Disassociating Web ACL from CloudFront distribution..."
aws cloudfront disassociate-distribution-web-acl \
--id "$CF_ID" \
--if-match "$CF_ETAG" --profile lu && \
echo "Disassociation complete."

# get updated cloudfront etag
CF_ETAG=$(aws cloudfront get-distribution-config \
--id "$CF_ID" \
--query "ETag" \
--output text --profile lu)

# create disable config file
aws cloudfront get-distribution-config \
--id "$CF_ID" --profile lu | \
jq '.DistributionConfig | .Enabled = false' > temp_config.json

# initiate cloudfront disable
echo "Disabling CloudFront distribution..."
aws cloudfront update-distribution \
--id "$CF_ID" \
--distribution-config file://temp_config.json \
--if-match "$CF_ETAG" --profile lu

# wait for distribution deployment
aws cloudfront wait distribution-deployed \
--id "$CF_ID" --profile lu && \
echo "CloudFront Distribution disabled."

# get updated cloudfront etag
CF_ETAG=$(aws cloudfront get-distribution-config \
--id "$CF_ID" \
--query "ETag" \
--output text --profile lu)

# delete cloudfront distribution
echo "Deleting CloudFront distributon..."
aws cloudfront delete-distribution \
--id "$CF_ID" \
--if-match "$CF_ETAG" --profile lu && \
echo "CloudFront Distribution deleted."

# get web acl id
WAF_ID=$(aws wafv2 list-web-acls \
--scope CLOUDFRONT \
--query "WebACLs[?Name=='p2-waf'].Id" \
--output text --region us-east-1 --profile lu)

# get web acl lock token
LOCK_TOKEN=$(aws wafv2 get-web-acl \
--scope CLOUDFRONT \
--query "LockToken" \
--name "p2-waf" \
--id "$WAF_ID" \
--output text --region us-east-1 --profile lu)

# delete web acl
echo "Deleting Web ACL..."
aws wafv2 delete-web-acl \
--scope CLOUDFRONT \
--name "p2-waf" \
--id "$WAF_ID" \
--lock-token "$LOCK_TOKEN" --region us-east-1 --profile lu && \
echo "Web ACL deleted."

# empty and delete access log bucket
echo "Emptying access log bucket..."
aws s3 rm s3://p2-bucket-access-logs-<ACCOUNT_ID>-us-west-2-an \
--recursive --region us-west-2 --profile lu && \
echo "Access log bucket emptied, now deleting..."

aws s3api delete-bucket \
--bucket p2-bucket-access-logs-<ACCOUNT_ID>-us-west-2-an \
--region us-west-2 --profile lu && \
echo "Access logs bucket deleted."

# empty and delete waf log bucket
echo "Emptying WAF log bucket..."
aws s3 rm s3://aws-waf-logs-p2-<ACCOUNT_ID>-us-east-1-an \
--recursive --region us-east-1 --profile lu && \
echo "WAF log bucket emptied, now deleting..."

aws s3api delete-bucket \
--bucket aws-waf-logs-p2-<ACCOUNT_ID>-us-east-1-an \
--region us-east-1 --profile lu && \
echo "WAF logs bucket deleted."

# empty and delete replica bucket
echo "Emptying replica bucket"
aws s3 rm s3://p2-bucket-replica-<ACCOUNT_ID>-us-east-1-an \
--recursive --region us-east-1 --profile lu

aws s3api delete-objects \
--bucket p2-bucket-replica-<ACCOUNT_ID>-us-east-1-an \
--region us-east-1 --profile lu \
--delete "$(aws s3api list-object-versions \
  --bucket p2-bucket-replica-<ACCOUNT_ID>-us-east-1-an \
  --region us-east-1 --profile lu \
  --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
  --output json)" 2>/dev/null

aws s3api delete-objects \
--bucket p2-bucket-replica-<ACCOUNT_ID>-us-east-1-an \
--region us-east-1 --profile lu \
--delete "$(aws s3api list-object-versions \
  --bucket p2-bucket-replica-<ACCOUNT_ID>-us-east-1-an \
  --region us-east-1 --profile lu \
  --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
  --output json)" 2>/dev/null && \
echo "Replica bucket emptied, now deleting..."

aws s3api delete-bucket \
--bucket p2-bucket-replica-<ACCOUNT_ID>-us-east-1-an \
--region us-east-1 --profile lu && \
echo "Replica bucket deleted."

# empty and delete primary bucket
echo "Emptying primary bucket..."
aws s3 rm s3://p2-bucket-<ACCOUNT_ID>-us-west-2-an \
--recursive --region us-west-2 --profile lu

aws s3api delete-objects \
--bucket p2-bucket-<ACCOUNT_ID>-us-west-2-an \
--region us-west-2 --profile lu \
--delete "$(aws s3api list-object-versions \
  --bucket p2-bucket-<ACCOUNT_ID>-us-west-2-an \
  --region us-west-2 --profile lu \
  --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
  --output json)" 2>/dev/null

aws s3api delete-objects \
--bucket p2-bucket-<ACCOUNT_ID>-us-west-2-an \
--region us-west-2 --profile lu \
--delete "$(aws s3api list-object-versions \
  --bucket p2-bucket-<ACCOUNT_ID>-us-west-2-an \
  --region us-west-2 --profile lu \
  --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
  --output json)" 2>/dev/null && \
echo "Primary bucket emptied, now deleting..."

aws s3api delete-bucket \
--bucket p2-bucket-<ACCOUNT_ID>-us-west-2-an \
--region us-west-2 --profile lu && \
echo "Primary bucket deleted."
