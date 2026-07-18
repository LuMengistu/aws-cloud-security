# Edge Hardening Setup

This rebuilds the edge in front of the S3 origin. It is a guided reference, not a one-shot script: the CloudFront distribution, ACM certificate, WAF Web ACL, and registrar records are console or external steps that cannot be scripted, and the scriptable blocks apply configuration to the resources those steps create.

Before use, substitute your own values:
- `<ACCOUNT_ID>` — your 12-digit AWS account ID (appears in every bucket name and ARN)
- `<DISTRIBUTION_ID>` — your CloudFront distribution ID (changes on every rebuild; must match the `CF_ID` in `nuke.sh`)

## Console Prerequisites

**Origin bucket**
- Create S3 bucket `p2-bucket` in us-west-2, Account Regional Namespace, ACLs disabled (Bucket owner enforced).
- Block Public Access on, all four settings. SSE-S3. Tagged `Project: Cloud-Security`, `Env: Dev`.
- Do NOT enable static website hosting — OAC requires the REST endpoint, and the website endpoint breaks signing silently.
- Upload website files to the bucket root.

**CloudFront distribution**
- Create `p2-distribution`: pay as you go, single website, origin `p2-bucket`, allow private S3 bucket access, no WAF yet, default root object `index.html`. Tagged `Project: Cloud-Security`, `Env: Dev`.
- Apply the generated bucket policy to `p2-bucket` (scripted below with the SourceArn pinned to this distribution).

**ACM certificate**
- Request the cert in us-east-1 (the only region CloudFront reads certs from), covering the apex and www, DNS-validated via CNAME at the registrar. Do not proceed until status is Issued.

**Replica bucket**
- Create `p2-bucket-replica` in us-east-1, Account Regional Namespace, ACLs disabled, Block Public Access, SSE-S3, versioning enabled at creation. Tagged `Project: Cloud-Security`, `Env: Dev`.

**WAF logging bucket**
- Create `aws-waf-logs-p2` in us-east-1, Block Public Access, SSE-S3. Tagged `Project: Cloud-Security`, `Env: Dev`.

**WAF Web ACL**
- Create `p2-waf` in us-east-1, CLOUDFRONT scope: Core rule set plus `p2-rate-limit` (50 req / 5 min per IP). Logging destination S3 `aws-waf-logs-p2`. Attach to `p2-distribution`.

**Access logging bucket**
- Create `p2-bucket-access-logs` in us-west-2, Account Regional Namespace, ACLs disabled, Block Public Access, SSE-S3. Tagged `Project: Cloud-Security`, `Env: Dev`.

## Origin Bucket Configuration

Run after the origin bucket and distribution exist.

```bash
# block public access
aws s3api put-public-access-block --bucket p2-bucket-<ACCOUNT_ID>-us-west-2-an \
--public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
--region us-west-2 --profile lu

# bucket policy - oac (replace <DISTRIBUTION_ID> with your distribution's ID)
aws s3api put-bucket-policy --bucket p2-bucket-<ACCOUNT_ID>-us-west-2-an \
--policy '{
    "Version": "2008-10-17",
    "Id": "PolicyForCloudFrontPrivateContent",
    "Statement": [
        {
            "Sid": "AllowCloudFrontServicePrincipal",
            "Effect": "Allow",
            "Principal": {
                "Service": "cloudfront.amazonaws.com"
            },
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::p2-bucket-<ACCOUNT_ID>-us-west-2-an/*",
            "Condition": {
                "StringEquals": {
                    "AWS:SourceArn": "arn:aws:cloudfront::<ACCOUNT_ID>:distribution/<DISTRIBUTION_ID>"
                }
            }
        }
    ]
}' \
--region us-west-2 --profile lu

# default encryption (SSE-S3)
aws s3api put-bucket-encryption --bucket p2-bucket-<ACCOUNT_ID>-us-west-2-an \
--server-side-encryption-configuration '{
    "Rules": [
        {
            "ApplyServerSideEncryptionByDefault": {
                "SSEAlgorithm": "AES256"
            }
        }
    ]
}' \
--region us-west-2 --profile lu

# versioning
aws s3api put-bucket-versioning --bucket p2-bucket-<ACCOUNT_ID>-us-west-2-an \
--versioning-configuration '{"Status": "Enabled"}' \
--region us-west-2 --profile lu
```

## Versioning, Replication, and DR

Run after the replica bucket exists with versioning enabled. Replication requires versioning on both buckets, and the CRR role must exist before `put-bucket-replication` runs.

```bash
# replica bucket versioning
aws s3api put-bucket-versioning --bucket p2-bucket-replica-<ACCOUNT_ID>-us-east-1-an \
--versioning-configuration '{"Status": "Enabled"}' \
--region us-east-1 --profile lu

# primary bucket 30-day noncurrent-version expiry
aws s3api put-bucket-lifecycle-configuration --bucket p2-bucket-<ACCOUNT_ID>-us-west-2-an \
--lifecycle-configuration '{
    "Rules": [
        {
            "ID": "expire-noncurrent-versions",
            "Status": "Enabled",
            "Filter": {},
            "NoncurrentVersionExpiration": {
                "NoncurrentDays": 30
            }
        }
    ]
}' \
--region us-west-2 --profile lu

# cross-region replication - v2 (delete-marker replication left disabled)
aws s3api put-bucket-replication --bucket p2-bucket-<ACCOUNT_ID>-us-west-2-an \
--replication-configuration '{
    "Role": "arn:aws:iam::<ACCOUNT_ID>:role/service-role/s3crr_role_for_p2-bucket-<ACCOUNT_ID>-us-west-2-an",
    "Rules": [
        {
            "ID": "primary-bucket-replication",
            "Status": "Enabled",
            "Filter": {},
            "Destination": {
                "Bucket": "arn:aws:s3:::p2-bucket-replica-<ACCOUNT_ID>-us-east-1-an"
            }
        }
    ]
}' \
--region us-west-2 --profile lu
```

## WAF Logging Bucket Configuration

Run after the WAF logging bucket exists. The `aws-waf-logs-` prefix is required — WAF rejects any other.

```bash
# block public access
aws s3api put-public-access-block --bucket aws-waf-logs-p2-<ACCOUNT_ID>-us-east-1-an \
--public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
--region us-east-1 --profile lu

# default encryption (SSE-S3)
aws s3api put-bucket-encryption --bucket aws-waf-logs-p2-<ACCOUNT_ID>-us-east-1-an \
--server-side-encryption-configuration '{
    "Rules": [
        {
            "ApplyServerSideEncryptionByDefault": {
                "SSEAlgorithm": "AES256"
            }
        }
    ]
}' \
--region us-east-1 --profile lu
```

## Access Logging

Run after the access-logs bucket exists. It must share the origin's region (us-west-2) and is deliberately not replicated.

```bash
# block public access
aws s3api put-public-access-block --bucket p2-bucket-access-logs-<ACCOUNT_ID>-us-west-2-an \
--public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
--region us-west-2 --profile lu

# default encryption (SSE-S3)
aws s3api put-bucket-encryption --bucket p2-bucket-access-logs-<ACCOUNT_ID>-us-west-2-an \
--server-side-encryption-configuration '{
    "Rules": [
        {
            "ApplyServerSideEncryptionByDefault": {
                "SSEAlgorithm": "AES256"
            }
        }
    ]
}' \
--region us-west-2 --profile lu

# point the origin's server access logging at it
aws s3api put-bucket-logging --bucket p2-bucket-<ACCOUNT_ID>-us-west-2-an \
--bucket-logging-status '{
    "LoggingEnabled": {
        "TargetBucket": "p2-bucket-access-logs-<ACCOUNT_ID>-us-west-2-an",
        "TargetPrefix": "s3-access/"
    }
}' \
--region us-west-2 --profile lu
```

## After the Build

Run the verification checks: a direct S3 URL returns 403, HTTP redirects to HTTPS, WAF blocks appear under a load test, replication and delete-marker behavior confirmed on the replica, and Prowler returns zero remediable criticals. Run `nuke.sh` to tear down.
