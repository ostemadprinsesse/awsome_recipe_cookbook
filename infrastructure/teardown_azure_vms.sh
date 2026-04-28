#!/usr/bin/env bash
set -euo pipefail

# Azure VM teardown for Ostemadprinsesse/awsome_recipe_cookbook
# Deletes the resource group and removes deployment-specific GitHub secrets.
#
# Run interactively: bash infrastructure/teardown_azure_vms.sh

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-ostemadprinsesse-cookbook}"
GITHUB_REPO="${GITHUB_REPO:-Ostemadprinsesse/awsome_recipe_cookbook}"

log() { printf '\n\033[1;34m[teardown]\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

az_cli() {
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' az "$@"
}

command -v az >/dev/null || die "Azure CLI (az) not installed."
command -v gh >/dev/null || die "GitHub CLI (gh) not installed."

log "Verifying Azure login..."
az_cli account show >/dev/null 2>&1 || die "Not logged in to Azure. Run 'az login' first."
ACCOUNT_NAME=$(az_cli account show --query name -o tsv)

log "Verifying GitHub login..."
gh auth status >/dev/null 2>&1 || die "Not logged in to GitHub. Run 'gh auth login' first."

cat <<CONFIRM

About to tear down the deployment:

  Azure subscription : $ACCOUNT_NAME
  Resource group     : $RESOURCE_GROUP
  GitHub repo        : $GITHUB_REPO

This will delete the VM resources and remove deployment-specific secrets.
CONFIRM

read -rp "Continue? (y/N): " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted by user."

if ! az_cli group exists --name "$RESOURCE_GROUP" | grep -q "true"; then
  log "Resource group '$RESOURCE_GROUP' does not exist. Nothing to delete."
else
  log "Showing resources in '$RESOURCE_GROUP'..."
  az_cli resource list --resource-group "$RESOURCE_GROUP" --output table || true

  log "Deleting resource group '$RESOURCE_GROUP'..."
  az_cli group delete --name "$RESOURCE_GROUP" --yes --no-wait

  log "Waiting for resource group deletion to finish..."
  az_cli group wait --name "$RESOURCE_GROUP" --deleted --timeout 600 || true
fi

log "Removing deployment-specific GitHub secrets and variables..."
gh secret delete SSH_HOST_NGINX -R "$GITHUB_REPO" >/dev/null 2>&1 || true
gh secret delete BACKEND_PRIVATE_IP -R "$GITHUB_REPO" >/dev/null 2>&1 || true
gh secret delete SSH_USER -R "$GITHUB_REPO" >/dev/null 2>&1 || true
gh secret delete SSH_PRIVATE_KEY -R "$GITHUB_REPO" >/dev/null 2>&1 || true
gh variable delete DEPLOY_MODE -R "$GITHUB_REPO" >/dev/null 2>&1 || true
gh variable delete DEPLOY_OWNER -R "$GITHUB_REPO" >/dev/null 2>&1 || true

log "Done."
cat <<SUMMARY

Deployment removed.

What remains:
  - CR_PAT and DOCKER_GITHUB_USERNAME are left in repo Actions secrets on purpose.
  - If you want a fully clean repo state, delete those manually in GitHub.

SUMMARY