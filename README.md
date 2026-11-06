# Ptero Installer

Install your own **Pterodactyl Panel** on a VPS with **one command**. No questions, no setup steps, no domain needed. Made for beginners who don't want to buy hosting from a third party.

## Install (one command)

Log in to your VPS as **root** and paste this:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/whitigerxgaming-design/ptero-installer/main/install.sh)"
```

Wait about 10 minutes. Don't close the window. When it finishes, you get:

- Your **panel link** (a free `trycloudflare.com` address with HTTPS)
- Your **username** (`admin`) and a **random password**

Everything is also saved in `/root/pterodactyl-credentials.txt`.

## What it does automatically

- Checks your VPS (OS, CPU, RAM, virtualization, network)
- Creates a free Cloudflare tunnel, so you need **no domain and no port forwarding**
- Installs the Panel (nginx, PHP, MariaDB, and the Pterodactyl Panel)
- Generates secure passwords
- If your VPS supports Docker, installs **Wings** and creates the location, node, and game ports in the Panel for you
- Saves a `ptero-manage` command for later

## Requirements

| Item | Needed |
|---|---|
| OS | Ubuntu 22.04 / 24.04 or Debian 11 / 12 |
| Access | Root |
| RAM | 2 GB minimum, 4 GB or more recommended |
| Virtualization | **KVM** if you want to run game servers |

> **Important:** On **LXC** and **OpenVZ** VPS plans, Docker does not work, so only the **Panel** is installed. To host game servers, use a **KVM** VPS. Check yours with `systemd-detect-virt`.

## Manage your panel later

Type this on the VPS:

```bash
ptero-manage
```

| Option | What it does |
|---|---|
| 1. Fix problems | Checks all services and restarts everything |
| 2. Get a new Panel link | Creates a new random tunnel link |
| 3. Show my login details | Shows your username, password, and current link |
| 4. Permanent link | Use your own Cloudflare domain so the link never changes |
| 5. Advanced install | Manual install with your own domain, sslip.io, or Wings only |

You can also run `ptero-url` any time to print your current panel link.

## Making your first game server

If Wings was installed (KVM VPS only):

1. Open your panel link and log in.
2. Go to **Admin → Servers → Create New**.
3. Pick the owner, the node (`node1`), a port, and an egg (for example Minecraft).
4. Click **Create Server**.

If the node was not created automatically, the installer shows you the exact settings to enter under **Admin → Nodes → Create New**.

## Good to know

- **The link can change.** Random tunnel links change after a restart. The panel updates itself, and `ptero-manage` shows the new link. For a link that never changes, use option 4 with a domain on Cloudflare.
- **Players cannot join through the panel link.** Game servers use `IP:port`, so the game ports (for example `25565-25600`) must be open at your VPS provider. If your provider blocks them, servers run but players can't connect.
- **Tunnels are for the website only**, not for game traffic.

## Troubleshooting

| Problem | Fix |
|---|---|
| Link shows **Error 1033** | The tunnel restarted. Run `ptero-manage` and choose **1**, then use the link it prints. |
| Link does not open | Run `ptero-manage` and choose **2** for a new link. |
| `Failed to fork` or `apt` errors | The VPS has a process limit. Check `ps aux \| wc -l` and ask your provider to raise it. |
| Docker or Wings won't start | Your VPS is probably LXC or OpenVZ. Use a KVM VPS for Wings. |
| Forgot your login | Run `ptero-manage` and choose **3**, or `cat /root/pterodactyl-credentials.txt`. |

Tunnel log: `tail -20 /var/log/ptero-tunnel-panel.log`

## Other ways to run it

```bash
ptero-manage --advanced   # manual install menu
ptero-manage --install    # force the automatic install
```

## Uninstall

Use the official uninstaller and choose the uninstall option:

```bash
bash <(curl -s https://pterodactyl-installer.se)
```

Then remove the tunnels and helper commands:

```bash
systemctl disable --now ptero-tunnel-panel ptero-tunnel-node ptero-url-sync
rm -f /usr/local/bin/ptero-manage /usr/local/bin/ptero-url /usr/local/bin/ptero-url-sync
```

## Credits

- [Pterodactyl](https://pterodactyl.io) for the panel and Wings
- [pterodactyl-installer](https://github.com/pterodactyl-installer/pterodactyl-installer) for the installation scripts this tool builds on
- [Cloudflare](https://www.cloudflare.com) for `cloudflared` tunnels

## Disclaimer

This is an unofficial community tool and is not affiliated with Pterodactyl or Cloudflare. Use it at your own risk, and always use a fresh VPS, because the installer configures nginx, PHP, MariaDB, and the firewall.
