# 🍕 Pizzaria Deploy Script

This repository contains a Bash script that automates the process of **continuous deployment** of an application (example: pizzaria) hosted in a Git repository, using **Docker** and **docker-compose**.

The script is designed to:

- Automatically clone or update the application repository.
- Detect changes and rebuild the stack (via docker-compose or Dockerfile fallback).
- Ensure containers are always running.
- Install Git hooks to trigger automatic rebuilds on branch changes or merges.
- Schedule periodic checks every 5 minutes via cron.
- Prevent concurrent executions using a lock file.

---

## 📋 Prerequisites

- **Operating System:** Linux (Debian/Ubuntu recommended).
- **Permissions:** Script must be run as `root` or via `sudo`.
- **Dependencies automatically installed:**  
  - `curl`
  - `git`
  - `docker.io`
  - `docker-compose`

---

## ⚙️ Configuration

Variables can be defined in the environment before execution or fall back to defaults:

| Variable         | Default                                                                | Description |
|------------------|------------------------------------------------------------------------|-------------|
| `REPO_URL`       | `https://github.com/gabrielbergmann/proway-docker.git`                | Git repository URL of the application. |
| `BASE_DIR`       | `/opt/pizzaria`                                                        | Base installation directory. |
| `APP_DIR`        | `$BASE_DIR/proway-docker`                                              | Application directory. |
| `LOG_FILE`       | `/var/log/pizzaria_deploy.log`                                         | Path to the log file. |
| `CRON_FILE`      | `/etc/cron.d/pizzaria-deploy`                                          | Cron configuration file. |
| `LOCK_FILE`      | `/var/lock/pizzaria_deploy.lock`                                       | Lock file to prevent concurrent executions. |
| `PIZZA_PORT`     | `8080`                                                                 | External port exposed (default `8080`). |
| `ALWAYS_REBUILD` | `false`                                                                | If `true`, forces rebuild on every run. |

---

## 🚀 How to Use

1. **Download the script** to the server:

   ```bash
   curl -o /opt/pizzaria/deploy.sh https://raw.githubusercontent.com/your-repo/deploy.sh
   chmod +x /opt/pizzaria/deploy.sh
