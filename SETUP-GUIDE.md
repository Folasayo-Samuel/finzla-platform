# Step-by-step setup guide

From an empty machine to a working submission. Every command is copy-pasteable. Run them in order.

**Before you start, read this once.** The assessment says: *"you must understand everything you submit and be able to explain or modify it during the technical review."* The review is 30–45 minutes on your own repository. So as you go, the `WHY THIS MATTERS` notes in each step are the parts to actually absorb — they are the questions a reviewer asks. The commands get you a working repo; those notes get you through the review.

---

## Contents

- [Step 0 — Install the tools](#step-0--install-the-tools)
- [Step 1 — Create the GitHub repository](#step-1--create-the-github-repository)
- [Step 2 — Open it in VS Code](#step-2--open-it-in-vs-code)
- [Step 3 — Copy in the project files](#step-3--copy-in-the-project-files)
- [Step 4 — Run the app locally](#step-4--run-the-app-locally)
- [Step 5 — Build and test the container](#step-5--build-and-test-the-container)
- [Step 6 — Set up AWS credentials](#step-6--set-up-aws-credentials)
- [Step 7 — Request the TLS certificate](#step-7--request-the-tls-certificate)
- [Step 8 — Bootstrap Terraform state](#step-8--bootstrap-terraform-state)
- [Step 9 — Deploy the dev environment](#step-9--deploy-the-dev-environment)
- [Step 10 — Push the first image](#step-10--push-the-first-image)
- [Step 11 — Configure GitHub](#step-11--configure-github)
- [Step 12 — Prove the pipeline works](#step-12--prove-the-pipeline-works)
- [Step 13 — Deploy prod](#step-13--deploy-prod)
- [Step 14 — Collect evidence](#step-14--collect-evidence)
- [Step 15 — Final submission check](#step-15--final-submission-check)
- [Appendix A — If you skip the live AWS deployment](#appendix-a--if-you-skip-the-live-aws-deployment)
- [Appendix B — Tear everything down](#appendix-b--tear-everything-down)
- [Appendix C — Troubleshooting](#appendix-c--troubleshooting)
- [Appendix D — Review preparation](#appendix-d--review-preparation)

---

## Step 0 — Install the tools

### macOS

```bash
# Homebrew, if you don't have it
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

brew install terraform awscli jq git gh python@3.13
brew install --cask docker visual-studio-code
open -a Docker          # start Docker Desktop and wait for it to be running
```

### Ubuntu / WSL2

```bash
sudo apt update && sudo apt install -y curl unzip jq git python3.13 python3.13-venv gnupg software-properties-common

# Terraform (HashiCorp apt repo)
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform

# AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip && sudo ./aws/install && rm -rf awscliv2.zip aws

# Docker
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"     # then log out and back in

# GitHub CLI
(type -p wget >/dev/null || sudo apt install wget -y) \
  && sudo mkdir -p -m 755 /etc/apt/keyrings \
  && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
  && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
  && sudo apt update && sudo apt install gh -y
```

VS Code on Ubuntu: download the `.deb` from <https://code.visualstudio.com/download>, then `sudo dpkg -i code_*.deb`.

### Verify (all platforms)

```bash
terraform version   # need >= 1.11.0
aws --version       # need aws-cli/2.x
docker --version && docker buildx version
python3 --version   # need >= 3.10, 3.13 recommended
git --version
gh --version
jq --version
```

> **Terraform must be ≥ 1.11.** This project uses S3-native state locking (`use_lockfile = true`), which became generally available in 1.11. On an older version `terraform init` will reject the backend block.

---

## Step 1 — Create the GitHub repository

```bash
gh auth login       # choose GitHub.com → HTTPS → login with a browser
```

Create it **private** — an assessment repo containing infrastructure detail should not be public.

```bash
mkdir -p ~/projects && cd ~/projects
gh repo create finzla-platform --private --clone --description "Finzla Cloud & Platform Engineer technical assessment"
cd finzla-platform
```

If you'd rather not use `gh`: create the repo in the GitHub web UI, then

```bash
git clone https://github.com/<YOUR-USERNAME>/finzla-platform.git
cd finzla-platform
```

Record your details — you will paste these repeatedly:

```bash
export GH_OWNER=$(gh api user --jq .login)
export GH_REPO=finzla-platform
echo "owner=$GH_OWNER repo=$GH_REPO"
```

> **WHY THIS MATTERS — personal account vs organisation.** If you create this under a GitHub **organisation** rather than your personal account, two things change: the Gitleaks *action* would need a paid licence (this project uses the free binary instead, so you are fine), and you get access to organisation-level environment protection rules. Either works.

---

## Step 2 — Open it in VS Code

```bash
code .
```

Install the extensions that will catch mistakes as you type:

```bash
code --install-extension hashicorp.terraform
code --install-extension ms-python.python
code --install-extension charliermarsh.ruff
code --install-extension ms-azuretools.vscode-docker
code --install-extension redhat.vscode-yaml
code --install-extension github.vscode-github-actions
```

Create `.vscode/settings.json` so formatting matches what CI enforces — this prevents the single most common CI failure, a formatting mismatch:

```bash
mkdir -p .vscode && cat > .vscode/settings.json << 'EOF'
{
  "editor.formatOnSave": true,
  "files.trimTrailingWhitespace": true,
  "files.insertFinalNewline": true,
  "[terraform]": {
    "editor.defaultFormatter": "hashicorp.terraform",
    "editor.formatOnSave": true
  },
  "[python]": {
    "editor.defaultFormatter": "charliermarsh.ruff",
    "editor.formatOnSave": true,
    "editor.codeActionsOnSave": { "source.organizeImports.ruff": "explicit" }
  },
  "[yaml]": { "editor.defaultFormatter": "redhat.vscode-yaml" },
  "terraform.languageServer.enable": true,
  "files.exclude": { "**/.terraform": true, "**/__pycache__": true }
}
EOF
```

---

## Step 3 — Copy in the project files

Extract the provided `finzla-platform.tar.gz` into this repository:

```bash
# from ~/projects/finzla-platform
tar -xzf ~/Downloads/finzla-platform.tar.gz --strip-components=1 -C .
ls -a
```

You should see:

```
.env.example  .github/  .gitignore  Makefile  README.md  app/  docs/  terraform/
```

Verify nothing is missing:

```bash
test -f app/src/main.py && test -f app/Dockerfile \
  && test -f terraform/bootstrap/main.tf \
  && test -d terraform/modules/network \
  && test -f .github/workflows/pr-validate.yml \
  && test -f docs/architecture.svg \
  && echo "ALL FILES PRESENT" || echo "SOMETHING IS MISSING"
```

Commit before you change anything, so you always have a clean point to return to:

```bash
git add -A
git commit -m "feat: initial platform — app, terraform, ci/cd, docs"
git push -u origin main
```

> The push will not trigger the deploy workflow yet — it needs GitHub variables that do not exist. That is expected and gets fixed in step 11.

---

## Step 4 — Run the app locally

```bash
cd app
python3 -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install --upgrade pip
pip install -r requirements-dev.txt
```

Run the checks CI will run:

```bash
ruff check .              # expect: All checks passed!
ruff format --check .     # expect: N files already formatted
python -m pytest -v       # expect: 4 passed
bandit -r src/ -q         # expect: no output
```

Start the server:

```bash
APP_ENV=local APP_VERSION=0.1.0 GIT_SHA=$(git rev-parse HEAD) \
  uvicorn src.main:app --reload --port 8000
```

In a second terminal:

```bash
curl -s localhost:8000/health | jq       # {"status":"ok"}
curl -s localhost:8000/version | jq      # version, git_sha, build_number, environment, uptime
curl -s localhost:8000/docs -o /dev/null -w '%{http_code}\n'   # 200 in local/dev
```

Confirm the production hardening works:

```bash
# Stop the server (Ctrl-C), then:
APP_ENV=prod uvicorn src.main:app --port 8000 &
sleep 3
curl -s -o /dev/null -w 'prod /docs -> %{http_code}\n' localhost:8000/docs   # expect 404
kill %1
```

> **WHY THIS MATTERS.** OpenAPI docs are disabled when `APP_ENV=prod`. An interactive schema browser on a production fintech API is free reconnaissance — it hands an attacker every endpoint, parameter, and type. This is a one-line conditional in `main.py` and a reasonable thing to be asked about.

Deactivate when done: `deactivate && cd ..`

---

## Step 5 — Build and test the container

```bash
cd app
docker build -t finzla-app:local .
cd ..
```

Run it and check the endpoints:

```bash
docker run -d --name finzla-test -p 8000:8000 -e APP_ENV=local finzla-app:local
sleep 5
curl -s localhost:8000/health | jq
curl -s localhost:8000/version | jq
```

Now verify the security properties — these are the ones a reviewer will probe:

```bash
# 1. Not running as root
docker exec finzla-test id
# expect: uid=10001 gid=10001

# 2. Root filesystem is writable in plain docker run, but ECS enforces
#    readonlyRootFilesystem. Simulate it:
docker run --rm --read-only --tmpfs /tmp finzla-app:local \
  python -c "print('starts fine with a read-only root filesystem')"

# 3. No build toolchain shipped to production
docker run --rm finzla-app:local sh -c 'which gcc pip3 || echo "no compiler, no pip — good"'

# 4. Image size — multi-stage should keep this modest
docker images finzla-app:local --format '{{.Size}}'
```

Clean up:

```bash
docker rm -f finzla-test
```

### Pin the base image by digest (do this now)

The Dockerfile uses the `python:3.13-slim` **tag**, which is mutable. For a fintech platform, pin it:

```bash
docker pull python:3.13-slim
DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' python:3.13-slim | cut -d@ -f2)
echo "digest: $DIGEST"

# Replace both FROM lines
sed -i.bak "s|FROM python:3.13-slim AS|FROM python:3.13-slim@${DIGEST} AS|g" app/Dockerfile
rm -f app/Dockerfile.bak
grep '^FROM' app/Dockerfile

# Confirm it still builds
docker build -t finzla-app:pinned app/ && echo "PINNED BUILD OK"
```

```bash
git add app/Dockerfile
git commit -m "security: pin base image by digest"
```

> **WHY THIS MATTERS.** A tag can be repointed at different bytes by whoever controls the upstream registry. A digest is a content hash — it cannot. This is the difference between "we build from Python 3.13" and "we build from *exactly these bytes*", and it is a direct supply-chain control. Say that in the review.

---

## Step 6 — Set up AWS credentials

You need an AWS account. Free tier will not cover this entirely — budget **$5–15** for a few days of testing, and follow [Appendix B](#appendix-b--tear-everything-down) when finished.

### Create an admin user for bootstrap only

Sign in to the AWS console as root, then:

1. **IAM → Users → Create user** → name `finzla-bootstrap`
2. Attach `AdministratorAccess` directly
3. Create user → **Security credentials → Create access key** → "Command Line Interface"

```bash
aws configure --profile finzla
# AWS Access Key ID:     <paste>
# AWS Secret Access Key: <paste>
# Default region name:   eu-west-1
# Default output format: json

export AWS_PROFILE=finzla
aws sts get-caller-identity
```

> **WHY THIS MATTERS.** This admin key exists only to create the state bucket and the OIDC roles. Everything after that runs through OIDC with no stored keys. **Delete this access key when you finish step 9** — and be ready to say so, because "how do you bootstrap without AdministratorAccess" is exactly the kind of question this assessment asks. The honest answer is: you need elevated permissions once to create the roles that replace them, then you remove it.

Set some variables for later steps:

```bash
export AWS_REGION=eu-west-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "account=$ACCOUNT_ID region=$AWS_REGION"
```

**Enable a budget alarm now, before creating anything:**

```bash
cat > /tmp/budget.json << EOF
{
  "BudgetName": "finzla-monthly",
  "BudgetLimit": {"Amount": "30", "Unit": "USD"},
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST"
}
EOF
cat > /tmp/notify.json << 'EOF'
[{
  "Notification": {
    "NotificationType": "ACTUAL",
    "ComparisonOperator": "GREATER_THAN",
    "Threshold": 80,
    "ThresholdType": "PERCENTAGE"
  },
  "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "YOUR-EMAIL@example.com"}]
}]
EOF
# edit the email above first, then:
aws budgets create-budget --account-id "$ACCOUNT_ID" \
  --budget file:///tmp/budget.json \
  --notifications-with-subscribers file:///tmp/notify.json
```

---

## Step 7 — Request the TLS certificate

The ALB HTTPS listener needs a validated ACM certificate. **This must exist before you deploy**, and DNS validation can take a few minutes, so do it now.

### If you own a domain

```bash
export DOMAIN=api-dev.yourdomain.com

CERT_ARN=$(aws acm request-certificate \
  --domain-name "$DOMAIN" \
  --validation-method DNS \
  --region "$AWS_REGION" \
  --query CertificateArn --output text)
echo "CERT_ARN=$CERT_ARN"

# Get the CNAME record you must create at your DNS provider
aws acm describe-certificate --certificate-arn "$CERT_ARN" --region "$AWS_REGION" \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord'
```

Create that CNAME at your DNS provider, then wait:

```bash
aws acm wait certificate-validated --certificate-arn "$CERT_ARN" --region "$AWS_REGION"
echo "certificate validated"
```

If your domain is in Route 53, validation can be automated:

```bash
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name yourdomain.com \
  --query 'HostedZones[0].Id' --output text | cut -d/ -f3)

aws acm describe-certificate --certificate-arn "$CERT_ARN" --region "$AWS_REGION" \
  --query 'Certificate.DomainValidationOptions[0].ResourceRecord' > /tmp/rr.json

jq -n --slurpfile rr /tmp/rr.json '{
  Changes: [{
    Action: "UPSERT",
    ResourceRecordSet: {
      Name: $rr[0].Name, Type: $rr[0].Type, TTL: 300,
      ResourceRecords: [{Value: $rr[0].Value}]
    }
  }]
}' > /tmp/change.json

aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --change-batch file:///tmp/change.json
aws acm wait certificate-validated --certificate-arn "$CERT_ARN" --region "$AWS_REGION"
```

### If you do not own a domain

You have two honest options. Do **not** fake it.

**Option A (recommended):** buy a cheap domain — Route 53 registers `.click` or `.link` for about $3–5/year, and it makes the whole submission demonstrable end to end.

**Option B:** skip the live deployment and submit the configuration, which the brief explicitly allows. Go to [Appendix A](#appendix-a--if-you-skip-the-live-aws-deployment) and say so plainly in your README.

> **Do not** switch the listener to plain HTTP to avoid needing a certificate. The brief requires HTTPS/TLS for external traffic, and for a fintech platform unencrypted transport is the kind of finding that ends an interview. Skipping the deployment is a far better answer than removing a security control.

---

## Step 8 — Bootstrap Terraform state

```bash
cd terraform/bootstrap
terraform init
terraform plan
terraform apply    # type: yes
```

Capture the outputs:

```bash
export STATE_BUCKET=$(terraform output -raw state_bucket)
export STATE_KMS=$(terraform output -raw kms_key_arn)
echo "STATE_BUCKET=$STATE_BUCKET"
echo "STATE_KMS=$STATE_KMS"
cd ../..
```

Verify the security posture actually applied:

```bash
aws s3api get-bucket-versioning --bucket "$STATE_BUCKET"
# expect: "Status": "Enabled"

aws s3api get-public-access-block --bucket "$STATE_BUCKET" \
  --query 'PublicAccessBlockConfiguration'
# expect: all four true

aws s3api get-bucket-encryption --bucket "$STATE_BUCKET" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm'
# expect: "aws:kms"
```

> **WHY THIS MATTERS — the chicken-and-egg.** The bucket that stores Terraform state cannot store its own state, so this one stack uses **local** state and is applied by hand, once. Keep its `terraform.tfstate` file — back it up somewhere private. It creates only two resources, so re-importing is recoverable, but losing it is avoidable annoyance.
>
> **Locking:** there is deliberately no DynamoDB table. Terraform 1.11 made S3-native locking generally available and deprecated the DynamoDB arguments; the lock is now a `.tflock` object written with an S3 conditional put. One fewer resource, one fewer IAM surface, one fewer service to pay for. Expect to be asked why there is no lock table — that is the answer.

---

## Step 9 — Deploy the dev environment

```bash
cd terraform/envs/dev
cp terraform.tfvars.example terraform.tfvars
```

Fill it in with real values:

```bash
cat > terraform.tfvars << EOF
aws_region  = "$AWS_REGION"
project     = "finzla"
environment = "dev"
vpc_cidr    = "10.10.0.0/16"

github_org  = "$GH_OWNER"
github_repo = "$GH_REPO"

state_bucket      = "$STATE_BUCKET"
state_kms_key_arn = "$STATE_KMS"

certificate_arn = "$CERT_ARN"

warning_alert_emails = ["YOUR-EMAIL@example.com"]
EOF
# edit the email, then check it
cat terraform.tfvars
```

`terraform.tfvars` is in `.gitignore` — it stays local. Only the `.example` is committed.

Initialise with the backend, then apply:

```bash
terraform init \
  -backend-config="bucket=$STATE_BUCKET" \
  -backend-config="key=dev/terraform.tfstate" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="kms_key_id=$STATE_KMS"

terraform fmt -check -recursive ../..    # must be silent
terraform validate                        # expect: Success!
terraform plan                             # read this — roughly 60-70 resources
```

Save the plan as evidence, then apply:

```bash
terraform plan -no-color > ../../../docs/evidence/terraform-plan-dev.txt 2>&1 || true
mkdir -p ../../../docs/evidence
terraform plan -no-color > ../../../docs/evidence/terraform-plan-dev.txt

terraform apply     # type: yes — takes 5-10 minutes (NAT gateways are slow)
```

Capture the outputs:

```bash
terraform output

export ECR_URL=$(terraform output -raw ecr_repository_url)
export ECS_CLUSTER=$(terraform output -raw ecs_cluster_name)
export ECS_SERVICE=$(terraform output -raw ecs_service_name)
export TASK_FAMILY=$(terraform output -raw task_definition_family)
export ALB_DNS=$(terraform output -raw alb_dns_name)
export LOG_GROUP=$(terraform output -raw log_group_name)
export PLAN_ROLE=$(terraform output -raw gha_plan_role_arn)
export DEPLOY_ROLE=$(terraform output -raw gha_deploy_role_arn)

cat << EOF
ECR_URL     = $ECR_URL
ECS_CLUSTER = $ECS_CLUSTER
ECS_SERVICE = $ECS_SERVICE
TASK_FAMILY = $TASK_FAMILY
ALB_DNS     = $ALB_DNS
LOG_GROUP   = $LOG_GROUP
PLAN_ROLE   = $PLAN_ROLE
DEPLOY_ROLE = $DEPLOY_ROLE
EOF
cd ../../..
```

**Confirm your SNS email subscription** — check your inbox and click the link, or the alarms will never reach you.

### Now delete the bootstrap access key

Everything from here runs through OIDC.

```bash
aws iam list-access-keys --user-name finzla-bootstrap
# aws iam delete-access-key --user-name finzla-bootstrap --access-key-id <AKIA...>
```

Keep it until step 13 if you plan to deploy prod from your laptop; delete it immediately after.

> **WHY THIS MATTERS — apply dev first.** The dev stack sets `create_oidc_provider = true` and owns the account-level GitHub OIDC provider. Prod sets it to `false`. There is one OIDC provider per AWS account, so if both stacks tried to manage it they would fight on every apply. Deploying prod first will fail on this — that is the reason.

---

## Step 10 — Push the first image

The service is running but has no real image yet — it was created pointing at a `bootstrap` tag that does not exist, so tasks are failing. That is expected. Push a real image:

```bash
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "${ECR_URL%%/*}"

TAG="sha-$(git rev-parse --short=12 HEAD)"
echo "building $TAG"

# ARM64 to match the task definition's cpu_architecture
docker buildx build --platform linux/arm64 \
  --build-arg APP_VERSION=0.1.0 \
  --build-arg GIT_SHA="$(git rev-parse HEAD)" \
  --build-arg BUILD_NUMBER=1 \
  -t "$ECR_URL:$TAG" \
  --push app/
```

> **Architecture must match.** The task definition sets `cpu_architecture = "ARM64"` (Graviton — roughly 20% cheaper per vCPU). If you build for `linux/amd64` the tasks start and immediately die with `exec format error`. This is a common and confusing failure; now you know it.

Point the service at the new image:

```bash
aws ecs describe-task-definition --task-definition "$TASK_FAMILY" \
  --query 'taskDefinition' > /tmp/td.json

jq --arg IMG "$ECR_URL:$TAG" '
  .containerDefinitions[0].image = $IMG
  | del(.taskDefinitionArn, .revision, .status, .requiresAttributes,
        .compatibilities, .registeredAt, .registeredBy, .deregisteredAt)
' /tmp/td.json > /tmp/td-new.json

NEW_TD=$(aws ecs register-task-definition --cli-input-json file:///tmp/td-new.json \
  --query 'taskDefinition.taskDefinitionArn' --output text)
echo "new task definition: $NEW_TD"

aws ecs update-service --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" \
  --task-definition "$NEW_TD" --no-cli-pager > /dev/null

aws ecs wait services-stable --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE"
echo "service stable"
```

Verify it actually serves traffic:

```bash
# Through the ALB DNS name
curl -sk "https://$ALB_DNS/health" | jq
curl -sk "https://$ALB_DNS/version" | jq

# Target health should be "healthy"
TG_ARN=$(aws elbv2 describe-target-groups --names finzla-dev-tg \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State}' --output table

# Logs are arriving
aws logs tail "$LOG_GROUP" --since 10m --format short | head -20
```

`-k` skips certificate verification because you are hitting the ALB's own DNS name, which the certificate does not cover. Point your domain's DNS at the ALB to test properly:

```bash
# If using Route 53
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "$(jq -n \
  --arg name "$DOMAIN" --arg dns "$ALB_DNS" \
  --arg zone "$(cd terraform/envs/dev && terraform output -raw alb_zone_id 2>/dev/null || echo '')" '{
  Changes: [{Action:"UPSERT", ResourceRecordSet:{
    Name:$name, Type:"A",
    AliasTarget:{HostedZoneId:$zone, DNSName:$dns, EvaluateTargetHealth:true}}}]}')"

sleep 60
curl -s "https://$DOMAIN/health" | jq     # no -k needed now
```

### Verify the container really is unreachable directly

This is the brief's explicit requirement, and being able to demonstrate it is worth more than asserting it:

```bash
# Get a task's private IP
TASK_ARN=$(aws ecs list-tasks --cluster "$ECS_CLUSTER" --service-name "$ECS_SERVICE" \
  --query 'taskArns[0]' --output text)
TASK_IP=$(aws ecs describe-tasks --cluster "$ECS_CLUSTER" --tasks "$TASK_ARN" \
  --query 'tasks[0].attachments[0].details[?name==`privateIPv4Address`].value' --output text)
echo "task private IP: $TASK_IP  (RFC1918 — not internet routable)"

# The task has no public IP at all
aws ecs describe-tasks --cluster "$ECS_CLUSTER" --tasks "$TASK_ARN" \
  --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text \
  | xargs -I{} aws ec2 describe-network-interfaces --network-interface-ids {} \
      --query 'NetworkInterfaces[0].Association.PublicIp' --output text
# expect: None

# The security group only accepts the ALB's security group as a source
aws ec2 describe-security-groups --filters "Name=group-name,Values=finzla-dev-tasks" \
  --query 'SecurityGroups[0].IpPermissions[].{Port:FromPort,SourceSG:UserIdGroupPairs[].GroupId,SourceCIDR:IpRanges[].CidrIp}'
# expect: SourceSG populated, SourceCIDR empty
```

That last output is the single best piece of evidence for "the container is not directly exposed". Save it.

---

## Step 11 — Configure GitHub

### Repository variables

```bash
gh variable set AWS_PLAN_ROLE_ARN    --body "$PLAN_ROLE"
gh variable set TF_STATE_BUCKET      --body "$STATE_BUCKET"
gh variable set TF_STATE_KMS_KEY_ARN --body "$STATE_KMS"
gh variable set ACM_CERTIFICATE_ARN  --body "$CERT_ARN"
gh variable list
```

### Create the environments

```bash
gh api -X PUT "repos/$GH_OWNER/$GH_REPO/environments/dev" --silent
gh api -X PUT "repos/$GH_OWNER/$GH_REPO/environments/prod" --silent
```

### Dev environment variables

```bash
ECR_NAME=$(basename "$ECR_URL")

for kv in \
  "AWS_DEPLOY_ROLE_ARN=$DEPLOY_ROLE" \
  "ECR_REPOSITORY=$ECR_NAME" \
  "ECS_CLUSTER=$ECS_CLUSTER" \
  "ECS_SERVICE=$ECS_SERVICE" \
  "ECS_TASK_FAMILY=$TASK_FAMILY" \
  "TARGET_GROUP_NAME=finzla-dev-tg" \
  "LOG_GROUP=$LOG_GROUP" \
  "APP_URL=https://${DOMAIN:-$ALB_DNS}"
do
  gh variable set "${kv%%=*}" --env dev --body "${kv#*=}"
done

gh variable list --env dev
```

### Branch protection and the prod approval gate

**This is the control the assessment asks about specifically.** Set it in the web UI — it is fiddly via API:

**Settings → Branches → Add branch protection rule**
- Branch name pattern: `main`
- ☑ Require a pull request before merging → Require approvals: **1**
- ☑ Require status checks to pass → search and select **`PR gate`**
- ☑ Do not allow bypassing the above settings

**Settings → Environments → prod**
- ☑ **Required reviewers** → add yourself
- ☑ Deployment branches → **Selected branches** → `main`

Or via API:

```bash
gh api -X PUT "repos/$GH_OWNER/$GH_REPO/environments/prod" \
  -f "wait_timer=0" \
  -F "reviewers[][type]=User" \
  -F "reviewers[][id]=$(gh api user --jq .id)" \
  -f "deployment_branch_policy[protected_branches]=true" \
  -f "deployment_branch_policy[custom_branch_policies]=false"
```

> **WHY THIS MATTERS — the key security answer.** The prod AWS role's trust policy scopes the OIDC `sub` claim to `repo:<owner>/<repo>:environment:prod` — **not** to `ref:refs/heads/main`.
>
> That distinction is the whole answer to *"what prevents a developer from deploying to production?"* If the trust were branch-scoped, anyone who could push to main could reach prod. Because it is environment-scoped, and the `environment:prod` claim only exists in a job that declares `environment: prod`, and that job pauses for required reviewers — **no prod AWS credential is ever minted without a human approving first**.
>
> Learn this one properly. It is the most likely deep question in the review.

---

## Step 12 — Prove the pipeline works

Open a pull request and watch every check run.

```bash
git checkout -b test/pipeline-validation

# Make a small, real change
sed -i.bak 's/"service": "finzla-backend"/"service": "finzla-backend-api"/' app/src/main.py 2>/dev/null || \
  sed -i 's/"finzla-backend"/"finzla-backend-api"/' app/src/main.py
rm -f app/src/main.py.bak

cd app && source .venv/bin/activate && ruff format . && ruff check . && python -m pytest -q && deactivate && cd ..

git add -A
git commit -m "test: verify pipeline end to end"
git push -u origin test/pipeline-validation

gh pr create --title "Test: pipeline validation" \
  --body "Verifying PR checks: terraform fmt/validate/plan, app build and test, security scans."
gh pr checks --watch
```

You should see the plan posted as a PR comment, and all of `app`, `security`, `terraform (dev)`, `terraform (prod)`, `pr-gate` pass.

Merge and watch the deployment:

```bash
gh pr merge --squash --delete-branch
gh run watch
```

The prod job will **pause** for your approval. Approve it in the Actions UI, or:

```bash
gh api -X POST "repos/$GH_OWNER/$GH_REPO/actions/runs/$(gh run list --limit 1 --json databaseId --jq '.[0].databaseId')/pending_deployments" \
  -F "environment_ids[]=$(gh api repos/$GH_OWNER/$GH_REPO/environments/prod --jq .id)" \
  -f state=approved -f comment="Approved for assessment demonstration"
```

### Demonstrate the rollback (worth doing)

The assessment asks how you handle an unhealthy deployment. Prove it rather than describing it:

```bash
git checkout -b test/rollback-demo

# Make the health check fail
python3 - << 'EOF'
import pathlib
p = pathlib.Path("app/src/main.py")
t = p.read_text()
t = t.replace('READY = os.getenv("SIMULATE_UNHEALTHY", "false").lower() != "true"',
              'READY = False  # TEMPORARY: rollback demonstration')
p.write_text(t)
EOF

git commit -am "test: deliberately break health check to demonstrate rollback"
git push -u origin test/rollback-demo
gh pr create --title "Test: rollback demonstration" --body "Deliberate health check failure."
gh pr merge --squash --admin --delete-branch     # bypass review for this test only
gh run watch
```

Expected: the deploy reaches the health-check step, target health never goes healthy, the workflow dumps diagnostics and rolls back to the previous task definition, and the run fails. Screenshot that — it is the strongest single piece of evidence in the submission.

Then revert:

```bash
git checkout main && git pull
git revert HEAD --no-edit
git push
gh run watch
```

---

## Step 13 — Deploy prod

Same as dev, with `create_oidc_provider = false` already set:

```bash
export CERT_ARN_PROD=<your prod certificate ARN>   # e.g. for api.yourdomain.com

cd terraform/envs/prod
cat > terraform.tfvars << EOF
aws_region  = "$AWS_REGION"
project     = "finzla"
environment = "prod"
vpc_cidr    = "10.20.0.0/16"

github_org  = "$GH_OWNER"
github_repo = "$GH_REPO"

state_bucket      = "$STATE_BUCKET"
state_kms_key_arn = "$STATE_KMS"

certificate_arn = "$CERT_ARN_PROD"

warning_alert_emails  = ["YOUR-EMAIL@example.com"]
critical_alert_emails = ["YOUR-EMAIL@example.com"]
EOF

terraform init \
  -backend-config="bucket=$STATE_BUCKET" \
  -backend-config="key=prod/terraform.tfstate" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="kms_key_id=$STATE_KMS"

terraform plan -no-color > ../../../docs/evidence/terraform-plan-prod.txt
terraform apply
terraform output
cd ../../..
```

Then set the prod environment variables in GitHub exactly as in step 11, substituting `prod` for `dev` and using the prod outputs.

> **Cost note.** Prod runs 2 NAT gateways and 2 on-demand tasks — roughly $120–150/month if left running. If budget is tight, deploy prod, capture evidence, then destroy it and keep dev. Say so in your README; a reviewer will respect the cost awareness.

---

## Step 14 — Collect evidence

The brief asks for evidence "where possible". Collect it into the repo:

```bash
mkdir -p docs/evidence
```

```bash
# Live endpoints
curl -s "https://${DOMAIN:-$ALB_DNS}/health" -k > docs/evidence/health-response.json
curl -s "https://${DOMAIN:-$ALB_DNS}/version" -k > docs/evidence/version-response.json

# TLS configuration — proves TLS 1.2+ and the cipher in use
echo | openssl s_client -connect "${DOMAIN:-$ALB_DNS}:443" -tls1_2 2>/dev/null \
  | grep -E 'Protocol|Cipher|subject=' > docs/evidence/tls-check.txt

# HTTP redirects to HTTPS
curl -sI "http://${DOMAIN:-$ALB_DNS}/health" | head -3 > docs/evidence/http-redirect.txt

# Target health
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --output json > docs/evidence/target-health.json

# The security group proving no direct exposure
aws ec2 describe-security-groups --filters "Name=group-name,Values=finzla-dev-tasks" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json > docs/evidence/task-security-group.json

# Tasks have no public IP
aws ecs describe-tasks --cluster "$ECS_CLUSTER" \
  --tasks $(aws ecs list-tasks --cluster "$ECS_CLUSTER" --service-name "$ECS_SERVICE" --query 'taskArns[0]' --output text) \
  --query 'tasks[0].{lastStatus:lastStatus,health:healthStatus,cpu:cpu,memory:memory}' \
  --output json > docs/evidence/task-status.json

# Application logs
aws logs tail "$LOG_GROUP" --since 30m --format short | head -50 > docs/evidence/app-logs.txt

# Alarms exist and are OK
aws cloudwatch describe-alarms --alarm-name-prefix finzla-dev \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue,Metric:MetricName}' \
  --output table > docs/evidence/alarms.txt

# ECR scan findings
aws ecr describe-image-scan-findings --repository-name "$ECR_NAME" \
  --image-id imageTag="$TAG" \
  --query 'imageScanFindingsSummary' --output json > docs/evidence/ecr-scan.json 2>/dev/null || true

# Local check output
(cd app && source .venv/bin/activate && \
  { echo "=== ruff ==="; ruff check .; echo "=== pytest ==="; python -m pytest -v; \
    echo "=== bandit ==="; bandit -r src/ -q; } > ../docs/evidence/local-checks.txt 2>&1; deactivate)

ls -la docs/evidence/
```

Screenshots to take from the browser (save into `docs/evidence/`):

1. GitHub Actions — a passing PR with the plan comment visible
2. GitHub Actions — the prod job **waiting for approval** (this shows the gate working)
3. GitHub Actions — the rollback run failing after health checks
4. CloudWatch dashboard `finzla-dev-service` with data on it
5. ECS console — service showing running tasks and a healthy target group
6. Browser at `https://your-domain/version` with the padlock showing

Add a short index so a reviewer knows what they are looking at:

```bash
cat > docs/evidence/README.md << 'EOF'
# Evidence

| File | Shows |
|---|---|
| `health-response.json` | `/health` returning 200 through the ALB |
| `version-response.json` | `/version` returning build provenance |
| `tls-check.txt` | negotiated TLS version and cipher |
| `http-redirect.txt` | port 80 returning 301 to HTTPS |
| `target-health.json` | ALB targets healthy |
| `task-security-group.json` | task ingress sourced from the ALB security group only, no CIDR — the container is not directly reachable |
| `task-status.json` | task running, no public IP |
| `app-logs.txt` | structured JSON logs in CloudWatch |
| `alarms.txt` | CloudWatch alarms provisioned and in OK state |
| `ecr-scan.json` | ECR vulnerability scan summary |
| `terraform-plan-dev.txt` | full dev plan output |
| `terraform-plan-prod.txt` | full prod plan output |
| `local-checks.txt` | ruff, pytest, bandit output |
| `*.png` | screenshots — CI runs, approval gate, rollback, dashboard |
EOF

git add docs/evidence
git commit -m "docs: add deployment evidence"
git push
```

---

## Step 15 — Final submission check

```bash
# 1. No secrets committed — scan the full history
docker run --rm -v "$(pwd):/repo" zricethezav/gitleaks:latest \
  detect --source /repo --redact --verbose
# expect: no leaks found

# 2. tfvars not committed
git ls-files | grep -E '\.tfvars$' && echo "PROBLEM: tfvars committed" || echo "OK: no tfvars in git"

# 3. No state files committed
git ls-files | grep -E 'tfstate' && echo "PROBLEM" || echo "OK: no state in git"

# 4. No .env committed
git ls-files | grep -E '^\.env$' && echo "PROBLEM" || echo "OK"

# 5. Everything formatted
terraform fmt -check -recursive terraform/ && echo "OK: terraform formatted"
(cd app && source .venv/bin/activate && ruff check . && ruff format --check . && deactivate)

# 6. Required deliverables present
for f in README.md app/Dockerfile app/src/main.py \
         .github/workflows/pr-validate.yml .github/workflows/deploy.yml \
         docs/architecture.svg terraform/envs/dev/main.tf; do
  test -f "$f" && echo "OK   $f" || echo "MISSING $f"
done

# 7. Latest CI run is green
gh run list --limit 3
```

Update the README's Evidence section to reflect what you actually did:

```bash
code README.md    # edit section 12 "Evidence" and section 13 "Known gaps"
```

Be accurate here. If you did not deploy prod, say so. If you skipped the live deployment, say so. **A reviewer trusts a submission that knows its own gaps far more than one that overstates.**

```bash
git add -A && git commit -m "docs: update evidence and known gaps" && git push
```

Then submit the repository URL. If the repo is private, add the reviewer as a collaborator:

```bash
gh api -X PUT "repos/$GH_OWNER/$GH_REPO/collaborators/<REVIEWER-USERNAME>" -f permission=pull
```

---

## Appendix A — If you skip the live AWS deployment

The brief allows this: *"If you choose not to perform a live AWS deployment, the configuration and workflow should still be complete enough for another engineer to deploy."*

Do everything you still can:

```bash
# App checks
cd app && python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
ruff check . && ruff format --check . && python -m pytest -v && bandit -r src/ -q
deactivate && cd ..

# Container build and run
docker build -t finzla-app:local app/
docker run -d --name t -p 8000:8000 -e APP_ENV=local finzla-app:local
sleep 5 && curl -s localhost:8000/health | jq && curl -s localhost:8000/version | jq
docker exec t id           # proves non-root
docker rm -f t

# Terraform validation without AWS credentials
cd terraform && terraform fmt -check -recursive
for e in dev prod; do
  (cd envs/$e && terraform init -backend=false && terraform validate)
done
cd ..

# Security scanning locally
docker run --rm -v "$(pwd):/tf" bridgecrew/checkov -d /tf/terraform --compact
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy:latest image finzla-app:local --severity HIGH,CRITICAL
```

Save all of that output into `docs/evidence/`, and add a clear note near the top of your README:

> **No live AWS deployment was performed.** Verified locally: application tests, container build and run, `terraform fmt`, `terraform validate` for both environments, Checkov IaC scanning, and Trivy image scanning. Evidence in `docs/evidence/`. The configuration is complete for another engineer to deploy; see section 11 for the procedure.

`terraform validate` without credentials still catches type errors, bad references, and missing variables — it is genuinely worth running.

---

## Appendix B — Tear everything down

Do this when you finish, or you will keep paying for NAT gateways.

```bash
# Prod first (if deployed)
cd terraform/envs/prod
terraform destroy      # you may need to disable ALB deletion protection first
cd ../dev
terraform destroy
cd ../..
```

If `destroy` fails on the ALB:

```bash
aws elbv2 modify-load-balancer-attributes \
  --load-balancer-arn "$(aws elbv2 describe-load-balancers --names finzla-prod-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text)" \
  --attributes Key=deletion_protection.enabled,Value=false
```

If it fails on a non-empty S3 bucket (ALB access logs):

```bash
aws s3 rm "s3://finzla-prod-alb-logs-$ACCOUNT_ID" --recursive
```

The state bucket has `prevent_destroy` on purpose. To remove it deliberately:

```bash
cd terraform/bootstrap
# remove the lifecycle prevent_destroy blocks from main.tf, then:
terraform apply
aws s3 rm "s3://$STATE_BUCKET" --recursive
aws s3api delete-objects --bucket "$STATE_BUCKET" --delete "$(aws s3api list-object-versions \
  --bucket "$STATE_BUCKET" --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json)" 2>/dev/null || true
terraform destroy
```

Then verify nothing is left running:

```bash
aws ec2 describe-nat-gateways --filter "Name=state,Values=available" \
  --query 'NatGateways[].NatGatewayId'
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws ecs list-clusters --query clusterArns
# all should be empty
```

Finally, delete the `finzla-bootstrap` IAM user and check Cost Explorer in a couple of days.

---

## Appendix C — Troubleshooting

### `terraform init` rejects `use_lockfile`

Your Terraform is older than 1.11. `terraform version`, then upgrade.

### `Error: creating ELBv2 Listener: CertificateNotFound`

The certificate is not validated, or is in a different region than the ALB. ACM certificates for an ALB must be in the **same region**.

```bash
aws acm describe-certificate --certificate-arn "$CERT_ARN" --region "$AWS_REGION" \
  --query 'Certificate.Status'    # must be ISSUED
```

### Tasks fail with `exec format error`

Architecture mismatch. The task definition says ARM64; you built amd64.

```bash
docker buildx build --platform linux/arm64 -t "$ECR_URL:$TAG" --push app/
```

### Tasks fail with `CannotPullContainerError`

The image tag does not exist, or the task cannot reach ECR.

```bash
aws ecr describe-images --repository-name "$ECR_NAME" --query 'imageDetails[].imageTags'
```

### Targets stuck `unhealthy`

Work through [README section 9](README.md#9-incident-investigation--503s-with-healthy-tasks). Fastest first look:

```bash
aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{State:TargetHealth.State,Reason:TargetHealth.Reason,Desc:TargetHealth.Description}' \
  --output table
aws logs tail "$LOG_GROUP" --since 15m --format short
```

### GitHub Actions: `Not authorized to perform sts:AssumeRoleWithWebIdentity`

The OIDC `sub` claim does not match the trust policy. Almost always `github_org`/`github_repo` in `terraform.tfvars` not matching reality, or a prod job running outside the `prod` environment.

```bash
aws iam get-role --role-name finzla-dev-gha-deploy \
  --query 'Role.AssumeRolePolicyDocument' --output json
# compare the sub value against repo:<owner>/<repo>:environment:<env>
```

### GitHub Actions: `Error: Input required and not supplied: role-to-assume`

A variable is missing or set at the wrong scope. Environment variables must be set with `--env <name>`:

```bash
gh variable list
gh variable list --env dev
gh variable list --env prod
```

### `terraform apply` hangs on NAT gateway

Normal. NAT gateways take 2–5 minutes each. Prod creates two.

### KMS `AccessDeniedException` when creating a log group

The KMS key policy must allow `logs.<region>.amazonaws.com`. It does in this code — but if you changed the region after the first apply, the policy condition still references the old one. Re-apply.

### Error about the OIDC provider already existing

You applied prod before dev, or set `create_oidc_provider = true` in both. It must be `true` in exactly one environment.

```bash
aws iam list-open-id-connect-providers
```

---

## Appendix D — Review preparation

The review is 30–45 minutes on your own repository. Be able to answer these without notes, in your own words.

### Almost certain to be asked

1. **Why ECS Fargate and not EKS?** One service; no control plane or nodes to operate; revisit at ~10 services with a platform team.
2. **How is the container prevented from being internet-reachable?** Private subnets with no inbound route, `assign_public_ip = false`, and the task security group's ingress referencing the ALB's **security group ID** rather than a CIDR — so nothing in the VPC can reach it either.
3. **What stops a developer deploying to prod?** The OIDC trust scopes `sub` to `environment:prod`, not a branch. That claim only appears in a job declaring `environment: prod`, which pauses for required reviewers. No credential is minted before approval.
4. **Why is `iam:PassRole` restricted to two ARNs?** `ecs:RegisterTaskDefinition` cannot be resource-scoped by the API. Unrestricted `PassRole` would let the deploy role register a task running as an administrator and start it — full account takeover. That condition is the difference between "runs code in one container" and "owns the account".
5. **Walk me through the request path.** Route 53 → ALB in a public subnet terminating TLS → target group of task IPs → task ENI in a private subnet on 8000 → uvicorn as uid 10001.
6. **What happens if a deploy fails health checks?** Old tasks keep serving (`minimum_healthy_percent = 100`); the ECS circuit breaker reverts automatically; the pipeline independently rolls back to the recorded task definition after dumping diagnostics.
7. **Where is state, and how is it locked?** S3 with versioning, KMS, TLS-only policy, per-environment key. Locking is S3-native `use_lockfile` — no DynamoDB, because 1.11 deprecated those arguments.

### Be ready to modify something live

They may ask you to change code. Practise:

- add a `/ready` endpoint distinct from `/health`
- change `desired_count` and explain the deploy behaviour
- add a fourth CloudWatch alarm
- tighten one IAM statement further
- add a new environment variable end to end (Terraform → task definition → app)

### Know your own gaps

Section 13 of the README lists them. Owning a gap reads as senior; being caught unaware of one does not. The main ones: `ec2:*` in the apply role is broader than ideal and needs iterative tightening against real `AccessDenied` errors; no WAF, GuardDuty, or Config; autoscaling thresholds are estimates rather than load-test results; and separate AWS accounts per environment is the right end state rather than what is built.

### Have a view on what you would do next

Top three from the README, and why in that order: separate AWS accounts with SCPs (an account boundary is the only control that is hard to misconfigure across, and it gets harder to retrofit over time); real tracing plus the fintech compliance controls; canary deployments with alarm-gated rollback and a **tested** DR plan.

Being able to say *"here is what I would do next and why in that order"* is usually what separates a good submission from a strong one.
