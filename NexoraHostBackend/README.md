# Nexora Host Private Backend — Phase 1

This is the remote execution side of the Nexora Host iPhone client. It is intentionally single-owner and has no registration, teams, plans, billing or customer logic.

## What works in this vertical slice

- owner bearer-token authentication
- clone a GitHub repository
- create an empty/template project
- runtime/framework/package-manager detection
- remote project file browser, read/write/create/delete
- dependency setup task
- remote terminal commands as cancellable tasks
- start / stop / restart a detected project
- project logs
- Linux listening-port detection and preview URL generation
- Git status / pull / commit / optional push
- runtime inventory for Node.js, Bun, Python, Lua, Go, Rust, Java, .NET, Ruby, PHP, Git, Docker, GCC/G++
- recent task/activity list
- running-process list

## Security model

The service requires `NEXORA_OWNER_TOKEN` for every endpoint except `/api/v1/health`.

Project commands are refused when the backend itself runs as root unless `NEXORA_ALLOW_ROOT=1` is explicitly set. The provided systemd unit runs as a dedicated `nexora` user. Dangerous shell patterns such as `sudo`, `rm -rf /`, `mkfs`, reboot/shutdown and hard Git cleanup require an explicit confirmation flag.

Put HTTPS in front of the backend before accessing it over the internet. A reverse proxy such as Caddy or nginx is appropriate.

## Debian install

Copy this folder to the server and run once as root:

```bash
chmod +x install.sh
./install.sh
nano /opt/nexora/backend/.env
systemctl restart nexora
systemctl status nexora
```

Set at least:

```env
NEXORA_OWNER_TOKEN=a-long-random-secret
NEXORA_PUBLIC_HOST=your-server-hostname-or-ip
NEXORA_PUBLIC_SCHEME=https
```

If you want private GitHub repositories, set `GITHUB_TOKEN` in the backend `.env`. Do not put it in project files.

Then configure the same backend URL and owner token in the Nexora Host iPhone app under Settings.

## Not claimed as finished yet

The larger specification deliberately says to build a strong vertical slice first. These modules remain later phases rather than being faked here:

- autonomous multi-step Agent worker with checkpoints and repeat-until-green loops
- Docker/Compose management panel
- production deployment history, zero-downtime switching and rollback
- database provisioning/backup manager
- Discord/generic webhooks and automation builder
- push notifications, Share Sheet and Apple Shortcuts
- process resource limits/containers per project
- full WebSocket terminal multiplexing
- public reverse-proxy/domain management from the app

The iPhone client already exposes the coherent Phase-1 workflow so those services can be added behind the same remote architecture.
