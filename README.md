# IPC Docker Setup

This guide documents the setup used on the IPC for Docker-based deployment of this repository on Ubuntu 24.04.

## 1. Prerequisites

1. Install Docker Engine and the Docker Compose plugin on the IPC.

This repo includes a setup script at [setup/docker-install.sh](setup/docker-install.sh).

Example:

```bash
chmod +x ./setup/docker-install.sh
sudo ./setup/docker-install.sh --user apollo
```

If you need the optional compatibility package for older Docker Desktop integrations, use:

```bash
sudo ./setup/docker-install.sh --user apollo --with-docker-desktop-compat
```

Notes:

- this installs Docker Engine inside the current Ubuntu environment using Docker's official apt repository
- if you're in WSL and `docker` is missing because Docker Desktop integration is disabled, this installs Docker directly inside the distro instead
- after the script adds a user to the `docker` group, open a new login shell or sign out and back in
- if systemd is not active in the target environment, Docker may install successfully without auto-starting the daemon

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

2. Install Node

If you need the Node.js toolchain used by the UI and bridge repos, this repo includes [setup/node-install.sh](setup/node-install.sh).

Example:

```bash
chmod +x ./setup/node-install.sh
sudo ./setup/node-install.sh --user apollo --node-version v22.21.1
```

Notes:

- this installs `nvm` into the target user's home directory and sets Node.js `v22.21.1` as the default version
- both `machine-bridge` and `machine-ui-heroui-shadcn` currently declare support for Node.js `>=22.16.0 <23`, so `v22.21.1` fits that range
- after installation, open a new shell or run `source ~/.bashrc` as the target user before using `node`, `npm`, or `nvm`

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
sudo bash ./setup/ethercat-network-tuning.sh --nic enp3s0 --cpu 3
```

Defaults:

- NIC: `enp3s0`
- CPU: `3`


The script prints the live NIC state after installation so you can confirm queue count, coalescing, offload state, qdisc, and IRQ placement.

## 8. Probe EtherCAT Traffic On A NIC

This repo includes a diagnostic script at [setup/ethercat-device-check.py](setup/ethercat-device-check.py).

Use it when you need to answer one narrow question from Linux: does a given NIC see EtherCAT frames, and are slave responses coming back on that interface?

Example:

```bash
chmod +x ./setup/ethercat-device-check.py
sudo ./setup/ethercat-device-check.py --nic enp3s0 --duration 10
```

How to interpret the result:

- `this NIC is seeing EtherCAT responses from the bus` means the interface is connected to an active EtherCAT segment and frames are returning from at least one device
- `the host is sending EtherCAT traffic, but no slave responses were observed` usually means the master is transmitting on the correct NIC but the bus is not replying
- `no EtherCAT traffic was observed` means either the wrong NIC was selected or no EtherCAT master traffic was present during the capture window

Notes:

- this is a passive traffic probe, not a full EtherCAT master scan
- to get a useful result, run it while CODESYS or another EtherCAT master is actively trying to start the bus
- the script also prints NIC RX and TX packet deltas during the capture window so you can spot TX-only behavior quickly

If you need to stop CODESYS temporarily and run an active Linux-side EtherCAT slave scan, use [setup/ethercat-active-scan.sh](setup/ethercat-active-scan.sh).

Build the SOEM scanner without touching runtime:

```bash
chmod +x ./setup/ethercat-active-scan.sh
sudo ./setup/ethercat-active-scan.sh --build-only --nic enp3s0
```

Run a full stop-scan-restart cycle:

```bash
sudo ./setup/ethercat-active-scan.sh --nic enp3s0
```

Notes:

- this is an active EtherCAT master probe, so it cannot share the NIC with a running CODESYS EtherCAT master
- the script builds SOEM `slaveinfo` in Docker under `/var/tmp/machine-docker-soem`
- if CODESYS runtime is active, the script stops it before scanning and restarts it automatically afterwards
- pass `--leave-runtime-stopped` if you need to inspect state before bringing CODESYS back up

## 9. Apply Permissions

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

That helper removes and recreates `/opt/repos/machine-ui-heroui-shadcn/.next` with the correct ownership for the configured Linux user, and it also repairs `/opt/repos/machine-ui-heroui-shadcn/node_modules` and `/opt/repos/machine-ui-heroui-shadcn/next-env.d.ts` ownership if a container or root-owned run leaves them inaccessible.

## 11. Launch Only `mqtt` And `mongodb`

These services use published images, so there is no local build step.

```bash
docker compose pull mqtt mongodb
docker compose up -d mqtt mongodb
docker compose ps mqtt mongodb
```

## 12. Launch A Single Service

```bash
docker compose up -d <service-name>
```

## 13. Configure A Dedicated X11 Kiosk Client

This repo includes a setup script at [setup/kiosk-ui-client.sh](setup/kiosk-ui-client.sh).

Use it when a separate Ubuntu client machine should boot directly into a persistent kiosk session using:

- `lightdm` autologin
- `openbox` on X11
- `chromium-browser` in fullscreen kiosk mode

The script will:

- install the required packages if they are missing
- create or reuse a dedicated `kiosk` user
- configure LightDM autologin for that user
- write `/home/kiosk/.config/openbox/autostart`
- disable screen blanking, DPMS, and screensaver
- map `apollo-<machine-id>` to the target UI IP in `/etc/hosts`
- detect whether the machine has a real display connected
- install an Xorg dummy display automatically when no display hardware is detected, unless you explicitly disable that behavior
- restart LightDM and print verification output including `loginctl`, the final autostart file, and the running Chromium command line

Example for machine `00254`:

```bash
cd /opt/repos/machine-docker
chmod +x ./setup/kiosk-ui-client.sh
sudo ./setup/kiosk-ui-client.sh \
    --machine-id 00254 \
    --host-ip 127.0.0.1 \
    --url http://127.0.0.1:3000/ \
    --portrait
```

Notes:

- This script targets a LightDM + Openbox X11 kiosk session, not GNOME.
- The default kiosk user is `kiosk`.
- The default display is `:0`.
- The default dummy display mode is `auto`, which installs an Xorg dummy display if no connected local display hardware is detected.
- If you want the script to fail instead of configuring a dummy display, pass `--dummy-display never`.
- Pass `--portrait` to rotate the kiosk display into portrait mode before Chromium starts.
- The generated Openbox autostart launches Chromium with the kiosk flags requested for the machine UI.

## 14. Configure Local MQTT WSS Hostname
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

If the host EtherCAT-facing NIC should use a fixed local address, install it with:

```bash
chmod +x ./setup/network-static-ip.sh
sudo ./setup/network-static-ip.sh --nic enp2s0 --address 192.168.102.1/24
```

That script prefers NetworkManager when available and otherwise writes a dedicated netplan file so the address persists across reboots without taking over the default route.

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

If a dedicated client should reach the IPC over its machine-side NIC instead of VPN or DNS, point that alias at the IPC NIC directly and import the bundled Caddy root certificate into the browser profile:

```bash
chmod +x ./setup/chrome-ui-autostart.sh
sudo ./setup/chrome-ui-autostart.sh \
    --user apollo \
    --url http://apollo-00225:3000/ \
    --host-alias apollo-00225 \
    --host-ip 192.168.102.1
```

That command updates `/etc/hosts`, imports `certs/caddy-local-root.crt` into the target user's NSS trust store for Chrome/Chromium, and installs the persistent desktop autostart entry.

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


## 14. Useful Operations

### MongoDB backup

```bash
docker exec -it mongo sh -c 'exec mongodump --archive --gzip' > mongo_backup.gz
```

### Remote IPC

- IP: `10.70.70.XXX`
- User: `apollo`

### Copy local SSH public key to remote IPC from Windows

```powershell
type $env:USERPROFILE\.ssh\id_rsa.pub | ssh apollo-admin@10.70.70.50 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```