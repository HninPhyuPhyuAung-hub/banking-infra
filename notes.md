# Deployment and Operations Notes

Practical setup and troubleshooting for dev. See [README.md](./README.md)
for the architecture and code overview.

## 1. Prerequisites

- Authorized AWS credentials for account `439475769687`, region `ap-southeast-1`.
- Terraform 1.11+, AWS CLI, and Git for local work.
- Existing S3/KMS/OIDC/IAM bootstrap:
  [infra/s3/notes.md](./infra/s3/notes.md). Do not recreate it.
- Frontend/backend images from
  [banking-app](https://github.com/HninPhyuPhyuAung-hub/banking-app).
- Session Manager plugin only if using ECS Exec.

Commit provider lock files, not state, saved plans, credentials, private
keys, or `.terraform` directories. State contains database secrets;
restrict access to the complete state objects.

## 2. GitHub configuration

| Location | Variable | Value |
|---|---|---|
| Repository Actions variables | `AWS_PLAN_ROLE_ARN` | `arn:aws:iam::439475769687:role/github-actions-banking-app-plan` |
| `infra-dev` environment variables | `AWS_APPLY_ROLE_ARN` | `arn:aws:iam::439475769687:role/github-actions-banking-app-apply` |

- Restrict `infra-dev` to `main`; configure reviewers when approval is needed.
- Protect `main` with PR review. Fork PRs do not run credentialed plans.
- Path-filtered required checks can remain pending on documentation-only PRs.
- Match OIDC trust to the exact token subject, including IDs when present;
  do not broaden it with wildcards. Environment subjects omit the branch.
- Plan can read state/secrets and manage locks; apply also provisions resources
  and writes state. Neither should delete state. Bootstrap IAM is maintained
  separately and the dev apply role is not production least privilege.

## 3. Deployment order

For a new environment, use **Actions -> Terraform -> Run workflow -> main**:

1. Select **pca** to create and activate the root CA.
2. Select **ecr** to create `banking-api` and `banking-dashboard`.
3. Publish both application images with the tag configured in
   [terraform.tfvars](./infra/envs/dev/terraform.tfvars), currently `latest`.
4. Select **dev** to deploy the application infrastructure.
5. Check service stability, target health, logs, API access, and DB access.

Dev requires PCA and ECR state. Until both exist, bootstrap PRs validate
dev but report its plan as **NOT RUN**. Rerun after deploying prerequisites.

For subsequent changes:

- Matching PRs plan all three stacks.
- Matching pushes to `main` apply **PCA -> ECR -> dev**, with configured
  environment approval.
- Manual selection runs one stack or **all** in the same order.
- Only `.tf`, `.tf.json`, `.tfvars`, `.tfvars.json` under `infra/`, provider
  lock files, [terraform-workflow.sh](./infra/terraform-workflow.sh), and
  [terraform.yml](./.github/workflows/terraform.yml) trigger automatic runs.
  Documentation-only changes do not.

Unchanged resources are not recreated. After a partial failure, review a
fresh plan against the same state; do not delete state to recover.

## 4. Application integration

| Container | Required setting | Source |
|---|---|---|
| Frontend | `ASPNETCORE_URLS=http://+:8081` | Terraform environment |
| Frontend | `BankingApi__BaseUrl=https://api.dev.banking.internal` | Terraform environment |
| Backend | `ASPNETCORE_URLS=http://+:8080` | Terraform environment |
| Backend | `ConnectionStrings__DefaultConnection` | Secrets Manager injection |

- The database secret is an Npgsql connection string, not JSON. Never print
  it. It requires TLS but does not enforce server certificate identity.
- Both containers must serve `/health` on their HTTP port. Redirect/proxy
  settings must allow probes; a running task is not necessarily healthy.
- Install the private CA root in the frontend trust store. Dashboard clients
  also need CA trust and private DNS access. The ALB's AWS hostname does not
  match the certificate.

An authorized operator can retrieve the public root certificate:

```bash
terraform -chdir=infra/pca init
terraform -chdir=infra/pca output -raw root_ca_certificate_pem > banking-root-ca.crt
```

Do not disable certificate validation to work around missing trust.

Updating `latest` requires an application rollout; it does not update
running tasks automatically. For a unique tag, update the task image
reference (for example `image_tag`). Coordinate application/Terraform
ownership so deployments do not overwrite each other's image selection.

## 5. Networking and capacity

- Traffic follows the [README request flow](./README.md#architecture).
  Tasks also reach private AWS endpoints/S3 image layers on TCP 443.
- No NAT gateways; no backend Internet Gateway; no initiated RDS outbound
  allowance. External APIs need separately reviewed connectivity.
- Each service starts at 2 tasks and scales from 1 to 4 at 60% CPU.
  Autoscaling owns desired count after creation.
- Deployment capacity is 100% minimum healthy / 200% maximum: temporary
  extra tasks are expected. Failed probes cause repeated replacements.
- RDS Multi-AZ provides a standby, not a read replica.

## 6. Logs and health verification

CloudWatch collects stdout/stderr with 14-day retention, not container
files. Streams use `<service>/<container>/<task-id>`. Never log secrets or
customer banking data.

Run these in separate terminals:

```bash
aws logs tail /ecs/banking-api --since 10m --follow --region ap-southeast-1
aws logs tail /ecs/banking-dashboard --since 10m --follow --region ap-southeast-1
```

Also check ECS events, stopped task reasons, and ALB target health.
Failures before logging starts may have no application logs.

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

Exec is enabled for both services. Use a newly deployed, running task with
`ExecuteCommandAgent=RUNNING`, the Session Manager plugin, and an operator
identity authorized for `ecs:ExecuteCommand` on the intended cluster/tasks:

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
endpoints across two AZs incur charges. Set budgets; this is not free-tier only.

There is no automatic destroy workflow. Review cleanup separately:

1. Remove dev first, intentionally handling RDS deletion protection and
   retaining its required final snapshot.
2. Retire PCA/ECR only when no environment depends on them. ECR deletion
   is blocked while repositories contain images; retain encryption keys
   while encrypted data/images are needed.
3. Preserve state and backups; remove the bootstrap bucket last, only
   when nothing relies on it.

For target-group replacements, use a new name: `create_before_destroy`
cannot create duplicate `frontend-tg`/`backend-tg` names. Do not manually
delete attached groups. Check regional availability before PostgreSQL upgrades.
