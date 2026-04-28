---
name: github-actions-ghcr-deployment
description: "Debug and fix GitHub Actions workflows for GHCR builds and SSH-based deployments. Use when: build fails, Docker login errors, deploy hangs, images don't pull, or setting up multi-service deployments with private registries. Includes diagnostic checklist, workflow best practices, and common pitfalls."
---

# GitHub Actions + GHCR Deployment Troubleshooting

## Quick Diagnostic Checklist

When your GitHub Actions build or deploy fails, work through this checklist systematically:

### 1. Workflow & Secret Verification
- [ ] Only ONE workflow file triggers on your branch (no duplicate `name:` across workflows)
- [ ] All required secrets exist in GitHub: `CR_PAT`, `DOCKER_GITHUB_USERNAME`, `SSH_PRIVATE_KEY`, `SSH_HOST_NGINX`, `BACKEND_PRIVATE_IP`
- [ ] `CR_PAT` has `write:packages` scope (can push to GHCR)
- [ ] `DOCKER_GITHUB_USERNAME` is your GitHub username (not org name)

### 2. Build Stage (docker buildx bake)
- [ ] `.github/workflows/cd.yaml` exists (only ONE file with this trigger)
- [ ] `docker-compose.prod.yml` has `build:` sections for each service
- [ ] `GITHUB_OWNER` is lowercase in build command: `$(echo "${{ github.repository_owner }}" | tr '[:upper:]' '[:lower:]')`
- [ ] Image tags match GHCR format: `ghcr.io/${GITHUB_OWNER}/service-name:latest`
- [ ] Multi-platform set correctly: `--set *.platform=linux/amd64,linux/arm64`

### 3. GHCR Login Issues
- [ ] Login happens BEFORE any `docker` or `docker compose` command
- [ ] If using **sudo** in remote SSH session: login must also use **sudo** (context isolation)
  - ❌ Wrong: `echo "$PAT" | docker login` then `sudo docker compose pull`
  - ✅ Right: `echo "$PAT" | sudo docker login` then `sudo docker compose pull`
- [ ] Login command format: `echo $CR_PAT | docker login ghcr.io -u $DOCKER_GITHUB_USERNAME --password-stdin`

### 4. Deployment Compose Files (backend.yml, nginx.yml)
- [ ] Removed all `build:` sections (deployment files pull, don't build)
- [ ] Added `pull_policy: always` to force fresh image pulls
- [ ] Added `networks:` definition for service isolation
- [ ] Environment variables passed correctly from `.env` file
- [ ] Port mappings match expected architecture (backend 8080, nginx 80)

### 5. SSH & Bastion Proxy
- [ ] SSH key copied to GitHub runner and permissions: `chmod 600 ~/.ssh/ssh_key`
- [ ] Bastion (nginx) VM must allow SSH from runner (Azure NSG rules opened on port 22)
- [ ] Backend VM accessible ONLY via bastion with ProxyCommand:
  ```
  -o ProxyCommand="ssh -i ~/.ssh/ssh_key -W %h:%p ... $SSH_USER@$SSH_HOST_NGINX"
  ```
- [ ] Preflight SSH test runs BEFORE transferring files

### 6. Environment & Secrets at Runtime
- [ ] `.env` file created on runner with lowercase `GITHUB_OWNER`
- [ ] `.env` transferred to VM before any `docker compose` commands
- [ ] Secrets passed explicitly to SSH commands via `env:` section (not just inherited)
- [ ] `BACKEND_PRIVATE_IP` used correctly in nginx `.env` for proxy config

---

## Common Error Patterns & Fixes

### Error: "Login Succeeded" followed by "unauthorized: authentication required"

**Root Cause:** GHCR login happened in one shell context (or without sudo), but `docker pull` happens in a different context (or with sudo).

**Fix:**
```bash
# WRONG ❌
echo "$CR_PAT" | docker login ghcr.io -u "$USERNAME" --password-stdin
sudo docker compose pull  # Different context!

# RIGHT ✅
echo "$CR_PAT" | sudo docker login ghcr.io -u "$USERNAME" --password-stdin
sudo docker compose pull  # Same sudo context
```

### Error: Duplicate workflow runs on same push

**Root Cause:** Two `.yaml` files in `.github/workflows/` with same `name:` and `on:` trigger.

**Fix:**
- Delete the duplicate workflow file (keep only one)
- Verify: `ls .github/workflows/` shows exactly ONE file

### Error: "image not found" or old image used after push

**Root Cause:** Docker Compose pulling from local cache instead of GHCR.

**Fix:**
```yaml
services:
  backend:
    image: ghcr.io/${GITHUB_OWNER}/app:latest
    pull_policy: always  # Force fresh pull every time
```

### Error: Backend unreachable from nginx

**Root Cause:** Missing or incorrect networking between services, or services on separate VMs without correct hostname resolution.

**Fix:**
- **Single VM:** Add `networks:` definition so services can reach each other by name
  ```yaml
  services:
    backend:
      networks:
        - app-network
    nginx:
      networks:
        - app-network
  networks:
    app-network:
      driver: bridge
  ```
- **Multiple VMs:** Use private IP address directly in nginx config:
  ```
  proxy_pass http://${BACKEND_PRIVATE_IP}:8080;
  ```

### Error: Environment variables not set in container

**Root Cause:** `.env` file not transferred to VM, or not in same directory as `docker-compose.yml`.

**Fix:**
```bash
# Transfer .env first
scp -i ~/.ssh/ssh_key .env $SSH_USER@$HOST:.env

# Then deploy (docker compose reads .env automatically from working dir)
ssh -i ~/.ssh/ssh_key $SSH_USER@$HOST "cd ~ && docker compose up -d"
```

---

## Workflow Structure Best Practices

### docker-compose.prod.yml (Build Phase)
```yaml
# For BUILD ONLY — includes build directives
services:
  backend:
    image: ghcr.io/${GITHUB_OWNER}/app_backend:latest
    build:                          # ✅ Build directive present
      context: ./backend
      dockerfile: Dockerfile.prod
    networks:
      - app-network
```

### docker-compose.backend.yml (Deploy Phase)
```yaml
# For DEPLOY ONLY — pull only, no build
services:
  backend:
    image: ghcr.io/${GITHUB_OWNER}/app_backend:latest
    pull_policy: always            # ✅ Force fresh pull
    environment:
      - FLASK_ENV=production
    ports:
      - "8080:8080"
    networks:                       # ✅ Network isolation
      - app-network
networks:
  app-network:
    driver: bridge
```

### Key Differences
| Item | prod.yml | backend.yml |
|------|----------|-------------|
| **Purpose** | CI build (GitHub Actions) | CD deploy (VMs) |
| `build:` section | ✅ Required | ❌ Remove it |
| `pull_policy` | Not needed | ✅ Add `always` |
| `networks` | Optional | ✅ Recommended |
| `image` tag | Must match GHCR path | Must match built image |

---

## Initial Diagnosis Questions (Ask These First)

When setting up or debugging, ask:

1. **Build Strategy**
   - Does GitHub Actions build and push, or is it local?
   - Are you using `docker buildx bake` with `--push` flag?

2. **GHCR Access**
   - Is `CR_PAT` valid with `write:packages` scope?
   - Are your images public or private?
   - Can you manually `docker pull ghcr.io/.../image:latest` locally?

3. **Deployment Architecture**
   - Single VM or multi-VM (bastion pattern)?
   - Backend private (no public IP) or public?
   - SSH to VMs: direct or via proxy?

4. **Networking**
   - Services on same VM → use Docker networks
   - Services on separate VMs → use private IP addresses
   - Nginx needs to reach backend on which IP:port?

5. **Secrets & Permissions**
   - All secrets in GitHub settings?
   - SSH key has correct permissions (600)?
   - VMs firewall rules allow ports 80, 443, 8080, 22?

---

## Checklists by Scenario

### Scenario A: Single-VM Docker Compose

✅ Both backend and nginx on same VM
✅ Use Docker network for inter-service communication
✅ GHCR login before `docker compose pull`
✅ No SSH bastion needed (direct deploy)

### Scenario B: Two-VM with Bastion

✅ Nginx VM public (bastion)
✅ Backend VM private (no public IP)
✅ SSH from GitHub runner → nginx bastion → backend
✅ Backend reaches GHCR via nginx outbound (or direct if egress allowed)
✅ Nginx reaches backend via private IP on port 8080

### Scenario C: Multi-Service with Private GHCR

✅ All images private (org/team scope)
✅ CR_PAT and DOCKER_GITHUB_USERNAME in GitHub Secrets
✅ Login in workflow **before** any docker command
✅ If sudo needed on VM, wrap login with `sudo`
✅ Transfer `.env` with all secrets before deploy

---

## Assets & Templates

### GitHub Actions Workflow Template

```yaml
name: Build and Deploy

on:
  push:
    branches: [main]

env:
  CR_PAT: ${{ secrets.CR_PAT }}
  DOCKER_GITHUB_USERNAME: ${{ secrets.DOCKER_GITHUB_USERNAME }}

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v4
      - run: |
          GITHUB_OWNER=$(echo "${{ github.repository_owner }}" | tr '[:upper:]' '[:lower:]')
          echo ${{ env.CR_PAT }} | docker login ghcr.io -u ${{ env.DOCKER_GITHUB_USERNAME }} --password-stdin
          GITHUB_OWNER=$GITHUB_OWNER docker buildx bake -f docker-compose.prod.yml \
            --set *.platform=linux/amd64,linux/arm64 --push
        working-directory: ./src

  deploy:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: |
          mkdir -p ~/.ssh
          printf '%s\n' "$SSH_PRIVATE_KEY" > ~/.ssh/ssh_key
          chmod 600 ~/.ssh/ssh_key
        env:
          SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
      - run: |
          ssh -i ~/.ssh/ssh_key -o StrictHostKeyChecking=no $SSH_USER@$SSH_HOST << EOF
          echo "$CR_PAT" | sudo docker login ghcr.io -u "$DOCKER_GITHUB_USERNAME" --password-stdin
          cd ~/app && sudo docker compose pull && sudo docker compose up -d
          EOF
        env:
          SSH_USER: ${{ secrets.SSH_USER }}
          SSH_HOST: ${{ secrets.SSH_HOST }}
          CR_PAT: ${{ secrets.CR_PAT }}
          DOCKER_GITHUB_USERNAME: ${{ secrets.DOCKER_GITHUB_USERNAME }}
```

---

## References

- [GitHub Container Registry Docs](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)
- [Docker Buildx Bake](https://docs.docker.com/build/bake/)
- [GitHub Actions Secrets](https://docs.github.com/en/actions/security-guides/encrypted-secrets)
- [SSH ProxyCommand for Bastion](https://linux.die.net/man/5/ssh_config)
