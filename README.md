# Ptero Installer

Install your own **Pterodactyl Panel** and **Wings** on a VPS in a few minutes, without buying hosting from a third party. Run one command, answer a few questions, and the installer does the rest.

It wraps the official [pterodactyl-installer](https://github.com/pterodactyl-installer/pterodactyl-installer) in unattended mode, so you never have to go through its prompts one by one.

## Features

- One menu: **Panel + Wings**, **Panel only**, **Wings only**, or **add a tunnel to an existing Panel**
- Asks everything up front: domain, admin email, username, password, timezone
- Three domain options:
  - **Your own domain** (Cloudflare or any provider)
  - **Cloudflare tunnel**: a random free `xxxx.trycloudflare.com` URL with HTTPS, no DNS and no port forwarding needed
  - **sslip.io**: a free automatic domain based on your IP
- Detects NAT / cloud networks and recommends the tunnel when ports can't be reached
- Free **Let's Encrypt** SSL on your own domain or sslip.io
- Auto-generates strong passwords
- Saves your login details to `/root/pterodactyl-credentials.txt`
- Opens the firewall ports for you

## Requirements

| Item | Needed |
|---|---|
| OS | Ubuntu 22.04 / 24.04 or Debian 11 / 12 |
| Access | Root |
| Virtualization | **KVM** (needed for Wings and Docker) |
| RAM | 2 GB minimum, 4 GB or more recommended |

> **Note:** Wings needs Docker, which does not work on most **LXC** or **OpenVZ** VPS plans. On those, install the Panel only and run Wings on a separate KVM VPS. Check yours with `systemd-detect-virt`.

## Install

```bash
apt update && apt install -y git
git clone https://github.com/whitigerxgaming-design/ptero-installer.git
cd ptero-installer
chmod +x install.sh
sudo ./install.sh
```

## Menu

| Option | What it does |
|---|---|
| 1 | Install Panel + Wings on this VPS |
| 2 | Install the Panel only |
| 3 | Install Wings only (a node) |
| 4 | Enable or refresh a Cloudflare tunnel for an existing Panel |

## Choosing a domain

| Option | Best for | Needs |
|---|---|---|
| **1. Own domain** | A permanent, professional setup | A domain, A records pointing to your VPS IP (Cloudflare proxy **off**, grey cloud), ports 80/443 open |
| **2. Cloudflare tunnel** | VPS behind NAT or a provider firewall, quick testing | Nothing. A random `trycloudflare.com` URL is created for you |
| **3. sslip.io** | A VPS with a real public IP | Ports 80/443 open to the internet |

If the installer prints a **NAT detected** warning, options 1 and 3 will probably fail. Use option 2.

## Cloudflare tunnel notes

- The tunnel URL **changes when the VPS or the tunnel restarts**. Run `sudo ./install.sh` and choose **4** to get the new Panel URL.
- Tunnels carry web traffic only. **Game ports (Minecraft etc.) cannot go through trycloudflare.** Players connect to `IP:port`, so those ports must be open at your provider (firewall or port forwarding).
- Quick tunnels are meant for testing. For a permanent URL, use your own domain.

## After installing: connect the node

If you installed Wings:

1. Log in to the panel, then go to **Admin → Locations** and create a location.
2. Go to **Admin → Nodes → Create New**:
   - **Own domain / sslip.io:** use your node domain as the FQDN, Daemon Port `8080`, SFTP Port `2022`.
   - **Cloudflare tunnel:** use the node tunnel URL as the FQDN, choose *Use SSL connection*, set *Behind Proxy* to **Yes**, and set Daemon Port to `443`.
3. Open the node's **Configuration** tab, copy the config, and paste it into `/etc/pterodactyl/config.yml`.
4. Start Wings:
   ```bash
   systemctl enable --now wings
   ```
5. The node should show a green heart.
6. On the node's **Allocation** tab, add your VPS IP and game ports (for example `25565-25600`).
7. Go to **Admin → Servers → Create New** and make your first server.

## Firewall

The installer opens ports on the VPS itself. If your provider has its own firewall (for example Azure, AWS, or Oracle), also allow:

- TCP: `80`, `443`, `8080`, `2022`
- TCP and UDP: your game port range

## Troubleshooting

| Problem | Fix |
|---|---|
| Page says "took too long to respond" | Ports are blocked or your VPS is behind NAT. Run the installer, choose **4**, and use the tunnel URL. |
| `Failed to fork` or `apt` errors | The VPS has a process limit. Check `ps aux \| wc -l` and ask your provider to raise it. |
| Docker will not start | Your VPS is probably LXC or OpenVZ. Use a KVM VPS for Wings. |
| SSL certificate fails | The domain must point to your VPS IP, ports 80 and 443 must be open, and the Cloudflare proxy must be off (grey cloud). |
| Tunnel URL not found | Check the log: `tail -20 /var/log/ptero-tunnel-panel.log` |
| Panel URL stopped working after a reboot | The tunnel URL changed. Run the installer and choose **4**. |
| Node shows a red heart | Check `systemctl status wings` and the node settings above. |

## Uninstall

Use the official uninstaller:

```bash
bash <(curl -s https://pterodactyl-installer.se)
```

Then choose the uninstall option. To remove the tunnels:

```bash
systemctl disable --now ptero-tunnel-panel ptero-tunnel-node
```

## Credits

- [Pterodactyl](https://pterodactyl.io) for the panel and Wings
- [pterodactyl-installer](https://github.com/pterodactyl-installer/pterodactyl-installer) for the installation scripts this tool builds on
- [Cloudflare](https://www.cloudflare.com) for `cloudflared` quick tunnels

## Disclaimer

This is an unofficial community tool and is not affiliated with Pterodactyl or Cloudflare. Use it at your own risk, and always use a fresh VPS, because the installer configures nginx, PHP, MariaDB, and the firewall.
