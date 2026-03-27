# homelab-media-stack

> **Full-stack media automation on Proxmox LXC + Docker.**  
> Pipeline: Jellyseerr → Radarr/Sonarr/Lidarr → Prowlarr → qBittorrent (Gluetun VPN) → Jellyfin.  
> TRaSH Guides compliant — single `/data` mount, hardlink-based import (zero storage duplication).

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![TRaSH Guides](https://img.shields.io/badge/TRaSH-Guides_compliant-brightgreen)](https://trash-guides.info)

---

## Architecture

### Single-mount hardlink design

```
CT302 (docker-host) /mnt/mediastore/
├── config/               ← per-app config dirs
└── data/                 ← SINGLE mount for all containers
    ├── torrents/
    │   ├── movies/       ← qBittorrent category: radarr
    │   ├── tv/           ← qBittorrent category: sonarr
    │   ├── music/        ← qBittorrent category: lidarr
    │   └── incomplete/
    ├── movies/           ← Radarr library  (hardlinked from torrents/movies/)
    ├── tv/               ← Sonarr library  (hardlinked from torrents/tv/)
    └── music/            ← Lidarr library  (hardlinked from torrents/music/)
```

Hardlinks require source and target on the **same filesystem**. With one `/data` mount all containers share the same filesystem — import is instant and uses zero extra space. Separate mounts force file copies → 2× storage.

### Container stack

| Container | Port | Role |
|---|---|---|
| `gluetun` | — | VPN killswitch (PIA / Mullvad / ProtonVPN) |
| `qbittorrent` | 8080 | Torrent client (routes through gluetun network) |
| `prowlarr` | 9696 | Indexer manager |
| `radarr` | 7878 | Movie automation |
| `sonarr` | 8989 | TV automation |
| `lidarr` | 8686 | Music automation |
| `bazarr` | 6767 | Subtitle automation |
| `jellyfin` | 8096 | Media server (AMD VA-API hardware transcode) |
| `jellyseerr` | 5055 | Request UI |
| `homepage` | 3001 | Dashboard |
| `tdarr` | 8265 | Transcode automation (scheduled) |

---

## Prerequisites

- Proxmox VE 8.x, LXC with Docker (CT302 recommended)
- AMD iGPU on pve-03 host for Jellyfin VA-API transcoding (see [docs/vaapi.md](docs/vaapi.md))
- ZFS pool or NFS for `/mnt/mediastore` storage
- VPN credentials (PIA / Mullvad etc.) for Gluetun

---

## Quick Start

```bash
# 1. Clone repo into docker-host LXC (CT302)
git clone https://github.com/YOUR_USER/homelab-media-stack.git /root/mediaserver
cd /root/mediaserver

# 2. Configure environment
cp .env.example .env
nano .env    # set DATA_PATH, VPN credentials, PUID/PGID, TZ

# 3. Create directory structure
bash scripts/create-dirs.sh

# 4. Start stack
docker compose --env-file .env up -d

# 5. Copy Homepage config
cp configs/homepage/*.yaml "${DATA_PATH}/config/homepage/"
docker restart homepage
```

---

## Repository Structure

```
homelab-media-stack/
├── README.md
├── .env.example              ← all secrets/paths as variables
├── docker-compose.yml        ← full stack definition
├── docs/
│   ├── qbittorrent.md        — category setup, VPN port forwarding
│   ├── radarr-sonarr.md      — root folders, hardlinks, download client
│   ├── lidarr.md             — Prowlarr category mapping for music
│   ├── vaapi.md              — AMD iGPU passthrough into LXC
│   ├── tdarr.md              — Tdarr schedule (avoid backup window)
│   └── wizarr.md             — External invite URL via Cloudflare Tunnel
├── scripts/
│   ├── create-dirs.sh        — Creates full /data/ directory tree
│   └── update-stack.sh       — git pull + docker compose up -d
└── configs/
    └── homepage/             — Dashboard yaml configs
        ├── services.yaml
        ├── widgets.yaml
        └── settings.yaml
```

---

## Critical Configuration Notes

### qBittorrent categories — use ABSOLUTE paths

```
Category: radarr  →  Save path: /data/torrents/movies   ← MUST be absolute
Category: sonarr  →  Save path: /data/torrents/tv
Category: lidarr  →  Save path: /data/torrents/music
```

If relative paths are used, qBittorrent prepends the default save path → `data/torrents/data/torrents/movies` duplication.

### Lidarr + Prowlarr music indexer categories

Prowlarr must expose `Audio` (3000), `Audio/MP3` (3010), `Audio/Lossless` (3040) categories — not only `Audio/Other`. Lidarr ignores `Audio/Other`.

### Gluetun healthcheck

Do not use `condition: service_healthy` for qbittorrent dependency — Gluetun API occasionally times out the healthcheck even when VPN tunnel is active. Use `condition: service_started`.

### Tdarr scheduling

Configure Tdarr to run **06:00–02:00** only — avoids overlap with PBS nightly backup window (02:30).

---

## VA-API Hardware Transcoding (AMD Ryzen iGPU)

Add `/dev/dri/renderD128` to the LXC config and to Jellyfin's Docker device list:

```bash
# On Proxmox host (pve-03):
echo "lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file" \
  >> /etc/pve/lxc/302.conf
```

Expected result: Jellyfin CPU usage ~0% during transcode (iGPU handles encode/decode).

Supported codecs on Renoir/Cezanne iGPU: H264 ✓, HEVC ✓, VP9 decode ✓, AV1 ✗.

---

*Tested on: Proxmox VE 8.3, AMD Ryzen Renoir iGPU, Docker 27.x*
