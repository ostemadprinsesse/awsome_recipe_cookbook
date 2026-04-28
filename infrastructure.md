# Infrastructure

Use script for the Azure two-VM setup:

```bash
bash infrastructure/setup_azure_vms.sh
```

teardown with one of these options 
```bash
bash infrastructure/setup_azure_vms.sh --teardown
bash infrastructure/teardown_azure_vms.sh
```


Before running, make sure the `LOCATION` in `infrastructure/setup_azure_vms.sh` matches the Azure region your subscription allows. We default to `swedencentral`.

When setup is done, open the app in your browser at:

```text
http://<nginx-public-ip>/
```

The backend VM is private, so you do not browse to it directly. If you need to test it, SSH into the nginx VM and curl the backend private IP on port `8080`.