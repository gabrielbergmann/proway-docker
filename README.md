# Pizzaria Auto-Deploy

This repository includes an idempotent deployment script that installs Docker, pulls the latest code, rebuilds images when needed, and brings the stack up via Docker Compose. It also installs itself in `cron` to self-update every 5 minutes.

## Features

- One-line install (root): installs Docker CE and the compose plugin on Debian/Ubuntu or RHEL-like distros.
- Git-aware updates: `git pull` on the repo directory and automatic rebuild only when relevant files change (Dockerfile, compose, app sources, lockfiles). You can force rebuild on every run by setting `ALWAYS_REBUILD=true`.
- Safe concurrency: uses `flock` to prevent overlapping runs from cron.
- Self-scheduling: adds a `root` cron entry to run every 5 minutes.
- Git hooks (`post-merge`, `post-checkout`) mark when a rebuild is necessary, accelerating the update loop after `git push`.

## Quick Start

```bash
sudo mkdir -p /opt/pizzaria
curl -fsSL https://raw.githubusercontent.com/<youruser>/<yourrepo>/main/deploy.sh -o /usr/local/bin/pizzaria_deploy.sh
sudo chmod +x /usr/local/bin/pizzaria_deploy.sh

# Optional configuration
export REPO_URL="https://github.com/<youruser>/<yourrepo>.git"  # defaults to gabrielbergmann/proway-docker
export PIZZA_PORT=8080                                         # external port, defaults to 8080
export ALWAYS_REBUILD=false                                    # set to true to force rebuild each run

# First run
sudo /usr/local/bin/pizzaria_deploy.sh
