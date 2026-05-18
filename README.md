# homelab-media-stack

> **Full-stack media automation on Proxmox LXC + Docker.**  
> Pipeline: Jellyseerr → Radarr/Sonarr/Lidarr → Prowlarr → qBittorrent (Gluetun VPN) → Jellyfin.  
> TRaSH Guides compliant — single `/data` mount, hardlink-based import (zero storage duplication).  
> **TVheadend IPTV stack** — DVB-C tuner → TVheadend → LG webOS app (EPG, DVR, live TV).

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
| `tvheadend` | 9981/9982 | IPTV server + DVR + EPG (DVB-C tuner) |

---

## TVheadend IPTV Stack

### Architecture

```
One kábel (koax)
    ↓
Koax splitter (1→2)
    ├── LG TV (gyári tuner, CAM kártya)
    └── Hauppauge WinTV-soloHD (USB, pve-03-ba dugva)
            ↓
       TVheadend (Docker, CT302) — 10.10.40.32:9981
            ↓
       WiFi/LAN
            ↓
       LG webOS TVheadend app (HTSP port 9982)
       + bármely eszköz (telefon, tablet, Kodi)
```

### Telepítés (CT302 docker-host)

```bash
mkdir -p /opt/tvheadend/{config,recordings}

cat > /opt/tvheadend/docker-compose.yml << 'EOF'
services:
  tvheadend:
    image: linuxserver/tvheadend:latest
    container_name: tvheadend
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Budapest
    volumes:
      - /opt/tvheadend/config:/config
      - /opt/tvheadend/recordings:/recordings
    devices:
      - /dev/dvb:/dev/dvb
    ports:
      - "9981:9981"
      - "9982:9982"
EOF

cd /opt/tvheadend
docker compose up -d
```

### Proxmox LXC DVB passthrough (pve-03 host)

```bash
# /etc/pve/lxc/302.conf -hoz hozzáadni:
lxc.cgroup2.devices.allow: c 212:* rwm
lxc.mount.entry: /dev/dvb dev/dvb none bind,optional,create=dir
```

### Firmware telepítése (pve-03 host)

```bash
apt-get install -y dvb-tools

wget -O /lib/firmware/dvb-demod-si2168-d60-01.fw \
  "https://github.com/LibreELEC/dvb-firmware/raw/master/firmware/dvb-demod-si2168-d60-01.fw"
wget -O /lib/firmware/dvb-tuner-si2157-a30-01.fw \
  "https://github.com/LibreELEC/dvb-firmware/raw/master/firmware/dvb-tuner-si2157-a30-01.fw"
```

### Felhasználók beállítása

A TVheadend webes felületen (**Configuration → Users**):

| User | Szerepkör | Web UI | Admin | Streaming |
|---|---|---|---|---|
| `admin` | Adminisztrátor | ✅ | ✅ | Advanced, Basic, HTSP |
| `webos` | LG TV app | ❌ | ❌ | Basic, HTSP |

**Fontos:** Az `Enabled` jelölőnégyzet legyen bepipálva minden bejegyzésnél!

### EPG beállítása

```bash
# EPG mappa és letöltő script
mkdir -p /opt/tvheadend/config/data

cat > /opt/tvheadend/epg_update.sh << 'EOF'
#!/bin/bash
curl -s -L "https://epgshare01.online/epgshare01/epg_ripper_HU1.xml.gz" \
  | gunzip > /opt/tvheadend/config/data/guide.xml
sed -i '/<!DOCTYPE/d' /opt/tvheadend/config/data/guide.xml
EOF
chmod +x /opt/tvheadend/epg_update.sh
/opt/tvheadend/epg_update.sh

# Napi automatikus frissítés
echo "0 4 * * * root /opt/tvheadend/epg_update.sh" >> /etc/cron.d/tvheadend
```

TVheadend-ben: **Configuration → Channel/EPG → EPG Grabber Modules** → engedélyezd: **Internal XMLTV: XML file grabber**

### Magyar IPTV playlist (DVB-C tuner nélkül)

```bash
docker exec tvheadend curl -L -s "https://iptv-org.github.io/iptv/index.m3u" | \
  awk '/\.hu@SD/{found=1} found{print; if(!/^#/) {found=0; next}}' | \
  sed 's/\.hu@SD/.hu/g' | \
  sed 's/tvg-id="RTLHarom\.hu"/tvg-id="RTL.HÁROM.hu"/g' | \
  sed 's/tvg-id="RTLKetto\.hu"/tvg-id="RTL.KETTŐ.hu"/g' | \
  sed 's/tvg-id="RTLGold\.hu"/tvg-id="RTL.GOLD.hu"/g' | \
  sed 's/tvg-id="DunaWorld\.hu"/tvg-id="Duna.World.hu"/g' | \
  sed 's/tvg-id="Duna\.hu"/tvg-id="Duna.TV.hu"/g' \
  > /opt/tvheadend/config/hungary.m3u
```

EPG forrás: `https://epgshare01.online/epgshare01/epg_ripper_HU1.xml.gz`

### Működő csatornák (IPTV módban)

| Csatorna | EPG ID | Státusz |
|---|---|---|
| RTL | RTL.hu | ✅ |
| TV2 | TV2.hu | ✅ |
| RTL Három | RTL.HÁROM.hu | ✅ |
| RTL Kettő | RTL.KETTŐ.hu | ✅ |
| Sport 1 | Sport1.hu | ✅ |
| ATV | ATV.hu | ✅ |
| M2 Petőfi | M2.hu | ✅ |

### DVB-C szkennelés (Hauppauge WinTV-soloHD után)

```
1. Dugd be a tunert a pve-03 USB portjába
2. Ellenőrzés: ls /dev/dvb/
3. LXC restart: pct restart 302
4. TVheadend: Configuration → DVB Inputs → TV adapters (meg kell jelennie)
5. Networks → Add → DVB-C Network
6. Előre meghatározott muxok: Hungary → One
7. Scan → Map all services → Map services
```

### Következő lépések

- [x] TVheadend Docker telepítés
- [x] Felhasználók beállítása
- [x] Magyar IPTV playlist (ingyenes streamek)
- [x] EPG beállítása (epgshare01.online HU1)
- [x] LG webOS app csatlakoztatása
- [x] Proxmox LXC DVB passthrough előkészítése
- [x] Hauppauge firmware telepítése
- [ ] Hauppauge WinTV-soloHD USB tuner bedugása
- [ ] DVB-C szkennelés One frekvenciákon
- [ ] USB CI modul + CAM kártya (titkosított One csatornákhoz)

---

## Prerequisites

- Proxmox VE 8.x, LXC with Docker (CT302)
- AMD iGPU on pve-03 host for Jellyfin VA-API transcoding
- ZFS pool or NFS for `/mnt/mediastore` storage
- VPN credentials (PIA / Mullvad etc.) for Gluetun
- (Opcionális) Hauppauge WinTV-soloHD USB DVB-C tuner

---

## Quick Start

```bash
git clone https://github.com/gaiagent0/homelab-media-stack.git /root/mediaserver
cd /root/mediaserver
cp .env.example .env
nano .env
bash scripts/create-dirs.sh
docker compose --env-file .env up -d
```

---

## Critical Configuration Notes

### TVheadend — EPG Grabber Modules fül nem látszik

Ha az **EPG Grabber Modules** fül hiányzik: **Configuration → General → Base** → pipáld be a **Persistent view level** jelölőnégyzetet → **Save** → oldal újratöltése.

### TVheadend — broadcasts = 0

Az EPG channel ID-knak egyezniük kell az M3U `tvg-id` értékeivel. A fenti playlist generáló script már tartalmazza a szükséges konverziókat.

### Gluetun healthcheck

Ne használd a `condition: service_healthy` feltételt — `condition: service_started` a helyes.

---

## VA-API Hardware Transcoding (AMD Ryzen iGPU)

```bash
echo "lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file" \
  >> /etc/pve/lxc/302.conf
```

---

*Tested on: Proxmox VE 7.0/8.3, AMD Ryzen Renoir iGPU, Docker 27.x, TVheadend 4.3-2657*
