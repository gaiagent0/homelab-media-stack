# qBittorrent – Setup Guide

## WebUI Initial Login

Default credentials on first run: `admin` / `adminadmin` (change immediately).

**Tools → Options → Web UI:**
- Enable CSRF protection: ✅
- Bypass authentication for clients on localhost: ✅ (optional, for *arr apps)

---

## Download Paths

**Tools → Options → Downloads:**

| Setting | Value |
|---|---|
| Default Save Path | `/data/torrents` |
| Keep incomplete torrents in | `/data/torrents/incomplete` |
| Default Torrent Management Mode | `Automatic` |

---

## Categories — MUST use absolute paths

Right-click the sidebar → **Add category**:

| Category | Save Path |
|---|---|
| `radarr` | `/data/torrents/movies` |
| `sonarr` | `/data/torrents/tv` |
| `lidarr` | `/data/torrents/music` |

> ⚠️ **Critical:** Save paths must be **absolute** (start with `/`).  
> If relative, qBittorrent appends the default save path:  
> `/data/torrents` + `torrents/movies` → `/data/torrents/torrents/movies` — broken hardlinks.

---

## Connection Settings

**Tools → Options → Connection:**

| Setting | Value |
|---|---|
| Listening Port | `40124` (PIA forwarded port — update when it changes) |
| Use UPnP / NAT-PMP | ❌ (VPN handles port forwarding) |

---

## VPN Port Forwarding (Gluetun + PIA)

Gluetun automatically forwards a port via PIA's API. Retrieve it:

```bash
docker exec gluetun cat /tmp/gluetun/forwarded_port
# 40124
```

Update this in qBittorrent if the port changes (PIA rotates it periodically).

Verify VPN IP (should NOT be your home IP):
```bash
docker exec gluetun wget -qO- https://ipinfo.io
```

---

## Speed Settings (optional tuning)

**Tools → Options → Speed:**
- Upload limit: set to ~80% of your upload capacity — seeding helps tracker ratio
- Download limit: unlimited

**Tools → Options → BitTorrent:**
- Enable DHT: ❌ (private trackers typically require this off)
- Enable PeX: ❌
- Enable Local Peer Discovery: ❌

---

## *arr Integration

qBittorrent is accessed by Radarr/Sonarr/Lidarr via the **Gluetun container hostname** — because qBittorrent runs inside Gluetun's network namespace:

| Setting | Value |
|---|---|
| Host | `gluetun` |
| Port | `8080` |
| Username | `admin` |
| Password | your WebUI password |

Do **not** use `qbittorrent` as the hostname — the container has no independent network interface.
