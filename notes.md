# Deployment and Operations Notes

See [README.md](./README.md) for the problem statement, requirements,
architecture, and code overview. These notes cover operating the dev
infrastructure; they do not assert that a deployment is currently healthy.

## 1. Prerequisites

- An AWS account and authorized credentials; configuration currently targets
  account `439475769687`, region `ap-southeast-1`.
- Terraform 1.11 or later for local work, AWS CLI, and Git.
- The existing S3/KMS/OIDC/IAM bootstrap described in
  [infra/s3/notes.md](./infra/s3/notes.md). Do not recreate existing resources.
- Two container images published from
  [banking-app](https://github.com/HninPhyuPhyuAung-hub/banking-app).
- Session Manager plugin only if using ECS Exec.

Commit provider lock files. Never commit `.terraform` directories, state,
saved plans, credentials, or private keys. Terraform state contains
database secrets even though runtime injection uses Secrets Manager.
Remote-state readers can read complete state objects, not only outputs.

## 2. GitHub configuration

| Location | Variable | Value |
|---|---|---|
| Repository Actions variables | `AWS_PLAN_ROLE_ARN` | `arn:aws:iam::439475769687:role/github-actions-banking-app-plan` |
| `infra-dev` environment variables | `AWS_APPLY_ROLE_ARN` | `arn:aws:iam::439475769687:role/github-actions-banking-app-apply` |

Restrict `infra-dev` deployments to `main` and configure required reviewers
when approval is needed. Protect `main` with PR review. Fork PRs do not run
credentialed plans. Do not make path-filtered checks mandatory for all
PRs without handling documentation-only changes: skipped workflows can
leave required checks pending.

OIDC trust must match actual repository/environment token subjects.
GitHub may include repository/owner IDs in the subject; use the exact
observed subject, not a broad wildcard. The environment subject does not
include the branch, so environment branch restrictions matter.

The plan role reads infrastructure, state, and required secrets and manages
locks; it cannot write state. The apply role provisions infrastructure and
writes all three states. Neither role should delete state objects.
Bootstrap IAM policies are maintained separately; editing documentation
does not update AWS permissions. The dev provisioning role is not a
production least-privilege design.

## 3. Deployment order

For a new environment, use **Actions -> Terraform -> Run workflow -> main**:

1. Select **pca** to create and activate the root CA.
2. Select **ecr** to create `banking-api` and `banking-dashboard`.
3. Publish both application images with the tag configured in
   [terraform.tfvars](./infra/envs/dev/terraform.tfvars), currently `latest`.
4. Select **dev** to deploy the application infrastructure.
5. Check service stability, target health, logs, API access, and DB access.

PCA and ECR are independently state-managed; dev requires both state
objects. On bootstrap PRs, dev init/validate runs but the plan is explicitly
**NOT RUN** if prerequisite state is absent. Rerun after both stacks exist.
Permission and network failures are not treated as missing state.

For subsequent changes:

- Matching PRs plan all three stacks.
- Matching pushes to `main` apply **PCA -> ECR -> dev**, with configured
  environment approval.
- Manual selection runs one stack or **all** in the same order.
- Only `.tf`, `.tf.json`, `.tfvars`, `.tfvars.json` under `infra/`, provider
  lock files, [terraform-workflow.sh](./infra/terraform-workflow.sh), and
  [terraform.yml](./.github/workflows/terraform.yml) trigger automatic runs.
  Documentation-only changes do not.

Applying all stacks does not recreate unchanged resources. After a partial
failure, review a new full plan against the same state; do not delete state
or manually recreate resources as a recovery shortcut.

## 4. Application integration

| Container | Required setting | Source |
|---|---|---|
| Frontend | `ASPNETCORE_URLS=http://+:8081` | Terraform environment |
| Frontend | `BankingApi__BaseUrl=https://api.dev.banking.internal` | Terraform environment |
| Backend | `ASPNETCORE_URLS=http://+:8080` | Terraform environment |
| Backend | `ConnectionStrings__DefaultConnection` | Secrets Manager injection |

The database secret holds a single Npgsql connection string, not JSON.
Do not print it during troubleshooting. The current connection string
requires TLS but trusts the server certificate; certificate identity
verification is not enforced by that setting.

Both applications must return a successful response at `/health` over
their configured HTTP container port. A running container alone does not
mean its ALB target is healthy. Proxy/HTTPS-redirection configuration must
also allow health probes to succeed.

Install the private CA root in the frontend image's trust store before
calling the API. Browsers/operators also need CA trust and private DNS
access for the configured dashboard hostname. The ALB's AWS hostname does
not match the private certificate.

An authorized operator can retrieve the public root certificate:

```bash
terraform -chdir=infra/pca init
terraform -chdir=infra/pca output -raw root_ca_certificate_pem > banking-root-ca.crt
```

This exports the public certificate, not a private key. Do not disable
application certificate validation to work around missing trust.

Image pushes are separate from Terraform. Updating `latest` does not
update running tasks; the application pipeline must force a rollout.
For a unique tag, update the task-definition image reference, for example
through an `image_tag` change in this repository. Coordinate ownership so
application deployments and Terraform do not overwrite each other's image
selection.

## 5. Networking and capacity

| Source | Allowed destination | TCP port |
|---|---|---|
| Client | Frontend public ALB | 443 |
| Frontend ALB | Frontend tasks | 8081 |
| Frontend tasks | Backend internal ALB over peering | 443 |
| Backend ALB | Backend tasks | 8080 |
| Backend tasks | RDS | 5432 |
| Each task tier | Its private AWS endpoint security group | 443 |
| Each task tier | Regional S3 prefix list for image layers | 443 |

RDS has no initiated outbound allowance. Security groups are stateful.
No NAT gateways are configured, and the backend has no Internet Gateway.
Interface endpoint policies use AWS defaults; IAM and task-only endpoint
security groups still control access. Unrelated external APIs require
separately reviewed connectivity.

Each service starts with two tasks, scales from 1 to 4 at a 60% CPU target,
and ignores Terraform desired-count changes after creation. Deployments
allow 100% minimum healthy and 200% maximum capacity, so temporary extra
tasks are expected. Failed health checks can cause repeated replacements.
PostgreSQL Multi-AZ provides a standby, not a read replica.

## 6. Logs and health verification

CloudWatch groups `/ecs/banking-api` and `/ecs/banking-dashboard` collect
container stdout/stderr with 14-day retention. Stream names contain
`<service>/<container>/<task-id>`. Container files are not automatically
collected. Do not log tokens, credentials, or customer banking data.

Run these in separate terminals:

```bash
aws logs tail /ecs/banking-api --since 10m --follow --region ap-southeast-1
aws logs tail /ecs/banking-dashboard --since 10m --follow --region ap-southeast-1
```

Check ECS service events, stopped task reasons, and ALB target health.
Failures before the log driver starts may have no application logs.
Typical symptoms:

| Symptom | Check |
|---|---|
| `CannotPullContainerError` / tag not found | Correct ECR repository and published tag |
| ALB health response `404` | `/health` endpoint exists in the deployed image |
| Database hostname resolution failure | Injected connection string and VPC DNS |
| API certificate trust failure | Private CA installed in frontend trust store |
| GitHub waiter exceeds maximum attempts | ECS events/target health; do not simply increase the timeout |

From a host with associated-VPC connectivity and private DNS:

```bash
curl --cacert banking-root-ca.crt https://api.dev.banking.internal/health
```

## 7. ECS Exec

Both services enable ECS Exec, task-role `ssmmessages` channel permissions,
private `ssmmessages` endpoints, and a container init process. Existing
tasks cannot be retrofitted: deploy new tasks with Exec enabled. The task
must remain running and `ExecuteCommandAgent` must report `RUNNING`.

Use an operator identity permitted to run `ecs:ExecuteCommand` on the
intended cluster/tasks, with the Session Manager plugin installed:

```bash
aws ecs execute-command \
  --cluster backend-cluster \
  --task TASK_ID \
  --container banking-api \
  --interactive \
  --command "/bin/sh" \
  --region ap-southeast-1
```

Replace `TASK_ID` with a running task ID. For frontend use cluster
`frontend-cluster` and container `banking-dashboard`. The image must have
the requested shell. Exec runs as root; restrict access and do not print
secrets. Dedicated session transcript logging is not configured.

## 8. Costs and cleanup

Private CA, ALBs, Multi-AZ RDS, Fargate, logs, KMS, and nine interface
endpoints across two AZs incur ongoing charges. Check current AWS pricing
and configure budgets; this is not a free-tier-only design.

There is no automatic destroy workflow. Review cleanup separately:

1. Remove dev first, intentionally handling RDS deletion protection and
   retaining its required final snapshot.
2. Retire PCA/ECR only when no environment depends on them. ECR deletion
   is blocked while repositories contain images; retain encryption keys
   while encrypted data/images are needed.
3. Preserve state and backups; remove the bootstrap bucket last, only
   when nothing relies on it.

Target groups use `ip` with fixed names `frontend-tg` and `backend-tg`.
For a replacement that needs a new target group, choose a new name:
`create_before_destroy` cannot create two groups with the same name.
Do not delete groups attached to listeners/services manually. Check
regional PostgreSQL version availability before changing engine versions.
