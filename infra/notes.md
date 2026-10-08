# Banking infrastructure: setup and deployment

All regional resources use `ap-southeast-1`. Git is the source of the
Terraform configuration. One workflow, [Terraform](../.github/workflows/terraform.yml),
manages PCA, ECR and dev. Only the S3/IAM bootstrap remains outside Terraform.
Deployments are selected explicitly in GitHub Actions, not automatically on merge.

## Architecture and state

```text
Internet -> public frontend ALB -> private frontend ECS tasks
          -> internal HTTPS backend ALB -> private backend ECS tasks
          -> isolated PostgreSQL RDS subnets
```

The frontend VPC is `10.0.0.0/16`; the backend VPC is `192.168.0.0/16`.
They use same-region VPC peering. Both task tiers have no public IP and
no NAT gateway. The frontend ALB is the only public application entry point.
The backend VPC has no public subnets or Internet Gateway. Its AWS-service
access uses private endpoints; only the frontend VPC retains an Internet
Gateway and public subnets for its public ALB.
Only the application private-subnet route tables participate in peering.
Database subnet route tables retain local VPC routing only: backend tasks
reach RDS locally, and RDS does not need a route to the frontend VPC.

| Configuration | Remote state key | Resources |
|---|---|---|
| [pca](./pca/) | `pca/terraform.tfstate` | Root CA, activation, ACM permissions |
| [ecr](./ecr/) | `ecr/terraform.tfstate` | API/dashboard repositories, KMS key, lifecycle policies |
| [dev](./envs/dev/) | `dev/terraform.tfstate` | VPCs, endpoints, DNS, certificates, ALBs, ECS, RDS |

All three use `banking-app-tfstate-439475769687`, encrypted with KMS,
versioned and protected from public access. Each state has its own native
S3 lock file; DynamoDB is not used. Commit provider lock files, never
state or saved plan files.

Dev reads PCA's CA ARN and ECR's repository URLs automatically using
`terraform_remote_state`. No manual ARN/URL entry is needed. Reading remote
state permits access to the complete state object, not just its outputs.

## 1. Bootstrap once

Follow [s3/notes.md](./s3/notes.md) for the bucket, encryption key, OIDC
provider and separate plan/apply roles. These resources have already been
created in account `439475769687`; do not delete/recreate them.

Both existing role inline policies have been updated in AWS for the unified
workflow and verified with IAM simulation. Step 10 of the bootstrap notes
documents these permissions for rebuilding or updating them:

| Capability | Plan role | Apply role |
|---|---|---|
| Read dev/PCA/ECR state | Yes | Yes |
| Create/read/delete all three lock files | Yes | Yes |
| Write dev/PCA/ECR state | No | Yes |
| Delete state files | No | No |
| Provision infrastructure | No | Yes |

Documentation changes do not automatically update AWS IAM. The apply
policy retains broad service-level permissions for this dev assignment,
not production least privilege. Plans can read DB secrets and sensitive
state, so only trusted contributors should run credentialed PR checks.

## 2. Configure GitHub

1. Commit and push this configuration, including
   [terraform.yml](../.github/workflows/terraform.yml) and
   [terraform-workflow.sh](./terraform-workflow.sh). The dispatch workflow
   must be on `main` before its **Run workflow** button is available.
2. Set the repository Actions variable:
   `AWS_PLAN_ROLE_ARN = arn:aws:iam::439475769687:role/github-actions-banking-app-plan`.
3. Create/protect the `infra-dev` environment with **main-only deployment
   branches** and **required reviewer approval**. Set its variable:
   `AWS_APPLY_ROLE_ARN = arn:aws:iam::439475769687:role/github-actions-banking-app-apply`.
4. Protect `main` with PR review and the checks `Plan (pca)`, `Plan (ecr)`,
   and `Plan (dev)`.

The plan role trusts this repo's PR subject. The apply role trusts its
`environment:infra-dev` subject, which does not contain a branch; environment
branch protection is therefore essential. The deploy job also rejects
non-main dispatches. Fork PRs do not receive credentialed plans.

## 3. First deployment: PCA, then ECR

In GitHub: **Actions -> Terraform -> Run workflow**, select branch `main`.

1. Select stack **pca**, run and approve the environment deployment.
   This creates/activates the CA and saves its remote state.
2. Select stack **ecr**, run and approve.
   This creates the two repositories and saves their remote state.

PCA and ECR are independent, but both must exist before dev can plan.
AWS Private CA in general-purpose mode has significant ongoing cost
(approximately $400/month per active CA, plus issuance fees; verify current
AWS pricing). Do not leave it running unintentionally.

ECR Terraform creates repositories, KMS encryption, scan-on-push and a
policy expiring untagged images after seven days. **It never builds or
pushes application images.**

Before initial PCA/ECR deployment, the PR dev job still initializes and
validates Terraform but reports **Dev plan NOT RUN** if either prerequisite
state is missing. This is an explicit bootstrap exception, not a successful
dev plan. After deploying both stacks, rerun the PR checks to obtain a real
dev plan. Permission/network errors are not treated as missing state.

## 4. Application pipeline publishes images

The application projects, Dockerfiles and build/push pipeline are not
implemented yet. This is a separate deliverable. The future application
pipeline must build/test both images and push tags matching `image_tag`
in [dev/terraform.tfvars](./envs/dev/terraform.tfvars), currently `latest`.
Publish both images before deploying dev; otherwise ECS tasks cannot start.

Use a separate application deployment role. ECR push requires
`ecr:GetAuthorizationToken` on `*` and repository-scoped
`ecr:BatchCheckLayerAvailability`, `ecr:InitiateLayerUpload`,
`ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`, and `ecr:PutImage`.
The Terraform workflow has no image build/push steps.

### Private CA trust

The frontend calls `https://api.dev.banking.internal` using a separate
PCA-issued ACM certificate on the backend ALB. Private CA roots are not
automatically trusted by .NET or browsers. Install the public root
certificate in the frontend image's OS trust store during the build.
For Debian-based .NET images, copy it into
`/usr/local/share/ca-certificates/` and run `update-ca-certificates`.
Never disable HttpClient certificate validation or distribute private keys.

The public root certificate is available as PCA's `root_ca_certificate_pem`
output. An authorized build operator can retrieve it after backend init:

```bash
terraform -chdir=infra/pca init
terraform -chdir=infra/pca output -raw root_ca_certificate_pem > banking-root-ca.crt
```

This reads an output; it does not apply PCA locally. Integrate public-root
retrieval into the future image pipeline with explicitly authorized access.

## 5. Deploy dev

Open a PR to `main` changing Terraform configuration. All three stack plans
run automatically, with plans in job logs and results in the run summary.
Review the plans and merge. Matching pushes to `main` deploy all three stacks
in order, subject to the protected environment's approval rules.

Push and PR triggers match only `infra/**/*.tf`, `infra/**/*.tf.json`,
`infra/**/*.tfvars`, `infra/**/*.tfvars.json`,
`infra/**/.terraform.lock.hcl`, `infra/terraform-workflow.sh`, and
`.github/workflows/terraform.yml`. README/notes-only changes do not trigger
the workflow; mixed documentation and matching code changes still do.
Avoid requiring a path-filtered workflow as a mandatory check for
documentation-only PRs: skipped workflows can leave required checks pending.

Manual runs remain available regardless of changed paths:
**Actions -> Terraform -> Run workflow -> main -> dev**, and approve
the protected environment deployment if required.

Dev creates networking, private endpoints, DNS, both ALB certificates,
ALBs, ECS and RDS, using PCA/ECR remote-state outputs. Both ECS services
start with two tasks; CPU target tracking at 60% scales each from one to
four tasks. Actual healthy task counts must be verified after deployment.

For later changes touching all stacks, select **all**. It runs
**PCA -> ECR -> dev sequentially** and stops on the first error. Use
individual selections for bootstrap so application images can be published
before dev. Each deployment generates a fresh saved plan for the checked-out
main commit and applies that exact plan. PR plans are previews, not the
deployment artifact. Concurrent deploy runs are serialized; state locking
also protects against overlapping PR plans.

## 6. Network restrictions and verification

| Source | Allowed outbound destination | TCP port |
|---|---|---|
| Frontend ALB | Frontend tasks' security group | Frontend container port |
| Frontend tasks | Backend ALB's security group over peering | 443 |
| Backend ALB | Backend tasks' security group | Backend container port |
| Backend tasks | RDS security group | 5432 |
| Both task tiers | Their private AWS endpoint security group | 443 |
| Both task tiers | Regional S3 prefix list for ECR image layers | 443 |
| RDS | No initiated outbound connections | None |

Fargate exceptions: ECR API/Docker, CloudWatch Logs and ECS Exec
(`ssmmessages`) interface endpoints
in both VPCs, Secrets Manager in backend, and S3 gateway endpoints whose
policies permit only reads of the regional ECR image-layer bucket.
Nine interface endpoints across two AZs incur hourly/data charges.
Interface endpoint policies use AWS defaults; their security groups accept
only the corresponding task tier. IAM still controls AWS API operations.

Security groups are stateful; replies do not need extra egress. VPC DNS
is not filtered by security groups (use Resolver DNS Firewall if required).
External APIs/identity providers need separately reviewed access.
TLS terminates at each ALB; ALB-to-task connections remain HTTP.

After deployment verify image pulls, logs, secret injection, healthy tasks,
frontend-to-API HTTPS with CA trust, and DB access. From an associated VPC:

```bash
curl --cacert banking-root-ca.crt https://api.dev.banking.internal/health
```

Both VPCs are associated with the private zone. Peering does not give a
laptop private DNS access. Connecting to an ALB's AWS hostname does not
match the private certificate's name.

For updates to an existing mutable image tag, the application pipeline
must force an ECS deployment after pushing. For immutable tags, update
`image_tag` via a PR and run the dev deployment. Terraform does not detect
image-content changes behind an unchanged tag.

## 7. ECS task logs

Both task definitions already use the `awslogs` driver to send container
stdout/stderr to CloudWatch Logs in `ap-southeast-1`:

| Service | Log group | Retention |
|---|---|---|
| Backend API | `/ecs/banking-api` | 14 days |
| Frontend dashboard | `/ecs/banking-dashboard` | 14 days |

Each task has its own stream named `<service>/<container>/<task-id>`.
The execution role grants log delivery permissions, and private Logs
endpoints allow delivery without NAT or internet access. Application logs
must be written to stdout/stderr; files inside containers are not collected.
Do not log passwords, connection strings, tokens, or customer banking data.

Open **CloudWatch -> Logs -> Log groups** and choose the service's group,
or follow recent logs with AWS CLI credentials that permit log reads:

```bash
aws logs tail /ecs/banking-api --since 10m --follow --region ap-southeast-1
aws logs tail /ecs/banking-dashboard --since 10m --follow --region ap-southeast-1
```

Run each follow command in a separate terminal. Dev exports
`backend_ecs_log_group_name` and `frontend_ecs_log_group_name` after apply.
Image-pull or startup failures before logging initializes may have no
application logs; inspect ECS service events and stopped task reasons too.

## 8. ECS Exec

Both services enable ECS Exec. Task roles grant the four required
`ssmmessages` channel actions (these actions require resource `*`).
Each VPC has a private `ssmmessages` endpoint using the existing
task-only HTTPS security-group rules; no internet access is added.
Containers enable the init process to reap ECS Exec agent child processes.

Apply the dev stack to deploy this configuration. The task-definition
change rolls out new tasks; existing tasks cannot be retrofitted with ECS
Exec. A task must stay running and its `ExecuteCommandAgent` must report
`RUNNING` before a session can connect.

Install the AWS Session Manager plugin on your workstation and use an
operator identity authorized for `ecs:ExecuteCommand` on the intended
cluster/tasks. The CI image-push role is not an operator role. To open a
backend shell, replace `TASK_ID` with a running task's ID:

```bash
aws ecs execute-command \
  --cluster backend-cluster \
  --task TASK_ID \
  --container banking-api \
  --interactive \
  --command "/bin/sh" \
  --region ap-southeast-1
```

For frontend use cluster `frontend-cluster` and container
`banking-dashboard`. The image must contain the requested shell. ECS Exec
runs as root, so restrict operator access and avoid printing secrets.
Application stdout/stderr logging remains enabled; this change does not
configure dedicated ECS Exec session transcript logging.

## Teardown and existing-state migration

Fargate uses `awsvpc` networking, so both ALB target groups use target
type `ip`. Target groups are named `frontend-tg` and `backend-tg`.
Renaming the previous generated-name groups requires replacement;
`create_before_destroy` creates the newly named groups before switching
listeners and ECS services. ECS creation waits for the listener association.
For future replacement changes that retain the same fixed name, choose a
new target-group name first: AWS cannot create two groups with the same
name, and `create_before_destroy` cannot bypass that uniqueness constraint.
Do not manually delete groups attached to listeners or ECS services.

The PostgreSQL default is `15.19`, verified available in `ap-southeast-1`
for `db.t3.micro` with Multi-AZ and gp3. Verify regional version availability
again before future deployments; older minor versions may be retired.
After a failed partial apply, rerun a full plan/apply against the same
remote state. Do not delete state or recreate resources by hand.

Peering routes use stable list-index keys so a first plan can include
route tables whose AWS IDs are not known yet. Keep route-table input order
stable. If migrating an already-applied older configuration keyed by
route-table IDs, move each existing route's state address to its matching
index before applying; otherwise Terraform will plan route replacement.
Requester routes target the backend CIDR, and accepter routes target the
frontend CIDR.

There is deliberately no one-click destroy workflow. Review teardown
separately: remove dev first (disable RDS deletion protection intentionally
and retain the required final snapshot), then retire PCA/ECR if unused.
ECR has `force_delete = false`; populated repositories must be explicitly
emptied before destruction. Preserve the image KMS key while images need it.
Delete the state bucket last, only when nothing requires its state/history.

If dev was already applied before the ECR split, migrate its ECR key,
repositories and lifecycle policies to ECR state before deploying this
refactor. Back up both states and verify no deletion/recreation is planned.
A Terraform `moved` block cannot transfer resources between separate states.
For existing deployments, also review NAT removal and security-group rule
replacement carefully; startup may retry while rules are being created.
