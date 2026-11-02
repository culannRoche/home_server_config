# Home Server

Turns a fresh Debian install into a headless server that runs services in Docker, is reachable over SSH from anywhere through Tailscale, monitors its own hardware, and emails you when something goes wrong.

For safety, your user has no root access by default: admin tasks, including managing Docker, use `sudo`, which always asks for your password.

## You need

- A 64-bit machine with a **wired** network connection
- A USB stick for the Debian installer
- A free [Tailscale](https://login.tailscale.com) account, with Tailscale installed on your laptop
- Optional: an email account to send alerts from, with an **app password** (ideally a separate account used only for this)

Before first use, set `REPO_URL` in `bootstrap.sh` to this repo's URL. The repo must be public.

## Install

**1. Install Debian.** Write the [netinst ISO](https://www.debian.org/distrib/netinst) to a USB stick (e.g. with [balenaEtcher](https://etcher.balena.io/)) and boot from it. During the install:

- **Hostname**: this becomes the server's name on Tailscale, e.g. `homeserver`
- **Root password**: leave blank. Debian then locks the root account and gives your user `sudo` instead. The script requires this.
- **Software selection**: tick only *SSH server* and *standard system utilities*

**2. Get the script onto the server.** Log in and download it:

```bash
wget https://raw.githubusercontent.com/YOUR_GITHUB_USER/homeserver/main/bootstrap.sh
```

Or copy it from a USB stick with `sudo mount /dev/sdb1 /mnt && cp /mnt/bootstrap.sh ~` (use `lsblk` to find the stick).

**3. Run it.**

```bash
sudo bash bootstrap.sh
```

It first asks for your email settings (press Enter to skip), then runs by itself. When it prints a Tailscale login URL, open it on your laptop and approve the server. It finishes by sending a "Server online" email.

**4. Finish up.**

- In the [Tailscale admin console](https://login.tailscale.com/admin/machines), choose **Disable key expiry** for the server, or it will drop off your tailnet after about 180 days.
- From your laptop, connect with `ssh yourname@homeserver` (this works from anywhere).

## Monitoring

You get an email when SMART detects a disk problem, a disk reaches 55 °C, the CPU reaches 85 °C, or a disk is 90% full. All alerts are also logged; view them with `sudo journalctl -t homeserver-alert`.

For a quick look:

| Command | Shows |
|---|---|
| `htop` | Live CPU, memory and processes |
| `sensors` | Temperatures |
| `df -h` | Disk usage |
| `sar -u` / `sar -r` | CPU / memory history |

`sudo ncdu /` shows what is using disk space.

The limits are set in `/usr/local/bin/health-check` and `/etc/smartd.conf`.

## Adding services

Each service has its own folder in `services/<name>/`, containing `setup.sh`, `docker-compose.yml` and `.env.example`. The repo is cloned to `/opt/homeserver`; runtime data and real `.env` files go in `/opt/containers/<name>/`. Both are owned by root, so changing them needs `sudo`. To add one:

```bash
cd /opt/homeserver && sudo git pull
sudo bash services/<name>/setup.sh
```

Manage containers with `sudo docker ...` and `sudo docker compose ...`.

## Notes

- **No secrets live in this repo.** Email credentials are stored only on the server, in `/etc/msmtprc` (root-only).
- **Re-running `bootstrap.sh` is safe.** To change email settings, run `sudo RECONFIGURE_EMAIL=1 bash bootstrap.sh`.
- **Missed the Tailscale login?** Run `sudo tailscale up` to get a new URL.
- **Test alerts** with `sudo notify "Test" "Testing alerts" high`.
