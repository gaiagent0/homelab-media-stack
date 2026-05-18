# homelab-media-stack

> **Full-stack media automation on Proxmox LXC + Docker.**  
> Pipeline: Jellyseerr → Radarr/Sonarr/Lidarr → Prowlarr → qBittorrent (Gluetun VPN) → Jellyfin.  
> TRaSH Guides compliant — single `/data` mount, hardlink-based import (zero storage duplication).  
> **TVheadend IPTV stack** — DVB-C tuner → TVheadend → LG webOS app + Jellyfin Live TV (EPG, DVR, live TV).

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![TRaSH Guides](https://img.shields.io/badge/TRaSH-Guides_compliant-brightgreen)](https://trash-guides.info)

---

## Architecture

### Single-mount hardlink design

```
CT302 (docker-host) /mnt/mediastore/
├── config/               ← per-app config dirs
├── data/                 ← SINGLE mount for all containers
│   ├── torrents/
│   │   ├── movies/       ← qBittorrent category: radarr
│   │   ├── tv/           ← qBittorrent category: sonarr
│   │   ├── music/        ← qBittorrent category: lidarr
│   │   └── incomplete/
│   ├── movies/           ← Radarr library  (hardlinked from torrents/movies/)
│   ├── tv/               ← Sonarr library  (hardlinked from torrents/tv/)
│   └── music/            ← Lidarr library  (hardlinked from torrents/music/)
└── recordings/           ← TVheadend DVR felvételek
    ├── movies/           ← Jellyfin: Filmek könyvtár
    ├── tvshows/          ← Jellyfin: Sorozatok könyvtár
    ├── kozelet/          ← Jellyfin: Közélet könyvtár
    ├── sport/            ← Jellyfin: Sport könyvtár
    └── egyeb/            ← Jellyfin: Egyéb könyvtár
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
| `tvheadend` | 9981/9982 | IPTV server + DVR + EPG (DVB-C tuner) ✅ ACTIVE |

---

## TVheadend IPTV Stack ✅ LIVE

### Architecture

```
One kábel (koax)
    ↓
Koax splitter (1→2)
    ├── LG TV (gyári tuner, CAM kártya)
    └── Hauppauge WinTV-soloHD (USB, pve-03-ba dugva) ✅ ACTIVE
            ↓
       TVheadend (Docker, CT302) — 10.10.40.32:9981
            ↓
       WiFi/LAN
            ↓
       LG webOS TVheadend app (HTSP port 9982) ✅
       Jellyfin Live TV (TVheadend plugin) ✅
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
      - /mnt/mediastore/recordings:/recordings
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

**HTTP Authentication:** Configuration → General → Base → Authentication type → **"Both plain and digest"**

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

### OTA EPG letiltása (fontos!)

Az EIT (Over-the-air) EPG grabber lassítja a rendszert DVB-C tunernél. Ki kell kapcsolni:

```bash
docker stop tvheadend
sed -i '/"eit":/,/"priority": 1/{s/"enabled": true/"enabled": false/}' \
  /opt/tvheadend/config/epggrab/config
docker start tvheadend
```

### DVB-C hálózat beállítása (One)

```
1. Configuration → DVB Inputs → Networks → Add → DVB-C Network
2. Hálózat neve: One DVB-C
3. Előre meghatározott muxok: Hungary → One
4. Scan → Map all services → Map services
5. Tuner: Silicon Labs Si2168 (Hauppauge WinTV-soloHD)
```

### DVR felvételek

```bash
# Recordings jogosultság beállítása
chown -R 1000:1000 /mnt/mediastore/recordings/
chmod -R 775 /mnt/mediastore/recordings/
```

TVheadend DVR profilok:
| Profil | Storage path | Csatornák |
|---|---|---|
| `Tvshows` | `/recordings/tvshows` | RTL, TV2, RTL Három, RTL Kettő |
| `Sport` | `/recordings/sport` | Sport1, M4 Sport |
| `Kozelet` | `/recordings/kozelet` | ATV, Hír TV |
| `Movies` | `/recordings/movies` | Film csatornák |
| `Egyeb` | `/recordings/egyeb` | Egyéb |

### Jellyfin Live TV integráció

1. Jellyfin → Dashboard → Plugins → Catalog → **TVHeadend** → telepítés → restart
2. Plugin beállítások:
   - TVHeadend IP: `10.10.40.32`
   - Port: `9981`
   - Username: `admin`
   - Password: `admin`
3. Dashboard → Live TV → TV Guide Data Providers → **XMLTV**
   - URL: `http://admin:admin@10.10.40.32:9981/xmltv/channels`

### Jellyfin recordings könyvtárak

```bash
# Jellyfin docker-compose.yml volumes szekciójába:
- ${RECORDINGS}:/recordings

# .env fájlba:
RECORDINGS=/mnt/mediastore/recordings
```

### Működő One DVB-C csatornák ✅

| Csatorna | Státusz |
|---|---|
| M1 | ✅ |
| M2 / Petőfi TV | ✅ |
| DUNA | ✅ |
| M4 Sport | ✅ |
| M5 | ✅ |
| RTL | ✅ |
| TV2 | ✅ |
| RTL Kettő | ✅ |
| Sorozat+ | ✅ |
| Super TV2 | ✅ |
| Moziverzum | ✅ |
| RTL Gold | ✅ |
| TV4 | ✅ |
| Hangulat TV | ✅ |

### Következő lépések

- [x] TVheadend Docker telepítés
- [x] Felhasználók beállítása
- [x] Magyar IPTV playlist (ingyenes streamek)
- [x] EPG beállítása (epgshare01.online HU1)
- [x] LG webOS app csatlakoztatása
- [x] Proxmox LXC DVB passthrough előkészítése
- [x] Hauppauge WinTV-soloHD firmware telepítése
- [x] Hauppauge WinTV-soloHD USB tuner bedugva és aktív
- [x] One DVB-C szkennelés és csatornák betöltve
- [x] DVR felvételek beállítva (/mnt/mediastore/recordings)
- [x] Jellyfin TVHeadend plugin telepítve
- [x] Jellyfin recordings könyvtárak hozzáadva
- [ ] Jellyfin Live TV EPG channel mapping véglegesítése
- [ ] USB CI modul + CAM kártya (titkosított One csatornákhoz)
- [ ] DVR profilok hozzárendelése csatornákhoz

---

## Prerequisites

- Proxmox VE 8.x, LXC with Docker (CT302)
- AMD iGPU on pve-03 host for Jellyfin VA-API transcoding
- ZFS pool or NFS for `/mnt/mediastore` storage
- VPN credentials (PIA / Mullvad etc.) for Gluetun
- Hauppauge WinTV-soloHD USB DVB-C tuner ✅

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

### TVheadend — OTA EPG lassítja a rendszert

DVB-C tunernél az EIT grabber folyamatosan szkenneli az összes muxot. Kapcsold ki SSH-ból (lásd fent).

### TVheadend — Recording Permission Denied

```bash
chown -R 1000:1000 /mnt/mediastore/recordings/
chmod -R 775 /mnt/mediastore/recordings/
```

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

*Tested on: Proxmox VE 7.0/8.3, AMD Ryzen Renoir iGPU, Docker 27.x, TVheadend 4.3-2660, Hauppauge WinTV-soloHD*
