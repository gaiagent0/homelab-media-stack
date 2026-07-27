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
       Jellyfin Media Player (Windows desktop) ✅
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

### VA-API Mesa driver telepítése (pve-03 host) ⚠️ KRITIKUS

**MPEG2 és H264 hardveres dekódoláshoz szükséges — nélküle a Jellyfin Live TV kockás!**

```bash
apt-get install -y vainfo mesa-va-drivers
vainfo  # ellenőrzés: VAProfileMPEG2 és VAProfileH264 kell lásson
```

### Felhasználók beállítása

A TVheadend webes felületen (**Configuration → Users**):

| User | Szerepkör | Web UI | Admin | Streaming |
|---|---|---|---|---|
| `admin` | Adminisztrátor | ✅ | ✅ | Advanced, Basic, HTSP |
| `webos` | LG TV app | ❌ | ❌ | Basic, HTSP |

**HTTP Authentication:** Configuration → General → Base → Authentication type → **"Both plain and digest"**

### EPG beállítása

A linuxserver.io TVheadend image beépített `tv_grab_file` grabbere a `/config/data/*.xml` mintára illeszkedő
**összes** fájlt egyetlen `cat`-tel fűzi össze és úgy adja át a parsernek. Emiatt a `data` mappában
**kizárólag egyetlen `.xml` fájl lehet** (`guide.xml`) — lásd a lenti "EPG csendben nem importál semmit" szakaszt.

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

# Napi automatikus frissítés (cron.d — külön fájl, nem echo >> egy meglévőbe!)
echo "0 4 * * * root /opt/tvheadend/epg_update.sh" > /etc/cron.d/tvheadend
chmod 644 /etc/cron.d/tvheadend
```

TVheadend-ben: **Configuration → Channel/EPG → EPG Grabber Modules** → engedélyezd: **Internal XMLTV: XML file grabber**

Beállítás után az EPG-t manuálisan is be lehet tölteni azonnal a webUI-n a **"Re-run Internal EPG Grabbers"**
gombbal (Configuration → Channel/EPG → EPG Grabber Modules), vagy API-n keresztül:

```bash
curl -s -X POST "http://10.10.40.32:9981/api/epggrab/internal/rerun" -d "rerun=1"
```

### ⚠️ EPG csendben nem importál semmit (channels OK, broadcasts=0)

**Tünet:** a log azt mutatja, hogy a grab lefutott és a csatornákat felismerte, de a műsoridő-adatokat nem:

```
xmltv: /usr/bin/tv_grab_file: grab took 0 seconds
xmltv: /usr/bin/tv_grab_file: parse took 0 seconds
xmltv: /usr/bin/tv_grab_file:  channels   tot=  193 new=    0 mod=    3
xmltv: /usr/bin/tv_grab_file:  broadcasts tot=    0 new=    0 mod=    0   ← hiba!
```

**Ok:** a `tv_grab_file` script tartalma (linuxserver.io image):

```bash
if (( $# < 1 )); then
  cat /config/data/*.xml
  exit 0
fi
```

Ha **egynél több** `.xml` fájl van a `/config/data/` mappában (pl. egy régi, kézzel odamásolt fájl a napi
`guide.xml` mellett), a `cat` mindet összefűzi. Két `<?xml ...?>` deklaráció és két `<tv>` gyökérelem kerül
egymás mellé egy "dokumentumba" — ez érvénytelen XML. A TVheadend XML parsere ilyenkor csendben csak az első
`<tv>...</tv>` blokkot (jellemzően a `<channel>` lista, ami elöl van a fájlban) dolgozza fel, a később következő
`<programme>` elemeket eldobja, hibaüzenet vagy warning nélkül.

**Megoldás:**

```bash
# 1. Ellenőrizd, hány XML van a data mappában — pontosan 1-nek kell lennie
ls -la /opt/tvheadend/config/data/

# 2. Töröld a fölösleges/régi fájl(oka)t, csak a guide.xml maradjon
rm -f /opt/tvheadend/config/data/epg_hu.xml   # vagy bármi más régi fájl

# 3. Ellenőrzés: összefűzve is pontosan 1 <?xml> és 1 <tv> gyökérelem legyen
docker exec tvheadend sh -c "cat /config/data/*.xml | grep -c '<?xml'"   # → 1
docker exec tvheadend sh -c "cat /config/data/*.xml | grep -c '<tv '"    # → 1

# 4. Re-run Internal EPG Grabbers (webUI gomb, vagy API)
curl -s -X POST "http://10.10.40.32:9981/api/epggrab/internal/rerun" -d "rerun=1"
```

Ha a fenti után is `broadcasts=0` marad, az EPG adatbázis lehet korrupt egy korábbi hibás import miatt —
teljes reset szükséges:

```bash
docker stop tvheadend
rm -f /opt/tvheadend/config/epgdb.v3
find /opt/tvheadend/config/epggrab/xmltv/channels/ -type f -delete
docker start tvheadend
# várj ~20mp, majd Re-run Internal EPG Grabbers kétszer egymás után
# (1. futás: csak csatornafelismerés, 2. futás: tényleges programadat)
```

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

**Árva DVR bejegyzések (fájl törölve, adatbázis-rekord megmaradt):** induláskor
`dvr: unable to stat file '...' : No such file or directory` hibát okoznak a logban. Azonosítás és törlés:

```bash
# Listázd a DVR entryket, keresd meg amelyiknek nincs meg a fájlja a /mnt/mediastore/recordings alatt
curl -s "http://10.10.40.32:9981/api/dvr/entry/grid?limit=999" | python3 -m json.tool

# A hibás uuid-k törlése
curl -s -X POST "http://10.10.40.32:9981/api/dvr/entry/remove" -d "uuid=<UUID>"
```

### Jellyfin Live TV integráció ✅

1. Jellyfin → Dashboard → Plugins → Catalog → **TVHeadend** → telepítés → restart
2. Plugin beállítások:
   - TVHeadend IP: `10.10.40.32`
   - Port: `9981`
   - Username: `admin`
   - Password: `admin`
3. Dashboard → Live TV → TV műsorújság-szolgáltatók → **XMLTV**
   - URL: `https://epgshare01.online/epgshare01/epg_ripper_HU1.xml.gz`
   - ⚠️ NE használd a TVheadend XMLTV URL-t (`/xmltv/channels`) — az UUID alapú ID-kat exportál ami nem párosítható az EPG adatokkal!

### Jellyfin recordings könyvtárak

```bash
# Jellyfin docker-compose.yml volumes szekciójába:
- ${RECORDINGS}:/recordings

# .env fájlba:
RECORDINGS=/mnt/mediastore/recordings
```

### Jellyfin Media Player (Windows desktop)

Natív TS direct play támogatással — jobb Live TV élmény mint a böngésző:
```
https://github.com/jellyfin/jellyfin-media-player/releases/latest
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
- [x] VA-API Mesa driver telepítve (MPEG2/H264 hardveres dekódolás)
- [x] Jellyfin Live TV EPG beállítva (epgshare01.online)
- [x] Jellyfin Media Player Windows desktop telepítve
- [x] EPG cron aktiválva (`/etc/cron.d/tvheadend`, napi 04:00)
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

### TVheadend — EPG csendben nem importál semmit (channels OK, broadcasts=0)

Lásd fent, "EPG beállítása" szakasz — leggyakoribb ok: **több `.xml` fájl a `/config/data/` mappában**,
amit a `tv_grab_file` egyetlen érvénytelen dokumentummá fűz össze. Csak 1 fájl (`guide.xml`) lehet ott.

### TVheadend — Recording Permission Denied

```bash
chown -R 1000:1000 /mnt/mediastore/recordings/
chmod -R 775 /mnt/mediastore/recordings/
```

### TVheadend — Tuner foglalt (No free adapter)

Ha más eszköz foglalja a tunert, ellenőrizd:
```bash
curl -s "http://admin:admin@10.10.40.32:9981/api/status/subscriptions" | python3 -m json.tool
docker restart jellyfin  # ha a Jellyfin tartja nyitva a streamet
```

### Jellyfin Live TV — kockás kép (MPEG2 transcode)

```bash
# pve-03 host-on:
apt-get install -y mesa-va-drivers
# Majd Jellyfin Dashboard → Lejátszás → Átkódolás → MPEG2 hardveres dekódolás ✅
```

### Jellyfin Live TV EPG — UUID alapú ID-k

Ne használd a `http://tvheadend:9981/xmltv/channels` URL-t — UUID alapú channel ID-kat exportál.
Használd helyette közvetlenül: `https://epgshare01.online/epgshare01/epg_ripper_HU1.xml.gz`

### Gluetun healthcheck

Ne használd a `condition: service_healthy` feltételt — `condition: service_started` a helyes.

---

## VA-API Hardware Transcoding (AMD Ryzen iGPU)

```bash
# pve-03 host:
apt-get install -y vainfo mesa-va-drivers

# LXC 302 config:
echo "lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file" \
  >> /etc/pve/lxc/302.conf
```

---

*Tested on: Proxmox VE 7.0/8.3, AMD Ryzen Renoir iGPU, Docker 27.x, TVheadend 4.3-2660, Hauppauge WinTV-soloHD*
