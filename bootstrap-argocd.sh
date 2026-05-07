#!/usr/bin/env bash
################################################################################
# bootstrap-argocd.sh
#
# Run ONCE after Terraform creates the EKS cluster.
# Installs ArgoCD via Helm, then applies the App-of-Apps manifest.
#
# Usage: ./bootstrap-argocd.sh <env> <aws-region>
# Example: ./bootstrap-argocd.sh dev ap-southeast-1
################################################################################
set -euo pipefail

ENV="${1:-dev}"
AWS_REGION="${2:-ap-southeast-1}"
CLUSTER_NAME="eks-gitops-${ENV}"
ARGOCD_VERSION="7.3.4"
ARGOCD_NAMESPACE="argocd"

echo "==> Updating kubeconfig for ${CLUSTER_NAME}"
aws eks update-kubeconfig \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}"

echo "==> Adding ArgoCD Helm repo"
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

echo "==> Installing ArgoCD ${ARGOCD_VERSION} in namespace ${ARGOCD_NAMESPACE}"
helm upgrade --install argocd argo/argo-cd \
  --namespace "${ARGOCD_NAMESPACE}" \
  --create-namespace \
  --version "${ARGOCD_VERSION}" \
  --set server.service.type=LoadBalancer \
  --set configs.params."server\.insecure"=true \
  --set repoServer.resources.requests.cpu=100m \
  --set repoServer.resources.requests.memory=128Mi \
  --wait \
  --timeout 10m

echo "==> Waiting for ArgoCD server to be ready..."
kubectl rollout status deployment/argocd-server \
  -n "${ARGOCD_NAMESPACE}" \
  --timeout=300s

echo "==> Getting initial ArgoCD admin password"
ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret \
  -n "${ARGOCD_NAMESPACE}" \
  -o jsonpath='{.data.password}' | base64 -d)
echo "  ArgoCD admin password: ${ARGOCD_PASSWORD}"
echo "  (change this immediately in production!)"

echo "==> Registering Git repository with ArgoCD"
# You can also do this via the ArgoCD UI
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: eks-gitops-repo
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: https://github.com/your-org/eks-gitops-platform   # replace
  # For private repos, use SSH key or GitHub App credentials:
  # sshPrivateKey: |
  #   -----BEGIN OPENSSH PRIVATE KEY-----
  #   ...
EOF

echo "==> Applying App-of-Apps for environment: ${ENV}"
# Patch the app-of-apps to point to the right env directory
sed "s/\$ENV_NAME/${ENV}/g" argocd/app-of-apps.yaml | kubectl apply -f -

echo ""
echo "====================================================="
echo " ArgoCD bootstrap complete for: ${ENV}"
echo "====================================================="
echo ""
echo " ArgoCD UI:"
ARGOCD_LB=$(kubectl get svc argocd-server -n ${ARGOCD_NAMESPACE} \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "  http://${ARGOCD_LB}"
echo "  Username: admin"
echo "  Password: ${ARGOCD_PASSWORD}"
echo ""
echo " Next steps:"
echo "  1. Login to ArgoCD UI and verify App-of-Apps is syncing"
echo "  2. Check platform addons are deploying in correct sync-wave order"
echo "  3. Replace ACCOUNT_ID placeholders in clusters/${ENV}/argocd-apps/platform.yaml"
echo "  4. Commit and push — ArgoCD will self-sync"
echo ""
