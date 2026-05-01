git clone [<repo-url>](https://github.com/kuriousDesign/machine-docker.git) machine-docker
cd machine-docker

# MIGHT SETUP EACH DOCKER TO RUN AS USER
docker run --user "$(id -u):$(id -g)" -v /opt/repos/myrepo:/app ...

# GET LATEST CODE
git submodule update --remote --init --recursive

# RUN ONE SERVICE
docker compose up -d <service-name>


# REMOTE IPC
192.168.70.12
hostname: APO-IPC-00251-01
user: apollo-admin

## copy cert to remote ssh on windows
type $env:USERPROFILE\.ssh\id_rsa.pub | ssh apollo-admin@10.70.70.50 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"


# MONGO DB DATA VOLUME BACKUP
docker exec -it mongo sh -c 'exec mongodump --archive --gzip' > mongo_backup.gz

# RECORDINGS DIRECTORY CREATION
# Create the directory
sudo mkdir -p /opt/recordings
# Give it full permissions so your current user and future Docker containers can write
sudo chmod 777 /opt/recordings

# 💾 IPC Disk Space Management & Prevention Guide

This guide summarizes the configurations applied to **APO-IPC-00251-01** to prevent `100% disk usage` failures caused by Docker bloat and system logs.

## 1. Automated Weekly Cleanup (Cron)
A root-level cron job is scheduled to prune orphaned Docker data every Sunday at midnight.

*   **Configured via:** `sudo crontab -e`
*   **Schedule:** `0 0 * * 0` (Weekly)
*   **Command:** 
    ```bash
    /usr/bin/docker system prune -af --volumes > /var/log/docker_prune.log 2>&1
    ```
*   **Action:** Automatically deletes unused images, stopped containers, build caches, and orphaned volumes.

## 2. System Log Limitations (journalctl)
The `systemd` journal is capped to prevent it from consuming gigabytes of space over time.

*   **Immediate Cleanup:** `sudo journalctl --vacuum-size=200M`
*   **Permanent Cap:** Modified `/etc/systemd/journald.conf`
    *   Set: `SystemMaxUse=500M`
    *   Apply: `sudo systemctl restart systemd-journald`
*   **Action:** Ensures system logs never exceed 500MB total.

## 3. Docker Container Log Rotation
Individual container logs are limited to prevent "hidden" bloat in `/var/lib/docker/containers/`.

### Global Configuration (Recommended)
Applied via `/etc/docker/daemon.json`:
```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  }
}
