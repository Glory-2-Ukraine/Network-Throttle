# Network Bandwidth Throttle Manager

Automatically limits a server's network bandwidth during configured time windows using Linux Traffic Control (`tc`). Outside those windows, full bandwidth is restored. Starts on boot without intervention.

## Quick Start

```bash
git clone https://github.com/Glory-2-Ukraine/Network-Throttle.git
cd Network-Throttle
sudo nano /etc/throttle.ini    # configure first
sudo bash install.sh
```

## throttle.ini Format

```
<bandwidth MB/s>
<interface>
<HH:MM> <HH:MM>
<HH:MM> <HH:MM>
```

Example — limit to 50 MB/s on eth0, 8am–6pm and 10pm–6am:
```
50.0
eth0
08:00 18:00
22:00 06:00
```

Find your interface: `ip link show`

## Useful Commands

| Action | Command |
|--------|---------|
| Check status | `sudo systemctl status throttle` |
| Live logs | `sudo journalctl -t throttle -f` |
| Restart after config change | `sudo systemctl restart throttle` |
| Check tc rules | `sudo tc qdisc show dev eth0` |
| Remove tc rules manually | `sudo tc qdisc del dev eth0 root` |

## Files

| File | Location |
|------|----------|
| Config | `/etc/throttle.ini` |
| Script | `/usr/local/bin/throttle.sh` |
| Service | `/etc/systemd/system/throttle.service` |

## Documentation

Full documentation with troubleshooting in English and Ukrainian is included in this repository.

---
*Part of the [Glory-2-Ukraine](https://github.com/Glory-2-Ukraine) infrastructure toolkit.*
