#!/bin/bash

# Enhanced Azure VM Setup Script for CI/CD Demo
# Creates two VMs in a shared VNet:
#   - nginx VM  : public-facing, ports 80/443 open
#   - backend VM: internal, port 8080 accessible within VNet only
# Also sets VM IPs and backend private IP in GitHub secrets

set -e  # Exit on any error

# Parse command line arguments
NO_COLORS=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --no-colors    Disable colored output"
            echo "  --help, -h     Show this help message"
            exit 0
            ;;
        --no-colors)
            NO_COLORS=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# Configuration variables - CUSTOMIZE THESE
RESOURCE_GROUP="recipe-cookbook-rg"
LOCATION="swedencentral"  # Change to your preferred region (e.g., "eastus", "northeurope")
NGINX_VM_NAME="recipe-cookbook-nginx-vm"
BACKEND_VM_NAME="recipe-cookbook-backend-vm"
VM_SIZE="Standard_B1s"  # Change to "Standard_B2s" for better performance
VM_IMAGE="Canonical:0001-com-ubuntu-server-jammy:22_04-lts:latest"
ADMIN_USERNAME="azureuser"
SSH_KEY_PATH="$HOME/.ssh/id_rsa.pub"   # Change this path to point at your public key - (your private key should be in the same folder, and should be set in SSH_PRIVATE_KEY on GitHub)
VNET_NAME="recipe-cookbook-vnet"
SUBNET_NAME="recipe-cookbook-subnet"

# Disable all color output
GREEN=''
YELLOW=''
RED=''
NC=''

echo "=========================================="
echo "Enhanced Azure VM Setup for Recipe Cookbook"
echo "Two-VM deployment: nginx + backend"
echo "=========================================="
echo ""

# Check if Azure CLI is installed
if ! command -v az &> /dev/null; then
    echo -e "${RED}❌ Azure CLI is not installed${NC}"
    echo "Install it from: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi

echo -e "${GREEN}✅ Azure CLI is installed${NC}"

# Check if logged in to Azure
echo ""
echo "Checking Azure login status..."
if ! az account show &> /dev/null; then
    echo -e "${YELLOW}⚠️  Not logged in to Azure${NC}"
    echo "Logging in..."
    az login
else
    echo -e "${GREEN}✅ Already logged in to Azure${NC}"
    ACCOUNT=$(az account show --query name -o tsv)
    echo "Using subscription: $ACCOUNT"
fi

# Check if SSH key exists
echo ""
if [ ! -f "$SSH_KEY_PATH" ]; then
    echo -e "${YELLOW}⚠️  SSH key not found at $SSH_KEY_PATH${NC}"
    echo "Generating new SSH key..."
    ssh-keygen -t rsa -b 4096 -f "${SSH_KEY_PATH%.pub}" -N "" -C "azure-vm-cicd"
    echo -e "${GREEN}✅ SSH key generated${NC}"
else
    echo -e "${GREEN}✅ SSH key found at $SSH_KEY_PATH${NC}"
fi

# Create resource group
echo ""
echo "=========================================="
echo "Creating Resource Group"
echo "=========================================="
echo "Name: $RESOURCE_GROUP"
echo "Location: $LOCATION"

if az group exists --name "$RESOURCE_GROUP" | grep -q "true"; then
    echo -e "${YELLOW}⚠️  Resource group already exists${NC}"
    read -p "Do you want to delete and recreate it? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Deleting existing resource group..."
        az group delete --name "$RESOURCE_GROUP" --yes --no-wait
        echo "Waiting for deletion to complete..."
        sleep 10
    else
        echo "Using existing resource group"
    fi
fi

if ! az group exists --name "$RESOURCE_GROUP" | grep -q "true"; then
    az group create \
        --name "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --output table
    echo -e "${GREEN}✅ Resource group created${NC}"
fi

# Create shared Virtual Network
echo ""
echo "=========================================="
echo "Creating Shared Virtual Network"
echo "=========================================="
echo "VNet: $VNET_NAME"
echo "Subnet: $SUBNET_NAME"

az network vnet create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VNET_NAME" \
    --address-prefix 10.0.0.0/16 \
    --subnet-name "$SUBNET_NAME" \
    --subnet-prefix 10.0.1.0/24 \
    --output table

echo -e "${GREEN}✅ Virtual network created${NC}"

# Create nginx VM
echo ""
echo "=========================================="
echo "Creating nginx VM (public-facing)"
echo "=========================================="
echo "VM Name: $NGINX_VM_NAME"
echo "Size: $VM_SIZE"
echo "This may take 2-5 minutes..."
echo ""

az vm create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$NGINX_VM_NAME" \
    --image "$VM_IMAGE" \
    --size "$VM_SIZE" \
    --admin-username "$ADMIN_USERNAME" \
    --ssh-key-values "$SSH_KEY_PATH" \
    --vnet-name "$VNET_NAME" \
    --subnet "$SUBNET_NAME" \
    --public-ip-sku Standard \
    --no-wait \
    --output none

echo "nginx VM creation started (running in background)..."
echo "Waiting for nginx VM to be provisioned..."
sleep 60

# Check if VM was created successfully
if az vm show --resource-group "$RESOURCE_GROUP" --name "$NGINX_VM_NAME" &> /dev/null; then
    echo -e "${GREEN}✅ nginx VM created${NC}"
else
    echo -e "${RED}❌ Failed to create nginx VM${NC}"
    exit 1
fi

# Create backend VM
echo ""
echo "=========================================="
echo "Creating backend VM (internal)"
echo "=========================================="
echo "VM Name: $BACKEND_VM_NAME"
echo "Size: $VM_SIZE"
echo "This may take 2-5 minutes..."
echo ""

az vm create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$BACKEND_VM_NAME" \
    --image "$VM_IMAGE" \
    --size "$VM_SIZE" \
    --admin-username "$ADMIN_USERNAME" \
    --ssh-key-values "$SSH_KEY_PATH" \
    --vnet-name "$VNET_NAME" \
    --subnet "$SUBNET_NAME" \
    --public-ip-sku Standard \
    --no-wait \
    --output none

echo "backend VM creation started (running in background)..."
echo "Waiting for backend VM to be provisioned..."
sleep 60

# Check if VM was created successfully
if az vm show --resource-group "$RESOURCE_GROUP" --name "$BACKEND_VM_NAME" &> /dev/null; then
    echo -e "${GREEN}✅ backend VM created${NC}"
else
    echo -e "${RED}❌ Failed to create backend VM${NC}"
    exit 1
fi

# Configure network security for nginx VM (ports 80 and 443)
echo ""
echo "=========================================="
echo "Configuring Network Security"
echo "=========================================="
echo "nginx VM: opening ports 22 (SSH), 80 (HTTP), 443 (HTTPS)"

az vm open-port \
    --resource-group "$RESOURCE_GROUP" \
    --name "$NGINX_VM_NAME" \
    --port 80 \
    --priority 300 \
    --output table

az vm open-port \
    --resource-group "$RESOURCE_GROUP" \
    --name "$NGINX_VM_NAME" \
    --port 443 \
    --priority 310 \
    --output table

echo -e "${GREEN}✅ nginx VM ports configured${NC}"

# Port 8080 on the backend VM is accessible within the VNet by default
# (Azure's AllowVnetInbound rule covers intra-VNet traffic on all ports).
# No internet-facing port openings are needed for the backend VM beyond SSH.
echo ""
echo "backend VM: port 22 (SSH) open, port 8080 accessible within VNet only"
echo -e "${GREEN}✅ backend VM network configured${NC}"

# Get VM public IPs
echo ""
echo "=========================================="
echo "Getting VM Information"
echo "=========================================="

NGINX_PUBLIC_IP=$(az vm show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$NGINX_VM_NAME" \
    --show-details \
    --query publicIps \
    --output tsv)

BACKEND_PUBLIC_IP=$(az vm show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$BACKEND_VM_NAME" \
    --show-details \
    --query publicIps \
    --output tsv)

BACKEND_PRIVATE_IP=$(az vm show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$BACKEND_VM_NAME" \
    --show-details \
    --query privateIps \
    --output tsv)

echo ""
echo "nginx VM  — Public IP : ${GREEN}$NGINX_PUBLIC_IP${NC}"
echo "backend VM — Public IP : ${GREEN}$BACKEND_PUBLIC_IP${NC}"
echo "backend VM — Private IP: ${GREEN}$BACKEND_PRIVATE_IP${NC}"
echo ""
echo "nginx will proxy to backend via private IP: $BACKEND_PRIVATE_IP:8080"

# Wait for VMs to be fully ready
echo ""
echo "Waiting for VMs to be fully ready (this may take several minutes)..."
sleep 120

# Helper function to set up a single VM
setup_vm() {
    local VM_IP="$1"
    local VM_LABEL="$2"

    echo ""
    echo "=========================================="
    echo "Connecting to $VM_LABEL VM and updating system"
    echo "=========================================="

    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 "$ADMIN_USERNAME@$VM_IP" "
        set -e
        echo 'Connected to VM, starting system update...'

        echo 'Updating package lists...'
        sudo apt update -y

        echo 'Upgrading installed packages...'
        sudo apt upgrade -y

        echo 'Installing basic utilities...'
        sudo apt install -y curl wget git unzip

        echo 'Cleaning up...'
        sudo apt autoremove -y
        sudo apt autoclean

        echo 'System update and upgrade complete!'
        echo 'VM is ready for Docker installation.'
    "; then
        echo -e "${GREEN}✅ $VM_LABEL VM system update completed successfully${NC}"
    else
        echo -e "${YELLOW}⚠️  SSH connection to $VM_LABEL VM failed. VM may still be initializing.${NC}"
        exit 1
    fi
}

setup_vm "$NGINX_PUBLIC_IP" "nginx"
setup_vm "$BACKEND_PUBLIC_IP" "backend"

# Install Docker on both VMs
echo ""
read -p "Do you want to install Docker on both VMs now? (Y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then

    install_docker() {
        local VM_IP="$1"
        local VM_LABEL="$2"

        echo ""
        echo "=========================================="
        echo "Installing Docker on $VM_LABEL VM"
        echo "=========================================="

        ssh -o StrictHostKeyChecking=no "$ADMIN_USERNAME@$VM_IP" << 'ENDSSH'
            set -e
            echo "Updating package index..."
            sudo apt update

            echo "Installing prerequisites..."
            sudo apt install -y apt-transport-https ca-certificates curl software-properties-common

            echo "Adding Docker GPG key..."
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

            echo "Adding Docker repository..."
            echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

            echo "Installing Docker and Docker Compose..."
            sudo apt update
            sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

            echo "Adding user to docker group..."
            sudo usermod -aG docker $USER

            echo "Enabling UFW firewall..."
            sudo ufw --force enable
            sudo ufw allow 22/tcp
            sudo ufw allow 80/tcp
            sudo ufw allow 443/tcp

            echo "Creating app directory..."
            mkdir -p ~/app

            echo "Docker installation complete!"
            docker --version
            docker compose version
ENDSSH

        echo -e "${GREEN}✅ Docker installed on $VM_LABEL VM${NC}"
    }

    install_docker "$NGINX_PUBLIC_IP" "nginx"
    install_docker "$BACKEND_PUBLIC_IP" "backend"

    echo -e "${YELLOW}⚠️  Note: You need to logout and login again for docker group changes to take effect${NC}"
fi

# Set VM IPs in GitHub secrets
echo ""
echo "=========================================="
echo "Setting VM IPs in GitHub Secrets"
echo "=========================================="

if ! command -v gh &> /dev/null; then
    echo -e "${YELLOW}⚠️  GitHub CLI is not installed${NC}"
    echo "Install it from: https://cli.github.com/"
    echo "Then run: gh auth login"
    echo ""
    echo "Manual steps to set GitHub secrets:"
    echo "1. Navigate to your GitHub repository Settings > Secrets and variables > Actions"
    echo "2. Add these secrets:"
    echo "   SSH_USER              = $ADMIN_USERNAME"
    echo "   SSH_HOST_NGINX        = $NGINX_PUBLIC_IP"
    echo "   SSH_HOST_BACKEND      = $BACKEND_PUBLIC_IP"
    echo "   BACKEND_PRIVATE_IP    = $BACKEND_PRIVATE_IP"
    echo "   SSH_PRIVATE_KEY       = Contents of ~/.ssh/id_rsa"
    echo ""
    echo "3. Or install GitHub CLI and run this script from your repository directory"
else
    if ! gh auth status &> /dev/null; then
        echo -e "${YELLOW}⚠️  Not authenticated with GitHub CLI${NC}"
        echo "Running: gh auth login"
        gh auth login
    fi

    echo "Setting GitHub secrets..."

    echo "$ADMIN_USERNAME"    | gh secret set SSH_USER
    echo "$NGINX_PUBLIC_IP"   | gh secret set SSH_HOST_NGINX
    echo "$BACKEND_PUBLIC_IP" | gh secret set SSH_HOST_BACKEND
    echo "$BACKEND_PRIVATE_IP" | gh secret set BACKEND_PRIVATE_IP
    gh secret set SSH_PRIVATE_KEY < "${SSH_KEY_PATH%.pub}"

    echo -e "${GREEN}✅ GitHub secrets set successfully${NC}"
fi

# Summary
echo ""
echo "=========================================="
echo "Setup Complete!"
echo "=========================================="
echo ""
echo "Resource Group : ${GREEN}$RESOURCE_GROUP${NC}"
echo "VNet           : ${GREEN}$VNET_NAME${NC}"
echo ""
echo "nginx VM"
echo "  Name       : ${GREEN}$NGINX_VM_NAME${NC}"
echo "  Public IP  : ${GREEN}$NGINX_PUBLIC_IP${NC}"
echo "  Ports open : 22, 80, 443"
echo ""
echo "backend VM"
echo "  Name        : ${GREEN}$BACKEND_VM_NAME${NC}"
echo "  Public IP   : ${GREEN}$BACKEND_PUBLIC_IP${NC}"
echo "  Private IP  : ${GREEN}$BACKEND_PRIVATE_IP${NC}"
echo "  Ports open  : 22 (public), 8080 (VNet only)"
echo ""
echo "=========================================="
echo "GitHub Secrets set:"
echo "=========================================="
echo "  SSH_USER           = $ADMIN_USERNAME"
echo "  SSH_HOST_NGINX     = $NGINX_PUBLIC_IP"
echo "  SSH_HOST_BACKEND   = $BACKEND_PUBLIC_IP"
echo "  BACKEND_PRIVATE_IP = $BACKEND_PRIVATE_IP"
echo "  SSH_PRIVATE_KEY    = (from ~/.ssh/id_rsa)"
echo ""
echo "=========================================="
echo "Next Steps:"
echo "=========================================="
echo ""
echo "1. Update nginx.conf to proxy to the backend VM's private IP:"
echo "   proxy_pass http://$BACKEND_PRIVATE_IP:8080;"
echo ""
echo "2. Update the GitHub Actions workflow to deploy:"
echo "   - backend image  → backend VM  (SSH_HOST_BACKEND)"
echo "   - nginx image    → nginx VM    (SSH_HOST_NGINX)"
echo ""
echo "3. SSH to your VMs:"
echo "   ${YELLOW}ssh $ADMIN_USERNAME@$NGINX_PUBLIC_IP${NC}    (nginx)"
echo "   ${YELLOW}ssh $ADMIN_USERNAME@$BACKEND_PUBLIC_IP${NC}  (backend)"
echo ""
echo "=========================================="
echo ""
echo "To delete everything later, run:"
echo "   ${RED}./azure-teardown.sh${NC}"
echo ""
