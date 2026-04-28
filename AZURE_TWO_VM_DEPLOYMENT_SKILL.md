# Notes from the human on why we made this file / uses the knowledge
2. Skill Guide for dit næste projekt
Lavet AZURE_TWO_VM_DEPLOYMENT_SKILL.md — en fuld implementeringsguide som:

Forklarer arkitekturen (offentlig nginx + privat backend)
Gennemgår hver setup-step
Håndterer variationer (andre ports, andre proxy'er, HAProxy i stedet for nginx, etc.)
Inkluderer troubleshooting tips
Giver konkrete eksempler på tilpasninger
Sådan bruges den til dit "Dinner Served and Ate" projekt:

Først: Se om projektet har en proxy-branch med nginx setup. Hvis ja, align den med docker-compose.nginx.yml format fra denne guide.

Kopier scripterne:

setup_azure_vms.sh
teardown_azure_vms.sh
Tilpas GITHUB_REPO, RESOURCE_GROUP, LOCATION til dit projekt.

Kopier workflow: Tag continuous_delivery_deployment_IaC.yaml og tilpas det til dit project layout (andre container navne, porte, osv.).

Stil spørgsmål i skill-guiden:

Kører i-projektet på port 8080 eller noget tredje?
Bruger det nginx eller noget helt tredje?
Er docker-composefiler struktureret på samme måde?



# Azure Two-VM Deployment Skill Guide

**Purpose:** Template and workflow for setting up a two-VM deployment on Azure (one public nginx proxy, one private backend) with Docker and GitHub Actions IaC integration.

**When to use this:** When your project needs:
- A scalable two-tier architecture (frontend/load balancer + backend service)
- Docker containers on Azure VMs
- GitHub Actions continuous deployment
- Private backend VM (no public IP; reachable only via frontend)
- Team-based Azure resource management with ownership locks

---

## Prerequisites & Decisions

### 1. Verify Your Architecture

Before starting, answer these questions about your target project:

- **Is your app already containerized?** You need Dockerfiles for each tier (frontend/proxy, backend).
- **Can your backend run on a private internal IP?** (Most services can via bastion/ProxyJump.)
- **Do you have a reverse proxy config?** (nginx, HAProxy, etc.) If using nginx, you'll template the backend IP into the proxy config at deploy time.
- **Are your Docker images public or private?** If private (GHCR), you'll need `CR_PAT` + registry login on the VMs.
- **Which Azure regions are available to your subscription?** (Check `az account list-locations` or Azure Portal.)

### 2. Choose Your Azure Region

Common regions: `northeurope`, `westeurope`, `swedencentral`, `eastus`. Adjust the `LOCATION` variable in `setup_azure_vms.sh` to match your subscription's capabilities.

### 3. Understand the Network Model

- **Resource Group:** Single RG for all two-VM resources (VMs, VNet, NSGs, IPs).
- **VNet + Subnet:** One shared VNet and subnet. Both VMs are in the same subnet so they can reach each other internally.
- **Public IP:** Only on the frontend (nginx) VM. Ports 80/443 open inbound.
- **Private IP:** Backend VM has no public IP. Port 8080 (or your backend port) accessible *only* from the frontend's private IP address.
- **NSG Rules:** Strict: backend only accepts traffic from frontend's private IP on the backend port.

---

## Implementation Steps

### Step 1: Prepare Your Docker Setup

Ensure your project layout matches this pattern:

```
src/
  backend/
    Dockerfile.prod       # Backend image (gunicorn, Flask, etc. on port 8080)
    requirements.txt
    app.py
    ...
  network/
    Dockerfile           # nginx or HAProxy (listens on 80)
    nginx.conf           # Template file with ${BACKEND_PRIVATE_IP} placeholder
  docker-compose.backend.yml   # Runs backend container on VM
  docker-compose.nginx.yml     # Runs proxy container on VM, env var BACKEND_PRIVATE_IP
  docker-compose.prod.yml      # Multi-service for local testing/building
```

**Key detail:** Your proxy's config must accept `${BACKEND_PRIVATE_IP}` as an environment variable substitution. In nginx:

```bash
# Dockerfile
CMD ["/bin/sh", "-c", "envsubst '${BACKEND_PRIVATE_IP}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf && nginx -g 'daemon off;'"]
```

### Step 2: Create the Azure Provisioning Script

Copy `infrastructure/setup_azure_vms.sh` from this repo and adapt:

- Change `GITHUB_REPO` from `Ostemadprinsesse/awsome_recipe_cookbook` to your org/repo.
- Change `RESOURCE_GROUP` name to something unique to your project.
- Adjust `LOCATION` to your Azure region.
- Update VM names if desired.

The script will:
1. Create resource group, VNet, subnet
2. Create two VMs (one with public IP, one without)
3. Configure NSG rules (80/443 on frontend, backend port from frontend only)
4. Install Docker on both VMs via SSH
5. Set GitHub Actions secrets (`SSH_HOST_NGINX`, `BACKEND_PRIVATE_IP`, `SSH_USER`, `SSH_PRIVATE_KEY`)

### Step 3: Update GitHub Actions Workflow

Your workflow must:

1. **Build stage:** Build and push both images to GHCR (or your registry).
   ```yaml
   GITHUB_OWNER=$GITHUB_OWNER docker buildx bake -f docker-compose.prod.yml \
     --set *.platform=linux/amd64,linux/arm64 --push
   ```

2. **Deploy backend stage:** SSH into backend *via frontend as bastion* (ProxyJump).
   ```bash
   scp -i ~/.ssh/ssh_key \
     -o StrictHostKeyChecking=no \
     -o ProxyJump="$SSH_USER@$SSH_HOST_NGINX" \
     src/docker-compose.backend.yml "$SSH_USER@$SSH_HOST_BACKEND:docker-compose.yml"
   ```

3. **Deploy frontend stage:** SSH directly into frontend, pass `BACKEND_PRIVATE_IP` as env var.
   ```bash
   echo "BACKEND_PRIVATE_IP=${{ secrets.BACKEND_PRIVATE_IP }}" >> .env
   scp ... .env $SSH_USER@$SSH_HOST_NGINX:.env
   ```

4. **GHCR login:** On both VMs before `docker compose pull`, log in:
   ```bash
   echo "$CR_PAT" | docker login ghcr.io -u "$DOCKER_GITHUB_USERNAME" --password-stdin
   ```

**If GHCR images are private**, set these repository secrets in GitHub:
- `CR_PAT` — Personal Access Token with `read:packages` + `write:packages`
- `DOCKER_GITHUB_USERNAME` — Your GitHub username or org name

### Step 4: Create Teardown Script

Copy `infrastructure/teardown_azure_vms.sh` and adjust the `RESOURCE_GROUP` to match your setup script.

The teardown will:
1. Delete the entire resource group (VMs, VNet, IPs).
2. Remove deployment-specific secrets from GitHub (optional; adjust as needed).

### Step 5: Set Up Repository Secrets

In your GitHub repo **Settings → Secrets and variables → Actions**, add:

| Secret | Source | Notes |
|--------|--------|-------|
| `SSH_USER` | Sæt af setup scriptet (`azureuser`) | VM admin user |
| `SSH_HOST_NGINX` | Set af setup scriptet | Frontend public IP |
| `BACKEND_PRIVATE_IP` | Set af setup scriptet | Backend internal IP |
| `SSH_PRIVATE_KEY` | Your `~/.ssh/id_rsa` file | For SSH access |
| `CR_PAT` | GitHub Settings → Tokens | Only if GHCR images are private |
| `DOCKER_GITHUB_USERNAME` | Your GitHub username | Only if GHCR images are private |

---

## Running the Setup

```bash
# 1. Ensure you are logged into Azure and GitHub
az login
gh auth login

# 2. Run the provisioning script
bash infrastructure/setup_azure_vms.sh

# 3. Confirm the prompts
# (Script will create VMs, configure network, set GitHub secrets)

# 4. Push to your deployment branch (e.g., IaC or main)
git push

# 5. GitHub Actions workflow runs automatically
# Monitor the build, deploy-backend, and deploy-nginx jobs
```

### Accessing the App

After deployment, open your browser to:

```
http://<nginx-public-ip>/
```

The IP is printed at the end of `setup_azure_vms.sh` and stored in the `SSH_HOST_NGINX` secret.

### Testing the Backend (if needed)

```bash
# SSH into frontend VM
ssh azureuser@<nginx-public-ip>

# From there, curl the backend on its private IP
curl http://10.0.1.5:8080/health   # (adjust IP and path as needed)
```

---

## Troubleshooting

### "Invalid resource ID" error on Windows/Git Bash

**Problem:** Azure CLI paths are converted by MSYS.

**Solution:** The setup script includes `az_cli()` wrapper that disables path conversion:
```bash
az_cli() {
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' az "$@"
}
```

### ProxyJump SSH timeout

**Problem:** Backend VM is unreachable via frontend.

**Solution:** Check NSG rule on backend:
```bash
az network nsg rule list -g <RESOURCE_GROUP> -n <NSG_NAME> --output table
```
Verify the rule allows your frontend's private IP on the backend port.

### Docker image pull fails on VM

**Problem:** `docker compose pull` fails with 401/403.

**Solution:** Ensure GHCR login is run before `pull`:
```bash
echo "$CR_PAT" | docker login ghcr.io -u "$DOCKER_GITHUB_USERNAME" --password-stdin
docker compose pull
```

### Node.js deprecation warning in GitHub Actions

**Problem:** Actions run on deprecated Node.js 20.

**Solution:** Update action versions to Node.js 24-compatible:
```yaml
uses: actions/checkout@v4
uses: docker/setup-buildx-action@v4
```

---

## Customization

### Different Backend Port

If your backend doesn't run on 8080, change:
- `BACKEND_PORT=8080` in `setup_azure_vms.sh`
- Port in `docker-compose.backend.yml`
- Port in proxy config (`nginx.conf`)

### Different VM Size

```bash
VM_SIZE=Standard_B2s bash infrastructure/setup_azure_vms.sh
```

Available sizes: `Standard_B1s`, `Standard_B2s`, `Standard_D2s_v5`, etc.

### Multiple Deployments (Team Sharing)

The setup script includes a **team ownership lock**. If another teammate has an active deployment:

```
[error] Another teammate already has an active deployment on this repo.
```

**Resolution:**
1. Ask the teammate to teardown first: `bash infrastructure/teardown_azure_vms.sh`
2. Or override (if you know the lock is stale): `FORCE=1 bash infrastructure/setup_azure_vms.sh`

---

## File Reference

| File | Purpose |
|------|---------|
| `infrastructure/setup_azure_vms.sh` | Provision VMs, network, and GitHub secrets |
| `infrastructure/teardown_azure_vms.sh` | Delete resource group and clean up secrets |
| `.github/workflows/continuous_delivery_deployment_IaC.yaml` | CI/CD pipeline (build, deploy-backend, deploy-nginx) |
| `src/docker-compose.backend.yml` | Backend service runtime contract |
| `src/docker-compose.nginx.yml` | Frontend/proxy service runtime contract |
| `src/network/nginx.conf` | Proxy template (contains `${BACKEND_PRIVATE_IP}`) |

---

## Key Learnings

1. **Private backend VMs save costs** — no egress traffic for the backend; only frontend talks to the internet.
2. **ProxyJump via SSH** — GitHub Actions can reach private VMs through a public bastion (the frontend).
3. **NSG rules are strict** — backend only accepts traffic from frontend's private IP. This enforces the desired architecture.
4. **Idempotency matters** — the setup script can be re-run safely; it reuses existing VMs and updates only what changed.
5. **GHCR login on the VM** — if using private images, the VM itself must authenticate to pull, not just the GitHub Actions runner.

---

## Example Adaptations

### If you use HAProxy instead of nginx

- Replace `src/network/Dockerfile` with your HAProxy image.
- Replace `src/network/nginx.conf` with your HAProxy config template.
- Ensure your config template accepts `${BACKEND_PRIVATE_IP}` substitution.

### If your backend runs on a different port

- Change `BACKEND_PORT=8080` in setup script.
- Update NSG rule to allow that port.
- Update proxy config to proxy to the new port.

### If you have multiple backend instances

- This template assumes one backend VM. For multiple backends:
  - Create multiple backend VMs (extend `create_vm()` calls in setup script).
  - Load balance across them in the proxy config.
  - Update NSG rules to allow proxy → all backend IPs.

---

## Next Steps for Your Actual Project

1. Copy this guide to your real project repo as `AZURE_DEPLOYMENT_README.md`.
2. Adapt the Docker/proxy setup to match your project's architecture.
3. Verify that GHCR images are built and pushed correctly.
4. Test the setup script in a dev/test subscription first.
5. Iterate on NSG rules and network config based on your specific needs.

---

**Last Updated:** April 2026  
**Based on:** Ostemadprinsesse/awsome_recipe_cookbook two-VM Azure IaC deployment  
