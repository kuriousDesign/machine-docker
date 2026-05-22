# IPC Docker Setup

This guide documents the setup used on the IPC for Docker-based deployment of this repository on Ubuntu 24.04.

## 1. Prerequisites

1. Install Docker Engine and the Docker Compose plugin on the IPC.
2. Confirm Docker is available:

```bash
docker --version
docker compose version
```

## 2. Configure GitHub Authentication For `apollo`

1. Generate a dedicated SSH key for the `apollo` account:

```bash
ssh-keygen -t ed25519 -C "apollo@$(hostname)-github" -f ~/.ssh/id_ed25519_github_apollo -N ""
```

2. Create or update `~/.ssh/config` so GitHub uses SSH over port 443:

```sshconfig
Host github.com
    HostName ssh.github.com
    Port 443
    User git
    IdentityFile ~/.ssh/id_ed25519_github_apollo
    IdentitiesOnly yes
```

3. Add `~/.ssh/id_ed25519_github_apollo.pub` to the GitHub account under SSH keys.
4. Configure Git to rewrite GitHub HTTPS remotes to SSH:

```bash
git config --global url."git@github.com:".insteadOf https://github.com/
```

5. Verify GitHub authentication:

```bash
ssh -T git@github.com
```

Notes:

- Standard GitHub SSH on port 22 is blocked from this IPC.
- The `ssh.github.com:443` configuration is required for GitHub access from this machine.
- This key has no passphrase, so anyone logged in as `apollo` can authenticate as the linked GitHub account.

## 3. Clone The Repository

1. Clone the repo into `/opt/repos`:

```bash
mkdir -p /opt/repos
git -C /opt/repos clone https://github.com/kuriousDesign/machine-docker.git
cd /opt/repos/machine-docker
```

2. Pull submodules if needed:

```bash
git submodule update --remote --init --recursive
```

## 4. Refresh Docker Group Access

If Docker reports `permission denied` on `/var/run/docker.sock`, the current shell probably has stale group membership.

Run:

```bash
newgrp docker
```

Then re-enter the repo directory:

```bash
cd /opt/repos/machine-docker
```

If that still does not apply, log out of the `apollo` session and sign back in.

## 5. Prepare Local Directories

1. Create the recordings directory used by the stack:

```bash
sudo mkdir -p /opt/recordings
sudo chmod 777 /opt/recordings
```

## 6. Apply Disk Management And Docker Log Controls

This repo includes a machine setup script at [setup/disk-management.sh](setup/disk-management.sh).

1. Make sure the script is executable if needed:

```bash
chmod +x ./setup/disk-management.sh
```

2. Run the setup script:

```bash
sudo ./setup/disk-management.sh
```

What it configures:

- weekly Docker cleanup via cron
- `journald` size cap and vacuum
- Docker daemon log rotation in `/etc/docker/daemon.json`
- immediate Docker system cleanup

Note:

- `mqtt` and `mongodb` rely on this daemon-level Docker logging policy rather than per-service `logging:` blocks in Compose.

## 7. Apply EtherCAT NIC Real-Time Tuning

This repo includes a commissioning script at [setup/ethercat-network-tuning.sh](setup/ethercat-network-tuning.sh).

Use it on a new IPC to install a persistent `systemd` service that:

- collapses the EtherCAT NIC to a single queue
- disables interrupt coalescing
- disables latency-adding offloads
- applies a simple `pfifo_fast` qdisc
- pins the NIC IRQs to a dedicated CPU core

Example for the current IPC layout:

```bash
chmod +x ./setup/ethercat-network-tuning.sh
sudo bash ./setup/ethercat-network-tuning.sh --nic enp2s0 --cpu 3
```

Defaults:

- NIC: `enp3s0`
- CPU: `3`

For this IPC, use `enp2s0`.

The script prints the live NIC state after installation so you can confirm queue count, coalescing, offload state, qdisc, and IRQ placement.

## 8. Apply Permissions

This repo includes a setup script at [setup/permissions.sh](setup/permissions.sh).

Use it to install a narrow `sudoers` rule and root-owned helper commands so the UI can:

- start, stop, and restart `codesyscontrol`
- read the approved CODESYS runtime log tail
- reset the generated `machine-ui` `.next` directory if a root-owned container run leaves local dev blocked

without granting broad sudo access to the application user.

Example for the current IPC user:

```bash
chmod +x ./setup/permissions.sh
sudo ./setup/permissions.sh
```

The script auto-detects the invoking `sudo` user. If you run it from a root shell or need to target a different account, pass `--user <linux-user>` explicitly, for example `--user apollo-admin`.

The script installs:

- `/usr/local/sbin/codesys-control-action`
- `/usr/local/sbin/codesys-control-log-tail`
- `/usr/local/sbin/machine-ui-reset-build-cache`
- `/etc/sudoers.d/<user>-codesys-control`

After installation, the target user can run:

```bash
sudo -n /usr/local/sbin/machine-ui-reset-build-cache
```

That helper removes and recreates `/opt/repos/machine-ui-heroui-shadcn/.next` with the correct ownership for the configured Linux user.

## 9. Configure UI Chrome Autostart

This repo includes a setup script at [setup/chrome-ui-autostart.sh](setup/chrome-ui-autostart.sh).

Use it to install a per-user GNOME autostart entry that opens Chrome to the machine UI as soon as the desktop session logs in.

Example for the current IPC:

```bash
chmod +x ./setup/chrome-ui-autostart.sh
sudo ./setup/chrome-ui-autostart.sh --user apollo --url http://apollo-00251:3000
```

Notes:

- The script defaults to the `apollo` user if `--user` is omitted.
- Pass the exact UI URL you want the operator session to open at login.
- Chrome launches in fullscreen mode for the UI session.
- The launcher also disables common Chrome startup prompts such as first-run, default-browser, crash-recovery, and other modal error dialogs.
- Chrome is auto-detected from `google-chrome-stable`, `google-chrome`, `chromium-browser`, or `chromium` unless `--browser` is supplied.

## 10. Launch Only `mqtt` And `mongodb`

These services use published images, so there is no local build step.

```bash
docker compose pull mqtt mongodb
docker compose up -d mqtt mongodb
docker compose ps mqtt mongodb
```

## 11. Launch A Single Service

```bash
docker compose up -d <service-name>
```

## 12. Configure Local MQTT WSS Hostname

This stack can expose the local broker to browser clients through `caddy`, which terminates TLS and proxies `wss` traffic to Mosquitto on `127.0.0.1:9002`.

1. Create a repo `.env` file from `.env.example` if one does not exist.
2. Set `MQTT_WSS_HOSTNAME` to a machine-specific hostname.

Recommended pattern:

```env
MQTT_WSS_HOSTNAME=apollo-00225
```

Notes:

- Use a different suffix per IPC or project, e.g. `apollo-00225`, `apollo-00251`.
- The UI local broker URI is derived from this value as `wss://<hostname>/mqtt`.
- For private deployments, `caddy` uses its internal CA, so client devices must trust the generated root certificate.

If the IPC itself should resolve that hostname back to the local broker, install a localhost hosts-file alias:

```bash
chmod +x ./setup/network-host-alias.sh
sudo ./setup/network-host-alias.sh --machine-id 00225
```

That script adds or updates a hosts entry in the form:

```text
127.0.0.1 apollo-00225
```

For this IPC, use `00225` so the local alias becomes `apollo-00225`.

Start the proxy with:

```bash
docker compose up -d caddy
docker compose logs --tail=100 caddy
```

Add a hosts entry on each client machine that should reach the broker:

```text
10.70.70.50 apollo-00225
```

Copy the generated root certificate into the repo for distribution:

```bash
mkdir -p certs
docker exec caddy cat /data/caddy/pki/authorities/local/root.crt > certs/caddy-local-root.crt
```

The IPC checkout will then contain the certificate at `certs/caddy-local-root.crt`.

On each Windows client machine that should trust the local `wss` endpoint:

1. Import the certificate into the Trusted Root store from an elevated PowerShell:

```powershell
Import-Certificate -FilePath .\certs\caddy-local-root.crt -CertStoreLocation Cert:\LocalMachine\Root
```

2. Validate name resolution and port reachability:

```powershell
Test-NetConnection apollo-00225 -Port 443
```

For browser and Next.js clients, the local broker URI should be:

```text
wss://apollo-00225/mqtt
```

## 13. Validation

Use these checks after setup:

```bash
docker ps
docker compose ps mqtt mongodb
ssh -T git@github.com
```

For EtherCAT NIC validation:

```bash
systemctl status enp2s0-rt-network-tuning.service --no-pager -l
ethtool -l enp2s0
ethtool -c enp2s0
ethtool -k enp2s0
tc qdisc show dev enp2s0
grep -i enp2s0 /proc/interrupts
```

For CODESYS UI permissions validation:

```bash
sudo -n /usr/local/sbin/codesys-control-log-tail
sudo -n /usr/local/sbin/codesys-control-action restart
```

For Chrome UI autostart validation:

```bash
sudo cat /home/apollo/.config/autostart/machine-ui-chrome.desktop
```

## 14. Useful Operations

### MongoDB backup

```bash
docker exec -it mongo sh -c 'exec mongodump --archive --gzip' > mongo_backup.gz
```

### Remote IPC

- IP: `10.70.70.50`
- User: `apollo`

### Copy local SSH public key to remote IPC from Windows

```powershell
type $env:USERPROFILE\.ssh\id_rsa.pub | ssh apollo-admin@10.70.70.50 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```