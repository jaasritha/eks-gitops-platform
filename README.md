# EKS GitOps Platform

Production-grade multi-environment platform using **Terraform + ArgoCD + Helm** on AWS EKS.

---

## Architecture Overview

```
Git Repository
├── terraform/          → Provisions EKS, VPC, IAM (IRSA), S3 backend
├── helm-charts/        → base-app chart + monitoring umbrella chart
├── apps/               → Per-app Helm values (dev / staging / prod)
├── clusters/           → ArgoCD Application manifests per environment
├── argocd/             → App-of-Apps root + ApplicationSet
└── .github/workflows/  → Terraform plan/apply CI + Helm lint
```

**Delivery model**: Terraform owns infrastructure. ArgoCD owns everything inside the cluster. Application teams push image tags → ArgoCD detects drift → syncs automatically.

---

## Step-by-Step Implementation Plan

### Phase 1 — Prerequisites (Day 1)

```bash
# 1. Install required tools
brew install terraform helm kubectl awscli argocd

# 2. Configure AWS credentials
aws configure sso   # or export AWS_PROFILE=your-profile

# 3. Create S3 bucket + DynamoDB table for Terraform remote state
aws s3api create-bucket \
  --bucket eks-gitops-tfstate-dev \
  --region ap-southeast-1 \
  --create-bucket-configuration LocationConstraint=ap-southeast-1

aws s3api put-bucket-versioning \
  --bucket eks-gitops-tfstate-dev \
  --versioning-configuration Status=Enabled

aws dynamodb create-table \
  --table-name eks-gitops-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-southeast-1

# 4. Fork/clone this repo and update your org name in:
#    - argocd/app-of-apps.yaml        (repoURL)
#    - argocd/applicationset.yaml     (repoURL)
#    - clusters/dev/argocd-apps/platform.yaml  (ARN placeholders)
```

---

### Phase 2 — Provision Dev EKS Cluster (Day 1-2)

```bash
cd terraform/envs/dev

# Init with remote state
terraform init

# Preview what will be created (~25 resources: VPC, EKS, IAM roles)
terraform plan

# Apply (takes ~15 minutes)
terraform apply

# Capture outputs — you'll need these for ArgoCD
terraform output -json > /tmp/tf-outputs-dev.json
```

**What gets created:**
- VPC with 3 private + 3 public subnets across AZs
- EKS 1.30 cluster with SPOT node group (t3.medium, 2 nodes)
- OIDC provider for IRSA
- IAM roles for ALB Controller, External-DNS, Cluster Autoscaler
- KMS key for secrets encryption
- CloudWatch log group

---

### Phase 3 — Bootstrap ArgoCD (Day 2)

```bash
# Update ACCOUNT_ID in clusters/dev/argocd-apps/platform.yaml first!
# Replace all "ACCOUNT_ID" placeholders with your AWS account ID:
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
find clusters/ -name "*.yaml" -exec sed -i "s/ACCOUNT_ID/${AWS_ACCOUNT}/g" {} \;

# Run the bootstrap script
./bootstrap-argocd.sh dev ap-southeast-1

# Verify ArgoCD is running
kubectl get pods -n argocd

# Check App-of-Apps is syncing
argocd app list
```

**Sync wave order (ArgoCD deploys in this sequence):**
1. Wave -2: `cert-manager` (CRDs must be present before other charts)
2. Wave -1: `aws-load-balancer-controller`
3. Wave  0: `external-dns`, `cluster-autoscaler`
4. Wave  5: `monitoring-stack` (Prometheus, Grafana, Loki)
5. Wave 10: `platform-apps` ApplicationSet (your microservices)

---

### Phase 4 — Deploy Your First Application (Day 2-3)

```bash
# 1. Build and push your image to ECR
aws ecr create-repository --repository-name frontend --region ap-southeast-1

aws ecr get-login-password --region ap-southeast-1 | \
  docker login --username AWS --password-stdin \
  ${AWS_ACCOUNT}.dkr.ecr.ap-southeast-1.amazonaws.com

docker build -t frontend:dev-latest .
docker tag frontend:dev-latest \
  ${AWS_ACCOUNT}.dkr.ecr.ap-southeast-1.amazonaws.com/frontend:dev-latest
docker push ${AWS_ACCOUNT}.dkr.ecr.ap-southeast-1.amazonaws.com/frontend:dev-latest

# 2. Update image repo in apps/frontend/helm-values/values-dev.yaml
sed -i "s/123456789/${AWS_ACCOUNT}/g" apps/frontend/helm-values/values-dev.yaml

# 3. Commit and push — ArgoCD auto-syncs within 3 minutes
git add apps/frontend/helm-values/values-dev.yaml
git commit -m "feat: update frontend image repo"
git push origin main

# 4. Watch ArgoCD sync
argocd app get frontend-dev
kubectl get pods -n app-dev -w
```

---

### Phase 5 — Staging and Production (Day 3-5)

```bash
# Provision staging cluster
cd terraform/envs/staging
terraform init && terraform apply

# Bootstrap ArgoCD on staging (points to a different ArgoCD instance or same with multi-cluster)
./bootstrap-argocd.sh staging ap-southeast-1

# Promote image tag from dev to staging
# Edit apps/frontend/helm-values/values-staging.yaml
# Change: tag: "dev-latest" → "v1.0.0"
# Push → ArgoCD syncs staging

# Promote to prod (requires PR review + GitHub env protection rules)
# Edit apps/frontend/helm-values/values-prod.yaml
# Change: tag: "v1.0.0" (same tag, different env config)
```

---

### Phase 6 — Apply OPA Gatekeeper Policies (Day 4)

```bash
# Install OPA Gatekeeper via Helm (add to clusters/dev/argocd-apps/platform.yaml)
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
helm install gatekeeper gatekeeper/gatekeeper -n gatekeeper-system --create-namespace

# Apply ConstraintTemplates and Constraints
kubectl apply -f clusters/dev/argocd-apps/gatekeeper-policies.yaml

# Test a policy violation (should be denied)
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bad-deploy
  namespace: app-dev
spec:
  selector:
    matchLabels:
      app: bad
  template:
    metadata:
      labels:
        app: bad
    spec:
      containers:
      - name: bad
        image: nginx:latest    # ← violates NoLatestTag (in prod)
        # no resources         # ← violates RequireResourceLimits
EOF
```

---

## Key Design Decisions

| Decision | Choice | Why |
|---|---|---|
| State backend | S3 + DynamoDB | Standard; locking prevents concurrent apply |
| IRSA over node IAM | ✅ Always | Per-pod least-privilege; no credential sprawl |
| single_nat_gateway | true in dev, false in prod | Cost vs HA tradeoff |
| ArgoCD sync mode | automated + selfHeal | Drift detection in prod; manual override still possible |
| Sync waves | -2 → 10 | CRDs before controllers; controllers before apps |
| Image tags | pinned in prod, latest in dev | Reproducibility in prod; speed in dev |
| HPA metrics | CPU + Memory | Both needed; CPU alone misses memory-bound services |
| PDB | prod only | Prevent all-pods eviction during node upgrades |

---

## Troubleshooting

```bash
# ArgoCD app stuck syncing?
argocd app sync <app-name> --force

# Gatekeeper blocking a deploy?
kubectl describe constrainttemplate <name>
kubectl get events -n app-dev --sort-by='.lastTimestamp'

# Check Terraform state drift
cd terraform/envs/dev && terraform plan   # should show "No changes"

# View ArgoCD sync history
argocd app history <app-name>

# Rollback to previous Helm release
argocd app rollback <app-name> <revision-number>
```

---

## Repository Checklist Before Going to Prod

- [ ] Replace all `ACCOUNT_ID`, `your-org`, `example.com` placeholders
- [ ] Set up GitHub environment protection rules for `prod-apply`
- [ ] Store secrets in AWS Secrets Manager + External Secrets Operator
- [ ] Enable S3 bucket versioning + MFA delete on Terraform state buckets
- [ ] Rotate ArgoCD initial admin password
- [ ] Configure ArgoCD RBAC (SSO via Okta/Cognito)
- [ ] Set `single_nat_gateway = false` in prod Terraform
- [ ] Enable VPC Flow Logs
- [ ] Configure ALB WAF ACL in prod ingress annotations
- [ ] Set `enforcementAction: deny` on all Gatekeeper constraints
- [ ] Configure Alertmanager → PagerDuty/Slack notification routes
