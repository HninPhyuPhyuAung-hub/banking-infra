# S3 State Bucket + GitHub OIDC Roles — one-time manual bootstrap

This is deliberately **not** Terraform. It creates the bucket that every
other config's remote backend depends on, so it can't be managed by a
Terraform config using that same backend (chicken-and-egg). Run this once,
by hand, per AWS account. PCA, ECR and dev then use the single Terraform
GitHub workflow, each with separate remote state.

Set these once at the top of your shell session, then copy/paste the rest:

```bash
export AWS_REGION=ap-southeast-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET_NAME="banking-app-tfstate-${ACCOUNT_ID}"   # must be globally unique
export KMS_ALIAS="alias/banking-app-tfstate"
export GITHUB_ORG="HninPhyuPhyuAung-hub" # owner only, not github.com
export GITHUB_REPO="banking-infra"      # repository name only, not owner/repo
export PLAN_ROLE_NAME="github-actions-banking-app-plan"
export APPLY_ROLE_NAME="github-actions-banking-app-apply"
```

## 1. Create the KMS key used to encrypt the state bucket

```bash
KMS_KEY_ID=$(aws kms create-key \
  --region "$AWS_REGION" \
  --description "Encrypts Terraform state for banking-app" \
  --query 'KeyMetadata.KeyId' --output text)

aws kms create-alias \
  --region "$AWS_REGION" \
  --alias-name "$KMS_ALIAS" \
  --target-key-id "$KMS_KEY_ID"

echo "KMS key: $KMS_KEY_ID"
```

## 2. Create the bucket

```bash
aws s3api create-bucket \
  --bucket "$BUCKET_NAME" \
  --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"
```

## 3. Enable versioning (lets you recover a previous state if something goes wrong)

```bash
aws s3api put-bucket-versioning \
  --bucket "$BUCKET_NAME" \
  --versioning-configuration Status=Enabled
```

## 4. Default encryption — SSE-KMS using the key from step 1

```bash
aws s3api put-bucket-encryption \
  --bucket "$BUCKET_NAME" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "aws:kms",
        "KMSMasterKeyID": "'"$KMS_KEY_ID"'"
      },
      "BucketKeyEnabled": true
    }]
  }'
```

## 5. Block all public access

```bash
aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

## 6. Bucket ownership controls (disables ACLs entirely — bucket owner always owns objects)

```bash
aws s3api put-bucket-ownership-controls \
  --bucket "$BUCKET_NAME" \
  --ownership-controls Rules='[{ObjectOwnership=BucketOwnerEnforced}]'
```

## 7. Bucket policy — deny any request that isn't HTTPS

```bash
aws s3api put-bucket-policy \
  --bucket "$BUCKET_NAME" \
  --policy '{
    "Version": "2012-10-17",
    "Statement": [{
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": ["arn:aws:s3:::'"$BUCKET_NAME"'", "arn:aws:s3:::'"$BUCKET_NAME"'/*"],
      "Condition": { "Bool": { "aws:SecureTransport": "false" } }
    }]
  }'
```

State locking does **not** need DynamoDB — Terraform >= 1.11's native S3
locking (`use_lockfile = true` in the backend block, already set in
`envs/dev/providers.tf` and `pca/providers.tf`) handles it via S3
conditional writes. Nothing further to create for that.

## 8. GitHub OIDC provider (lets GitHub Actions authenticate to AWS — no stored access keys)

```bash
aws iam create-open-id-connect-provider \
  --url "https://token.actions.githubusercontent.com" \
  --client-id-list "sts.amazonaws.com"
```

## 9. Two IAM roles with separate OIDC trust policies

| Role | Trusted OIDC subject | Access |
|---|---|---|
| Plan | This repository's `pull_request` jobs, without an environment | Read infrastructure and dev/PCA/ECR state; create/delete only the dev state lock |
| Apply | This repository's `infra-dev` environment jobs | Provision infrastructure and write dev state |

An environment job's OIDC subject is `environment:infra-dev`, **not**
`ref:refs/heads/main`. In GitHub, configure `infra-dev` to allow deployments
from **main only** and require reviewer approval. The environment protection
is what restricts the apply role to main; the AWS trust policy alone cannot
check the branch with this subject format. Do not use this environment on
the plan job.

If the GitHub OIDC provider already exists in your account, reuse it rather
than rerunning Step 8.

```bash
POLICY_DIR=$(mktemp -d)

cat > "$POLICY_DIR/plan-trust.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "repo:${GITHUB_ORG}/${GITHUB_REPO}:pull_request"
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name "$PLAN_ROLE_NAME" \
  --assume-role-policy-document "file://$POLICY_DIR/plan-trust.json" \
  --max-session-duration 3600

cat > "$POLICY_DIR/apply-trust.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "repo:${GITHUB_ORG}/${GITHUB_REPO}:environment:infra-dev"
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name "$APPLY_ROLE_NAME" \
  --assume-role-policy-document "file://$POLICY_DIR/apply-trust.json" \
  --max-session-duration 3600
```

## 10. Different permissions for plan and apply

The plan role is read-only for AWS infrastructure, but **not completely
read-only for S3/KMS**: Terraform must write/delete each stack's `.tflock`
and generate an encryption data key for that lock. It cannot overwrite or
delete any state file.

Plans can read sensitive data: Terraform state contains DB credentials,
and refreshing the secret version requires `secretsmanager:GetSecretValue`.
Only trusted contributors should run credentialed plans. The workflow skips
fork PRs; this does not make same-repository PR code safe automatically.

```bash
cat > "$POLICY_DIR/plan-permissions.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListStateBucket",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::${BUCKET_NAME}"
    },
    {
      "Sid": "ReadState",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": [
        "arn:aws:s3:::${BUCKET_NAME}/dev/terraform.tfstate",
        "arn:aws:s3:::${BUCKET_NAME}/pca/terraform.tfstate",
        "arn:aws:s3:::${BUCKET_NAME}/ecr/terraform.tfstate"
      ]
    },
    {
      "Sid": "StateLocks",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": [
        "arn:aws:s3:::${BUCKET_NAME}/dev/terraform.tfstate.tflock",
        "arn:aws:s3:::${BUCKET_NAME}/pca/terraform.tfstate.tflock",
        "arn:aws:s3:::${BUCKET_NAME}/ecr/terraform.tfstate.tflock"
      ]
    },
    {
      "Sid": "StateEncryptionAndLock",
      "Effect": "Allow",
      "Action": ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"],
      "Resource": "arn:aws:kms:${AWS_REGION}:${ACCOUNT_ID}:key/${KMS_KEY_ID}"
    },
    {
      "Sid": "ReadInfrastructure",
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*", "ecs:Describe*", "ecs:List*",
        "ecr:Describe*", "ecr:List*", "ecr:GetLifecyclePolicy",
        "elasticloadbalancing:Describe*", "rds:Describe*", "rds:ListTagsForResource",
        "kms:DescribeKey", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus", "kms:List*",
        "logs:Describe*", "logs:ListTagsForResource", "logs:ListTagsLogGroup",
        "application-autoscaling:Describe*",
        "acm:DescribeCertificate", "acm:GetCertificate", "acm:List*",
        "acm-pca:Describe*", "acm-pca:GetCertificate", "acm-pca:GetCertificateAuthorityCertificate",
        "acm-pca:GetCertificateAuthorityCsr", "acm-pca:List*",
        "route53:Get*", "route53:List*",
        "iam:GetRole", "iam:GetRolePolicy", "iam:GetPolicy", "iam:GetPolicyVersion",
        "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListRoleTags",
        "secretsmanager:DescribeSecret", "secretsmanager:ListSecretVersionIds",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    },
    {
      "Sid": "RefreshDatabaseSecret",
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT_ID}:secret:banking/rds/credentials-*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name "$PLAN_ROLE_NAME" \
  --policy-name "${PLAN_ROLE_NAME}-permissions" \
  --policy-document "file://$POLICY_DIR/plan-permissions.json"

cat > "$POLICY_DIR/apply-permissions.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListStateBucket",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::${BUCKET_NAME}"
    },
    {
      "Sid": "WriteState",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": [
        "arn:aws:s3:::${BUCKET_NAME}/dev/terraform.tfstate",
        "arn:aws:s3:::${BUCKET_NAME}/pca/terraform.tfstate",
        "arn:aws:s3:::${BUCKET_NAME}/ecr/terraform.tfstate"
      ]
    },
    {
      "Sid": "StateLocks",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": [
        "arn:aws:s3:::${BUCKET_NAME}/dev/terraform.tfstate.tflock",
        "arn:aws:s3:::${BUCKET_NAME}/pca/terraform.tfstate.tflock",
        "arn:aws:s3:::${BUCKET_NAME}/ecr/terraform.tfstate.tflock"
      ]
    },
    {
      "Sid": "StateKmsAccess",
      "Effect": "Allow",
      "Action": ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey"],
      "Resource": "arn:aws:kms:${AWS_REGION}:${ACCOUNT_ID}:key/${KMS_KEY_ID}"
    },
    {
      "Sid": "InfraProvisioning",
      "Effect": "Allow",
      "Action": [
        "ec2:*", "ecs:*", "ecr:*", "elasticloadbalancing:*", "rds:*",
        "secretsmanager:*", "kms:*", "logs:*", "application-autoscaling:*",
        "acm:*", "acm-pca:*", "route53:*",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ManageEcsRoles",
      "Effect": "Allow",
      "Action": [
        "iam:GetRole", "iam:CreateRole", "iam:DeleteRole", "iam:UpdateAssumeRolePolicy",
        "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PutRolePolicy",
        "iam:DeleteRolePolicy", "iam:GetRolePolicy", "iam:TagRole", "iam:UntagRole",
        "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListRoleTags"
      ],
      "Resource": [
        "arn:aws:iam::${ACCOUNT_ID}:role/banking-api-ecs-*",
        "arn:aws:iam::${ACCOUNT_ID}:role/banking-dashboard-ecs-*"
      ]
    },
    {
      "Sid": "PassEcsRoles",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": [
        "arn:aws:iam::${ACCOUNT_ID}:role/banking-api-ecs-*",
        "arn:aws:iam::${ACCOUNT_ID}:role/banking-dashboard-ecs-*"
      ],
      "Condition": {"StringEquals": {"iam:PassedToService": "ecs-tasks.amazonaws.com"}}
    },
    {
      "Sid": "ReadManagedPolicies",
      "Effect": "Allow",
      "Action": ["iam:GetPolicy", "iam:GetPolicyVersion"],
      "Resource": "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
    },
    {
      "Sid": "CreateRequiredServiceLinkedRoles",
      "Effect": "Allow",
      "Action": "iam:CreateServiceLinkedRole",
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/aws-service-role/*",
      "Condition": {
        "StringEquals": {
          "iam:AWSServiceName": [
            "ecs.amazonaws.com", "elasticloadbalancing.amazonaws.com",
            "rds.amazonaws.com", "ecs.application-autoscaling.amazonaws.com",
            "acm.amazonaws.com"
          ]
        }
      }
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name "$APPLY_ROLE_NAME" \
  --policy-name "${APPLY_ROLE_NAME}-permissions" \
  --policy-document "file://$POLICY_DIR/apply-permissions.json"

rm -f "$POLICY_DIR/plan-trust.json" "$POLICY_DIR/apply-trust.json" \
  "$POLICY_DIR/plan-permissions.json" "$POLICY_DIR/apply-permissions.json"
rmdir "$POLICY_DIR"
```

The apply policy intentionally retains broad service-level provisioning
permissions for this dev assignment; it is **not production least privilege**.
Its IAM management is limited to the app's ECS roles, not the GitHub roles.
The plan role can read all three state files and manage only their locks.
The apply role can write all three state files and manage their locks,
but neither role can delete state files. To enable the unified workflow,
rerun both `put-role-policy` commands with the updated permission documents;
do not recreate the bucket or roles. Existing AWS policies are not updated
automatically when this documentation changes.

### Migrating from the old shared role

If you already ran the old instructions, keep the bucket, KMS key and OIDC
provider. Retrieve the existing encryption key ID instead of creating another:

```bash
KMS_KEY_ID=$(aws kms describe-key --key-id "$KMS_ALIAS" \
  --region "$AWS_REGION" --query 'KeyMetadata.KeyId' --output text)
```

Run Steps 9-10 to create the two new roles, then change the GitHub variables
below. If the new roles already exist, use `aws iam update-assume-role-policy`
with the corresponding trust document instead of `create-role`;
`put-role-policy` updates their existing inline policy. After verifying both
workflows, remove the old shared role's inline policy and the old role
(`github-actions-banking-app`) to retire its access. Do not rerun the bucket
creation steps.

## 11. Note down the outputs you'll need next

```bash
echo "Bucket name:   $BUCKET_NAME"
echo "Plan role ARN: arn:aws:iam::${ACCOUNT_ID}:role/${PLAN_ROLE_NAME}"
echo "Apply role ARN: arn:aws:iam::${ACCOUNT_ID}:role/${APPLY_ROLE_NAME}"
```

- **Bucket name** → paste into the `backend "s3" { bucket = ... }` block in
  [`../envs/dev/providers.tf`](../envs/dev/providers.tf),
  [`../pca/providers.tf`](../pca/providers.tf), and
  [`../ecr/providers.tf`](../ecr/providers.tf), and into both
  `terraform_remote_state` blocks in
  [`../envs/dev/main.tf`](../envs/dev/main.tf).
- **Plan role ARN** → repository variable `AWS_PLAN_ROLE_ARN`.
- **Apply role ARN** → environment variable `AWS_APPLY_ROLE_ARN` in the
  protected `infra-dev` GitHub environment. Remove the obsolete
  `AWS_ROLE_TO_ASSUME` variable after migration. See
  [`../notes.md`](../notes.md) for the full GitOps setup.

Return to [`../notes.md`](../notes.md) and continue from Step 2.

## Tearing this down (only once nothing else needs this bucket/role)

```bash
aws iam delete-role-policy --role-name "$PLAN_ROLE_NAME" --policy-name "${PLAN_ROLE_NAME}-permissions"
aws iam delete-role --role-name "$PLAN_ROLE_NAME"
aws iam delete-role-policy --role-name "$APPLY_ROLE_NAME" --policy-name "${APPLY_ROLE_NAME}-permissions"
aws iam delete-role --role-name "$APPLY_ROLE_NAME"
aws iam delete-open-id-connect-provider \
  --open-id-connect-provider-arn "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

# Bucket must be emptied (including all versions) before it can be deleted
aws s3api delete-objects --bucket "$BUCKET_NAME" \
  --delete "$(aws s3api list-object-versions --bucket "$BUCKET_NAME" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}')"
aws s3api delete-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION"

aws kms schedule-key-deletion --key-id "$KMS_KEY_ID" --pending-window-in-days 7
aws kms delete-alias --alias-name "$KMS_ALIAS"
```
