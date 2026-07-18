# Edge Hardening

### Origin Lockdown | Layer 7 Filtering | HTTPS Enforcement
---

A static site served only through CloudFront, with the S3 origin locked so it cannot be reached directly. HTTPS is enforced end to end on a custom domain. AWS WAF filters at the edge with a managed rule set and per-IP rate limiting. Every bucket is encrypted, the origin is versioned and replicated to a second region for disaster recovery, and access to the origin is logged. Prowler verifies zero remediable critical findings. `setup.md` rebuilds the configuration; `nuke.sh` tears it down clean.

**Domain** · lumengistu.com (+ www) \
**Edge region** · us-east-1 (CloudFront, WAF, ACM) \
**Origin region** · us-west-2 \
**DR region** · us-east-1 (replica)

## What Was Built

**Origin unreachable except through CloudFront** \
The S3 origin bucket has Block Public Access on all four settings and ACLs disabled, so nothing is public and no object ACL can re-expose it. The only principal allowed to read it is CloudFront, and not CloudFront broadly: the bucket policy grants `s3:GetObject` to the `cloudfront.amazonaws.com` service principal but pins it with a `StringEquals` condition on `AWS:SourceArn` set to the exact distribution ARN. Without that condition the service principal trusts every CloudFront distribution on earth, so any stranger could front the bucket with their own distribution. The condition narrows it to this one. A request straight to the S3 REST endpoint returns 403 because it carries no matching distribution ARN.

**Origin Access Control, not the legacy OAI** \
CloudFront reaches the origin with OAC, which signs each request to S3. This requires the bucket's REST endpoint, not the static-website endpoint — the website endpoint serves openly and cannot validate a signed request, so pointing the origin at it silently breaks the lock. Static website hosting is deliberately left off for that reason.

**HTTPS on a custom domain** \
The distribution serves lumengistu.com and www.lumengistu.com as alternate domain names with an ACM certificate provisioned in us-east-1, the only region CloudFront reads certificates from. The cert is DNS-validated via CNAME records at the registrar and reused across rebuilds. At Namecheap the apex points to the distribution with an ALIAS/ANAME record and www with a CNAME, since a bare domain cannot be a CNAME. The viewer protocol policy redirects HTTP to HTTPS so nothing is served in the clear.

**WAF filtering at the edge** \
A Web ACL, CLOUDFRONT scope in us-east-1, carries the AWS managed Core rule set and a rate-based rule at 50 requests per 5-minute window per source IP. The managed rules inspect request content for common attack classes; the rate rule blocks floods and cost-exhaustion regardless of content. Logs are delivered to a bucket with the required `aws-waf-logs-` prefix, and the Web ACL is explicitly associated with the distribution — creating the ACL protects nothing until it is attached.

**Encryption at rest** \
Every bucket uses SSE-S3 default encryption. SSE-S3 is sufficient for public static content — AWS manages the keys at no cost — where the key ownership, per-decrypt audit trail, and revocation kill-switch of SSE-KMS would buy nothing. The content is public anyway, so there is nothing secret to protect with heavier key controls.

**Versioning, replication, and DR** \
The origin is versioned, with a lifecycle rule expiring noncurrent versions after 30 days so overwrites do not accumulate and bill indefinitely. It replicates cross-region to a bucket in us-east-1 under a V2 replication rule with delete-marker replication disabled, so a delete on the origin does not propagate to the replica. Writes replicate; deletes do not. That asymmetry is what makes the replica a safe DR copy rather than a mirror — a ransomware wipe or accidental deletion on the origin leaves the replica intact to restore from.

**Access logging** \
The origin's S3 server access logs are delivered to a dedicated logging bucket in the same region, us-west-2, under an `s3-access/` prefix. The log bucket must share the source region, and it is deliberately not replicated — replicating logs creates a cost loop and log confusion.

**Compliance baseline** \
Prowler scans us-east-1 and us-west-2 and returns zero remediable critical findings. The single reported critical, AdministratorAccess on the SSO permission set, is an accepted gap for a solo learning account. The terminal summary table is read as the source of truth rather than the HTML severity count, which inflates the critical number by counting passed checks on critical-severity controls.

## How to Use

Follow the manual console steps called out in `setup.md` for the pieces that cannot be scripted: creating the buckets, the CloudFront distribution, the ACM certificate, the WAF Web ACL, and the custom-domain records at the registrar. Then run the scripted portions of `setup.md` to apply the bucket policies, encryption, versioning, replication, lifecycle, and logging configuration.

`setup.md` is a guided reference, not a one-shot runnable script. Before use, substitute your own `<DISTRIBUTION_ID>` and `<ACCOUNT_ID>` — the distribution ID changes on every rebuild and must be reconciled in both the origin bucket policy and `nuke.sh`.

To tear down, run `nuke.sh`. It requires typing `NUKE` to confirm before touching anything. It disassociates the Web ACL from the distribution, disables and waits for the distribution to finish deploying before deleting it, deletes the Web ACL, then empties and deletes all four buckets in dependency order. The two versioned buckets are emptied in three passes — current objects, then versions, then delete markers — because a recursive remove on a versioned bucket only lays down delete markers while the real versions persist underneath.

## Verification

**Origin privacy** \
A direct request to the S3 REST endpoint returns 403; the site is reachable only through the CloudFront domain.

**HTTPS enforcement** \
An HTTP request to the CloudFront domain redirects to HTTPS. lumengistu.com loads over HTTPS with a valid certificate, and the direct cloudfront.net URL still resolves.

**WAF blocking** \
A load test exceeding the rate threshold produces 403 blocks, visible in sampled requests and delivered to the WAF logging bucket.

**OAC integrity** \
The bucket policy principal is `cloudfront.amazonaws.com` and the condition is scoped to the exact distribution ARN with no wildcards.

**Replication and DR behavior** \
An object uploaded after the replication rule appears in the replica within minutes. Deleting it from the origin leaves the replica copy intact, confirming delete markers do not propagate under the V2 rule.

**Compliance baseline** \
Prowler scanning us-east-1 and us-west-2 returns zero remediable critical findings. The single critical it reports — AdministratorAccess on the SSO permission set — is an accepted gap for a solo learning account.

**Clean-slate teardown** \
`nuke.sh` removes the distribution, Web ACL, and all buckets with no orphaned billable resources, and the stack rebuilds from `setup.md` plus the console prerequisites.

## Known Gaps

The AdministratorAccess policy on the SSO permission set is flagged critical by Prowler and accepted here: this is a single-principal learning account with a budget cap and no sensitive data, so scoping least-privilege per project buys no real security. In production this becomes a scoped permission set with admin assumed only when needed, so a credential compromise does not hand over the entire account.

There is no SNS alert on WAF block spikes, no GuardDuty on S3 data events, and no automated response to a traffic flood. The controls block and log; nothing notifies or reacts automatically. Detection and automated response are built in Set 4.

The replica is protected against a standard origin-side delete propagating, but not against a versioned delete or direct tampering with the replica bucket itself. Object Lock is the control that closes that and is introduced in Project 3: VPC Defense.

`setup.md` is a guided rebuild, part manual, not a one-shot automated deploy, and its hardcoded resource names and distribution ID must be reconciled on each rebuild. The distribution ID in particular must match between the origin bucket policy and `nuke.sh`. Full automation with tracked state arrives with Terraform in Set 3.
