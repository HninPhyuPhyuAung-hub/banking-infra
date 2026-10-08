#!/usr/bin/env bash
set -euo pipefail

action="${1:?Expected plan or apply}"
stack="${2:?Expected pca, ecr, dev or all}"

case "$action" in
  plan|apply) ;;
  *) echo "::error::Unknown action: $action"; exit 1 ;;
esac

case "$stack" in
  pca|ecr|dev) stacks=("$stack") ;;
  all) stacks=(pca ecr dev) ;;
  *) echo "::error::Unknown stack: $stack"; exit 1 ;;
esac

for current in "${stacks[@]}"; do
  directory="infra/$current"
  if [[ "$current" == "dev" ]]; then
    directory="infra/envs/dev"
  fi

  terraform -chdir="$directory" init -input=false
  terraform -chdir="$directory" validate

  if [[ "$current" == "dev" ]]; then
    missing=()
    for prerequisite in pca ecr; do
      key="$prerequisite/terraform.tfstate"
      count=$(aws s3api list-objects-v2 \
        --bucket banking-app-tfstate-439475769687 \
        --expected-bucket-owner 439475769687 \
        --region ap-southeast-1 \
        --prefix "$key" \
        --query "length(Contents[?Key == '$key'] || \`[]\`)" \
        --output text)
      if [[ "$count" == "0" ]]; then
        missing+=("$prerequisite")
      fi
    done

    if (( ${#missing[@]} > 0 )); then
      message="Dev cannot be planned until these stacks have remote state: ${missing[*]}. Deploy them from main first, then rerun the PR checks."
      if [[ "$action" == "plan" && "${GITHUB_EVENT_NAME:-}" == "pull_request" ]]; then
        echo "::warning::$message"
        printf '### Dev plan NOT RUN\n\n%s\n' "$message" >> "${GITHUB_STEP_SUMMARY:?}"
        continue
      fi
      echo "::error::$message"
      exit 1
    fi
  fi

  plan_file=$(mktemp "$RUNNER_TEMP/terraform-$current-XXXXXX.tfplan")
  trap 'rm -f "$plan_file"' EXIT
  terraform -chdir="$directory" plan -input=false -lock-timeout=5m \
    -no-color -out="$plan_file"

  if [[ "$action" == "apply" ]]; then
    terraform -chdir="$directory" apply -input=false -lock-timeout=5m "$plan_file"
  fi

  printf '### %s: %s completed\n\nSee the job logs for the Terraform plan.\n' \
    "$current" "$action" >> "${GITHUB_STEP_SUMMARY:?}"
  rm -f "$plan_file"
  trap - EXIT
done
