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
│   ├── music/            ← Lidarr library  (hardlinked from torrents/music/)
│   └── epg/              ← TVheadend guide.xml másolata, Jellyfin számára elérhető
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
| `epg-http` | 8181 | nginx:alpine — guide.xml statikus HTTP kiszolgálása Jellyfinnek ✅ ACTIVE |

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
       Jellyfin Live TV (TVheadend plugin, csatornák+stream) ✅
       Jellyfin Live TV (epg-http/guide.xml, műsorújság) ✅
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
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://127.0.0.1:9981/ping"]
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 30s
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
python3 /opt/tvheadend/hd_dedupe_epg.py
cp /opt/tvheadend/config/data/guide.xml /mnt/mediastore/data/epg/guide.xml
chmod 644 /mnt/mediastore/data/epg/guide.xml
EOF
chmod +x /opt/tvheadend/epg_update.sh
mkdir -p /mnt/mediastore/data/epg
/opt/tvheadend/epg_update.sh

# Napi automatikus frissítés (cron.d — külön fájl, nem echo >> egy meglévőbe!)
echo "0 4 * * * root /opt/tvheadend/epg_update.sh" > /etc/cron.d/tvheadend
chmod 644 /etc/cron.d/tvheadend
```

⚠️ **A `python3 .../hd_dedupe_epg.py` sor kritikus** — ha ez hiányzik a scriptből (pl. mert valaki felülírta
kézzel, vagy egy korábbi verzió maradt aktív), a napi 04:00-s cron a friss `guide.xml`-t a HD-dedupe/alias
nélküli, "csupasz" forrásra cseréli, és a HD-végződésű + alias csatornák EPG-je egyik napról a másikra eltűnik.
Mindig ellenőrizd `cat /opt/tvheadend/epg_update.sh`-val, hogy a hívás a helyén van-e egy frissítés után.

A **`cp .../guide.xml /mnt/mediastore/data/epg/guide.xml`** sor teszi elérhetővé a fájlt a Jellyfin konténer
számára is (lásd lentebb "Jellyfin Live TV integráció" — Jellyfin ugyanis nem éri el közvetlenül a
`/opt/tvheadend/config/data/`-t, mert az a CT302 hoszt saját fájlrendszerén van, nem a Jellyfin
docker-compose-jában mountolt egyik útvonalon sem).

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

**Két lehetséges ok:**

**1. Több `.xml` fájl a `/config/data/` mappában.** A `tv_grab_file` script tartalma (linuxserver.io image):

```bash
if (( $# < 1 )); then
  cat /config/data/*.xml
  exit 0
fi
```

Ha egynél több `.xml` fájl van ott (pl. egy régi, kézzel odamásolt fájl a napi `guide.xml` mellett), a `cat`
mindet összefűzi. Két `<?xml ...?>` deklaráció és két `<tv>` gyökérelem kerül egymás mellé egy "dokumentumba"
— ez érvénytelen XML. A TVheadend XML parsere ilyenkor csendben csak az első `<tv>...</tv>` blokkot (a
`<channel>` lista, ami elöl van) dolgozza fel, a később következő `<programme>` elemeket eldobja.

**2. Escapeletlen speciális karakter (pl. `&`) egy kézzel beszúrt csatornanévben** — lásd lentebb a
"Hiányos EPG" szakasz `xml_escape` megjegyzését. Ugyanezt a "csendes eldobás" mintát okozza.

**Megoldás:**

```bash
# 1. Ellenőrizd, hány XML van a data mappában — pontosan 1-nek kell lennie
ls -la /opt/tvheadend/config/data/

# 2. Töröld a fölösleges/régi fájl(oka)t, csak a guide.xml maradjon
rm -f /opt/tvheadend/config/data/epg_hu.xml   # vagy bármi más régi fájl

# 3. XML validitás ellenőrzés — ez elkapja mindkét okot (duplikátum ÉS escape-hiba)
python3 -c "
import xml.etree.ElementTree as ET
try:
    ET.parse('/opt/tvheadend/config/data/guide.xml')
    print('VALID XML')
except Exception as e:
    print('INVALID:', e)
"

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

### ⚠️ Hiányos EPG — " HD" végű és eltérő nevű csatornáknak nincs műsorújsága

**Tünet:** az EPG import sikeres (`broadcasts new > 0`), de csak a csatornák egy része kap tényleges
műsoradatot. A hiányzók két csoportba esnek:

1. **`" HD"` végű csatornanevek** (ATV HD, TV2 HD, RTL HD stb.) — a forrás a legtöbb csatornát HD jelző
   nélkül listázza (pl. `"ATV"`), a `tv_grab_file` fuzzy name-matchingje kis/nagybetűre és a pontos
   TVheadend-névre érzékeny, ezért nem párosul automatikusan a `" HD"` végű változattal.
2. **Erősen eltérő névformátumú csatornák** (DUNA HD, M2/Petőfi TV HD, M4 Sport HD, SAT1, VIASAT2/3,
   TV5 Monde, English Club HD, HISTORY HD, Kölyök Klub HD, Magyar Sláger TV, The Fishing & Hunting HD,
   Fashion TV stb.) — a forrásban `"Duna TV"`, `"m2 HD"`, `"m4"`, `"SAT 1"`, `"Viasat 2"`, `"TV5"`,
   `"English Club TV"`, `"The History HD"`, `"Kölyökklub"`, `"Sláger TV"`, `"Fishing and Hunting
   Channel"`, `"Fashionbox"` néven szerepelnek — túlságosan eltér a TVheadend-beli csatornanevedtől
   ahhoz, hogy a `" HD"` toldalékos dedupe (1. pont) megtalálja. Ezeknél **explicit alias** kell.

**Megoldás:** a letöltés után egy Python post-processzáló (a) minden nem-HD `<channel>` blokkot duplikál
`" HD"` toldalékkal, (b) egy explicit `ALIASES` szótár alapján további csatorna-klónokat hoz létre a
forrás channel ID-ről a te pontos TVheadend-csatornanevedre. Mindkettő a hozzá tartozó `<programme>`
elemeket is átmásolja az új ID-re. Az alias-nevek `xml_escape`-elve kerülnek be — **ez kritikus**: a
`"The Fishing & Hunting HD"` típusú nevekben a nyers `&` érvénytelen XML-t generálna, ami a teljes
`guide.xml` parse-t elrontja (lásd fent, "EPG csendben nem importál semmit" 2. ok):

```bash
cat > /opt/tvheadend/hd_dedupe_epg.py << 'PYEOF'
#!/usr/bin/env python3
"""guide.xml minden nem-HD csatornajahoz letrehoz egy ' HD' duplikatumot
(channel + programme elemek), hogy a tv_grab_file fuzzy matching-je
a helyi HD-elnevezesu csatornakra is illeszkedjen.
Emellett explicit alias-channeleket is letrehoz azokhoz a TVheadend
csatornanevekhez, amik nevformatuma tul elter a forrastol a fuzzy
matchinghez (pl. 'M2 / Petofi TV HD', 'DUNA HD', 'M4 Sport HD')."""
import re
from xml.sax.saxutils import escape as xml_escape

GUIDE = '/opt/tvheadend/config/data/guide.xml'

with open(GUIDE, 'r', encoding='utf-8') as f:
    content = f.read()

channel_blocks = re.findall(r'<channel id="[^"]+">.*?</channel>', content, re.DOTALL)

extra_channels = []
extra_programmes_map = {}

# --- 1. altalanos HD dedupe (mint korabban) ---
for block in channel_blocks:
    id_m = re.search(r'<channel id="([^"]+)">', block)
    name_m = re.search(r'<display-name[^>]*>([^<]+)</display-name>', block)
    if not id_m or not name_m:
        continue
    orig_id = id_m.group(1)
    orig_name = name_m.group(1)
    if 'HD' in orig_name.upper():
        continue
    new_id = orig_id + '.HD'
    new_name = orig_name + ' HD'
    new_block = block.replace(f'<channel id="{orig_id}">', f'<channel id="{new_id}">', 1)
    new_block = new_block.replace(f'>{orig_name}<', f'>{new_name}<', 1)
    extra_channels.append(new_block)
    extra_programmes_map[orig_id] = new_id

# --- 2. explicit alias-channelek: forras-id -> pontos TVheadend csatornanev ---
# Bővítsd ezt a szótárt, ha újabb erősen-eltérő-nevű csatornát találsz.
ALIASES = {
    'm1.HD.hu':                       'M1 HD',
    'm2.HD.hu':                       'M2 / Petőfi TV HD',
    'Duna.TV.hu':                     'DUNA HD',
    'm4.hu':                          'M4 Sport HD',
    'Duna.World.hu':                  'DUNA W/M4 Sport+ HD',
    'm5.hu':                          'M5 HD',
    'English.Club.TV.hu':             'English Club HD',
    'Fashionbox.hu':                  'Fashion TV',
    'The.History.HD.hu':              'HISTORY HD',
    'Kölyökklub.hu':                  'Kölyök Klub HD',
    'Sláger.TV.hu':                   'Magyar Sláger TV',
    'SAT.1.hu':                       'SAT1',
    'Fishing.and.Hunting.Channel.hu': 'The Fishing & Hunting HD',
    'TV5.hu':                         'TV5 Monde',
    'Viasat.2.hu':                    'VIASAT2',
    'Viasat.3.hu':                    'VIASAT3',
}

for src_id, alias_name in ALIASES.items():
    src_block_m = re.search(rf'<channel id="{re.escape(src_id)}">.*?</channel>', content, re.DOTALL)
    if not src_block_m:
        print(f"SKIP (forras channel nem talalhato): {src_id}")
        continue
    src_block = src_block_m.group(0)
    alias_id = src_id + '.alias'
    new_block = re.sub(r'<channel id="[^"]+">', f'<channel id="{alias_id}">', src_block, count=1)
    new_block = re.sub(r'<display-name[^>]*>[^<]+</display-name>',
                        f'<display-name>{xml_escape(alias_name)}</display-name>', new_block, count=1)
    extra_channels.append(new_block)
    extra_programmes_map[src_id] = alias_id

# --- programme duplikalas mindegyik mappelt (orig -> uj) parhoz ---
extra_programmes = []
for orig_id, new_id in extra_programmes_map.items():
    pattern = re.compile(
        r'<programme([^>]*)channel="' + re.escape(orig_id) + r'"([^>]*)>(.*?)</programme>',
        re.DOTALL
    )
    for m in pattern.finditer(content):
        new_prog = f'<programme{m.group(1)}channel="{new_id}"{m.group(2)}>{m.group(3)}</programme>'
        extra_programmes.append(new_prog)

insertion = ''.join(extra_channels) + ''.join(extra_programmes)
new_content = content.replace('</tv>', insertion + '</tv>')

with open(GUIDE, 'w', encoding='utf-8') as f:
    f.write(new_content)

print(f"Extra HD channel: {len(extra_channels)}, extra programme (HD+alias): {len(extra_programmes)}")
PYEOF

# Fűzd hozzá az epg_update.sh végéhez, hogy minden napi frissítés után lefusson
# (lásd fent az "EPG beállítása" szakaszban a teljes epg_update.sh-t):
echo "python3 /opt/tvheadend/hd_dedupe_epg.py" >> /opt/tvheadend/epg_update.sh
chown 1000:1000 /opt/tvheadend/config/data/guide.xml

# Ezután Re-run Internal EPG Grabbers KÉTSZER (1. csatorna-felismerés, 2. tartalom),
# szükség esetén teljes EPG reset is (lásd fenti szakasz)
```

**Új alias hozzáadása:** ha egy másik csatornánál is hasonló, tartósan hiányzó EPG-t találsz:

```bash
# forrás channel ID keresése egy friss, dedupe előtti letöltésen, kulcsszó szerint
pct exec 302 -- python3 -c "
import re
with open('/opt/tvheadend/config/data/guide.xml') as f:
    content = f.read()
targets = ['NÉVRÉSZLET1', 'NÉVRÉSZLET2']  # kisbetűs kulcsszavak
ids = re.findall(r'<channel id=\"([^\"]+)\">\s*<display-name[^>]*>([^<]+)</display-name>', content)
seen = set()
for cid, name in ids:
    if cid in seen: continue
    seen.add(cid)
    if any(t in name.lower() for t in targets):
        print(cid, '|', name)
"
```

majd vedd fel az `ALIASES` szótárba a `hd_dedupe_epg.py`-ban.

**Megjegyzés:** a helyi/kábeltévés csatornák egy része (pl. Kispest TV, Buda TV, Rákosmente TV, Szilas TV,
Williams TV, XV. TV, Régió Plusz TV, 16TV, 9.TV, Centrum TV, EKT, felnőtt csatornák) **nincs is benne** az
epgshare01 HU1 forrásban — ezekhez sem a HD-dedupe, sem az alias nem segít, mert nincs mit párosítani.
Ezekhez a TVheadend webUI-n kézzel is felvihető EPG-esemény (**DVR → Electronic Program Guide**, jobb klikk
egy üres sávra → **Add**), de ez nem frissül automatikusan — csak egyszeri, statikus bejegyzés.

### OTA EPG letiltása (fontos!)

Az EIT (Over-the-air) EPG grabber lassítja a rendszert DVB-C tunernél. Ki kell kapcsolni:

```bash
docker stop tvheadend
sed -i '/"eit":/,/"priority": 1/{s/"enabled": true/"enabled": false/}' \
  /opt/tvheadend/config/epggrab/config
docker start tvheadend
```

### ⚠️ Csatornák nem indulnak el ("No input detected") — Idle Scan

**Tünet:** a webUI elérhető, a csatornalista és az EPG is megvan, de bármelyik csatorna lejátszása
elakad/időtúllépést dob. A logban:

```
subscription: NNNN: service instance is bad, reason: No input detected
subscription: NNNN: No input source available for subscription "HTTP" to channel "..."
```

**Ok:** a DVB-C hálózat (**Configuration → DVB Inputs → Networks**) `idlescan` beállítása be van kapcsolva.
Ez azt jelenti, hogy amikor senki sem néz semmit, a TVheadend **folyamatosan, automatikusan újra-szkenneli**
az összes mux-ot a háttérben (a logban percenként visszatérő `tuning`/`scan complete` ciklusok formájában).
Egyetlen fizikai tunerrel ez azt okozza, hogy amikor ténylegesen elindítanál egy csatornát, a tuner épp
egy másik mux-on van elfoglalva a háttér-scan miatt, és a kérés időtúllépést kap.

**Megoldás:** kapcsold ki az Idle Scan-t minden hálózaton:

```bash
# Hálózat UUID-k lekérése
curl -s "http://10.10.40.32:9981/api/mpegts/network/grid?limit=10" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for n in d.get('entries',[]):
    print(n.get('networkname'), '|', n.get('uuid'))
"

# Kikapcsolás hálózatonként
curl -s -X POST "http://10.10.40.32:9981/api/idnode/save" \
  -d 'node={"uuid":"<NETWORK_UUID>","idlescan":false}'
```

Vagy webUI-n: **Configuration → DVB Inputs → Networks** → hálózat kiválasztása → **Idle Scan** pipa kikapcsolása.

### ⚠️ Csatornák nem indulnak el CT302/pve-03 restart után — beragadt USB DVB driver

**Tünet:** a webUI elérhető, a tuner frontend jó jelet mutat (`signal`/`snr` rendben az
`/api/status/inputs` API-ban), mégis **minden** csatorna egyformán, pontosan ~6 másodperc után
`"No input detected"` hibával elszáll — függetlenül attól, melyik mux-on van. Jellemzően több egymást
követő `pct stop`/`pct start` (CT302 restart) vagy USB re-enumerálódás (`FE_READ_STATUS error No such
device` a logban) után jelentkezik.

**Ok:** a kernel-szintű USB DVB driverek (`si2168`, `si2157`, `em28xx`) "megragadnak" egy hibás belső
állapotban a pve-03 hoszton — a `/dev/dvb/adapter0/` device node-ok újra létrejönnek, de a driver maga
nem áll helyre önmagától egy egyszerű docker/LXC restarttal.

**Megoldás:** explicit USB driver unbind/bind a pve-03 hoszton, utána teljes CT302 restart:

```bash
# pve-03 host-on:
# 1. TVheadend leállítása
pct exec 302 -- docker stop tvheadend

# 2. USB eszköz azonosítása (Hauppauge soloHD = 2040:8268)
lsusb | grep -i hauppauge
# pl. "Bus 004 Device 056: ID 2040:8268 Hauppauge soloHD"
# a bus/port útvonal (pl. 4-1) az lsusb -t vagy /sys/bus/usb/drivers/usb/ alatt látszik

# 3. driver unbind/bind (X-Y = a tényleges usb port útvonal, pl. 4-1)
echo "4-1" > /sys/bus/usb/drivers/usb/unbind
sleep 3
echo "4-1" > /sys/bus/usb/drivers/usb/bind
sleep 5

# 4. dvb node ellenőrzés a hoszton
ls -la /dev/dvb/adapter0/

# 5. CT302 teljes restart (a bind-mount frissen épül fel)
pct stop 302
sleep 5
pct start 302
sleep 25

# 6. TVheadend indítás
pct exec 302 -- bash -c "cd /opt/tvheadend && docker compose up -d"
```

Utána érdemes az **Idle Scan**-t is kikapcsolni (lásd fent), mert az szintén hozzájárulhat ehhez a
jelenséghez tartós szkennelési terheléssel.

### ⚠️ Csak a csatornák töredéke ("élő") jelenik meg — nincs "Map services" végrehajtva minden mux-on

**Tünet:** a `Configuration → DVB Inputs → Multiplexes` alatt sok mux-nál a **Services** oszlopban van
szám (pl. 8-17), de a **Channels** oszlop 0 — vagyis a mux-on talált szolgáltatások **soha nem lettek
csatornává mappelve**. Ez a Live TV listában (Jellyfin/webOS) jóval kevesebb csatornaként jelenik meg,
mint amennyi ténylegesen fogható lenne (pl. csak ~28 a 100+ potenciálisból).

**Ok:** a kezdeti "Map services" (Configuration → DVB Inputs → Services → Map services) csak részlegesen
futott le — jellemzően azért, mert a mux-scan több lépésben, megszakításokkal (restartok, USB
re-enumerálódás) történt, és a webUI-s "Map all services" nem lett újra lefuttatva minden mux felfedezése
után.

**Diagnózis — hiányzó mappelés keresése:**

```bash
# Mux-onkénti szolgáltatás- vs csatornaszám összevetés — svc>0 de chn=0 = hiányzó mappelés
curl -s "http://10.10.40.32:9981/api/mpegts/mux/grid?limit=999" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for m in d['entries']:
    if m.get('num_svc',0) > 0 and m.get('num_chn',0) == 0:
        print(m['name'], '| svc:', m['num_svc'])
"
```

**Megoldás:** a webUI-s "Map all services" (Configuration → DVB Inputs → Services → jelöld ki az érintett
szolgáltatásokat → Map services) a legmegbízhatóbb — a dokumentált `service/mapper/save` API hivatalosan
**"Untested"**, ezért API-ból inkább a `channel/create` végpontot érdemes használni, ami stabil és
dokumentált:

```bash
python3 << 'PYEOF'
import urllib.request, urllib.parse, json

BASE = "http://10.10.40.32:9981"

# Gyűjtsd ki a nem titkosított, csatorna nélküli szolgáltatásokat:
req = urllib.request.urlopen(f"{BASE}/api/mpegts/service/grid?limit=999", timeout=10)
services = json.loads(req.read())['entries']
todo = [(s['uuid'], s['svcname']) for s in services if not s.get('encrypted') and not s.get('channel')]

ok = 0
for svc_uuid, name in todo:
    conf = {"enabled": True, "name": name, "services": [svc_uuid], "epgauto": True}
    data = urllib.parse.urlencode({"conf": json.dumps(conf)}).encode()
    req = urllib.request.Request(f"{BASE}/api/channel/create", data=data, method="POST")
    try:
        urllib.request.urlopen(req, timeout=8)
        ok += 1
    except Exception as e:
        print(f"FAIL: {name} - {e}")

print(f"Kész: {ok}/{len(todo)} csatorna létrehozva")
PYEOF

# Utána EPG re-run, hogy az új csatornák is kapjanak műsorújságot:
curl -s -X POST "http://10.10.40.32:9981/api/epggrab/internal/rerun" -d "rerun=1"
```

**Fontos — nem minden mux egyformán jó jelű:** a mappelés után néhány mux-on a tuner nem tud stabilan
lock-ot tartani (a `/api/status/inputs` API `signal`/`snr` mezője `0` marad, streamelés `"No input
detected"` hibával elszáll, míg más mux-oknál -37..-50 dBm közti jó jel és 26-32 dB SNR mérhető). Ez
**valós, mux-specifikus jelprobléma**, nem szoftverhiba — a csatorna-bejegyzés ettől függetlenül
létrehozható, csak amíg a jel nem stabilizálódik (esetleg kábelezés/splitter ellenőrzésével), addig
"No input detected"-et fog dobni. Teszteld mux-onként:

```bash
# Adott csatorna signal/snr tesztje (indíts egy háttér-streamet, majd nézd a state-et)
(timeout 6 curl -s --max-time 5 "http://10.10.40.32:9981/stream/channel/<CHANNEL_UUID>" -o /dev/null &)
sleep 3
curl -s "http://10.10.40.32:9981/api/status/inputs" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for e in d.get('entries',[]): print('signal:', e.get('signal'), '| snr:', e.get('snr'))
"
```

### Jellyfin Live TV — a plugin passzív, nem próbál csatlakozni induláskor

A telepített `jellyfin-plugin-tvheadend` egy `ILiveTvService`-alapú plugin — **nem** a `livetv.xml`
`TunerHosts` mezőjén keresztül működik (azt üresen kell hagyni, ne szerkeszd kézzel!). A plugin csak
akkor kapcsolódik a TVheadend szerverhez, amikor ténylegesen megnyitod a Live TV oldalt a Jellyfin
kliensben — induláskor a logban nem várható semmilyen TVheadend/HTSP kapcsolódási kísérlet, ez normális.

### DVB-C hálózat beállítása (One)

```
1. Configuration → DVB Inputs → Networks → Add → DVB-C Network
2. Hálózat neve: One DVB-C
3. Előre meghatározott muxok: Hungary → One
4. Scan → Map all services → Map services
5. Tuner: Silicon Labs Si2168 (Hauppauge WinTV-soloHD)
6. Idle Scan: KIKAPCSOLVA (lásd fenti "Csatornák nem indulnak el" szakasz)
7. Minden mux felfedezése/módosulása után FUTTASD ÚJRA a "Map all services"-t —
   lásd fenti "Csak a csatornák töredéke élő" szakasz
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
   - **Fájl vagy webcím:** `http://10.10.40.32:8181/guide.xml` (ajánlott — lásd "Saját guide.xml
     kiszolgálása Jellyfinnek" szakasz), vagy alternatívaként fájlként `/data/epg/guide.xml`
   - ⚠️ **NE** a raw `https://epgshare01.online/epgshare01/epg_ripper_HU1.xml.gz` URL-t használd — abban
     nincs benne a HD-dedupe/alias (DUNA HD, M2 HD, SAT1 stb. hiányozna a Jellyfin-oldali EPG-ből is),
     ugyanaz a probléma jelentkezne, mint a TVheadend-nél a fejezet elején.
   - ⚠️ **NE** a TVheadend saját XMLTV URL-jét (`/xmltv/channels`) használd — UUID alapú channel ID-kat
     exportál, ami nem párosítható a plugin channel-adataival.
   - **Film/Gyermek/Hírek/Sport kategóriák:** opcionális, `|`-vel elválasztott kulcsszavak, pl. Gyermek:
     `Gyermek|Rajzfilm|Mese`, Hírek: `Hírek|Hírműsor`, Sport: `Sport` — hagyd üresen, ha nem fontos a
     kategorizálás.
   - **Felhasználó ügynök:** üresen hagyható.
   - **"Engedélyezze az összes tuner eszközre":** bekapcsolható, ha csak egy TVheadend-forrás van (ez itt
     a normál eset).

### Saját guide.xml kiszolgálása Jellyfinnek

A Jellyfin (LiveTV plugin) és a TVheadend `guide.xml`-je **különböző docker konténerek különböző
volume-jain** vannak, ezért a Jellyfin nem éri el közvetlenül a TVheadend fájlját. Két megoldás — mindkettő
egyszerre is használható, redundanciaként:

**A) Fájl elérési út** — a `guide.xml` bemásolása a Jellyfin `/data`-jába (ez már mountolva van):

```bash
mkdir -p /mnt/mediastore/data/epg
cp /opt/tvheadend/config/data/guide.xml /mnt/mediastore/data/epg/guide.xml
chmod 644 /mnt/mediastore/data/epg/guide.xml
# Jellyfin konténeren belül ez /data/epg/guide.xml lesz
```

Ezt a lépést az `epg_update.sh` már tartalmazza (lásd fent "EPG beállítása"), tehát napi 04:00-kor
automatikusan frissül.

**B) HTTP kiszolgálás** — egy könnyű nginx konténer, ami a `guide.xml`-t közvetlenül a TVheadend
konfigmappájából szolgálja ki (nincs másolás, mindig azonnal friss):

```bash
docker run -d \
  --name epg-http \
  --restart unless-stopped \
  -p 8181:80 \
  -v /opt/tvheadend/config/data:/usr/share/nginx/html:ro \
  nginx:alpine

# ellenőrzés
curl -s -o /dev/null -w "http_code=%{http_code}\n" http://10.10.40.32:8181/guide.xml
```

Elérhető: `http://10.10.40.32:8181/guide.xml`

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
| M1 HD | ✅ (EPG alias-szal) |
| M2 / Petőfi TV HD | ✅ (EPG alias-szal) |
| DUNA HD | ✅ (EPG alias-szal) |
| M4 Sport HD | ✅ (EPG alias-szal) |
| DUNA W/M4 Sport+ HD | ✅ (EPG alias-szal) |
| M5 HD | ✅ (EPG alias-szal) |
| SAT1, VIASAT2, VIASAT3, TV5 Monde, English Club HD, HISTORY HD, Kölyök Klub HD, Magyar Sláger TV, The Fishing & Hunting HD, Fashion TV | ✅ (EPG alias-szal) |
| RTL | ✅ |
| TV2 | ✅ |
| RTL Kettő | ✅ |
| Sorozat+ | ✅ |
| Super TV2 | ✅ |
| Moziverzum | ✅ |
| RTL Gold | ✅ |
| TV4 | ✅ |
| Hangulat TV | ✅ |
| CNN, Discovery Channel, TLC, Disney Channel, Cartoon Network, Nickelodeon, Nat Geo HD, +40 további | ⚠️ csatorna létrehozva, néhány mux (362MHz, 370MHz) gyenge jelű — lásd "Csak a csatornák töredéke élő" |
| BKTV, Buda TV, Kispest TV, Rákosmente TV, Szilas TV, Williams TV, XV. TV, Régió Plusz TV, 16TV, 9.TV, Centrum TV, EKT és hasonló helyi csatornák | ⚠️ nincs EPG forrás (epgshare01-ben nem szerepelnek) — csak kézi EPG-bevitel lehetséges |

### ⚠️ Csatornák nem indulnak el ("No assigned adapters") — Docker devices vs volumes

**Tünet:** a webUI elérhető, a csatornalista és az EPG is megvan, de minden csatorna streamelése "No assigned adapters" hibával elszáll. A logban:

```
subscription: NNNN: No input source available for subscription "HTTP" to channel "..."
webui: Couldn't start streaming ..., No assigned adapters
```

**Ok:** a `/dev/dvb` Docker container-be való átengedése **`volumes:`** helyett **`devices:`** beállítással történt. A `volumes:` bind mount csak a fájlrendszert mountolja, de **nem adja át a cgroup device access jogosultságokat** — emiatt a TVheadend process (vagy bárki a containerben) `PermissionError: [Errno 1] Operation not permitted` hibával nem tudja megnyitni a DVB device node-okat.

Ellenőrzés:
```bash
# CT302-n — ha ez PermissionError-t ad, a devices hibás:
docker exec --user root tvheadend python3 -c "open('/dev/dvb/adapter0/frontend0')"
# Helyes kimenet: nem dob hibát
# Hibás kimenet: PermissionError: [Errno 1] Operation not permitted
```

**Megoldás:** a `/dev/dvb` mount-ot át kell tenni `volumes:`-ból `devices:`-be:

```yaml
# HIBÁS ❌
services:
  tvheadend:
    volumes:
      - /dev/dvb:/dev/dvb

# HELYES ✅
services:
  tvheadend:
    volumes:
      - /opt/tvheadend/config:/config
      - /mnt/mediastore/recordings:/recordings
    devices:
      - /dev/dvb:/dev/dvb
```

Utána:
```bash
cd /opt/tvheadend && docker compose down && docker compose up -d
```

⚠️ **Figyelj:** ha a fájl rendszert mountolsz (nem device-et), akkor `volumes:` a helyes. A `devices:` csak valódi character device node-okhoz kell!

### Homepage Dashboard Widget (CT302)

A TVheadend adapter/státusz a Homepage dashboardon egyéni `customapi` widget-tel jelenik meg.
A widget egy helyi Python HTTP szervert kérdez le, ami a TVheadend API adatait JSON-ben szolgáltatja.

**Telepítés (CT302-n):**

```bash
cat > /opt/tvheadend/tvheadend-status-server.py << 'PYEOF'
#!/usr/bin/env python3
"""Lightweight HTTP server for TVheadend status JSON for Homepage dashboard"""
import http.server, json, os, subprocess, socketserver

PORT = 8050

class TVHHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/status", "/"):
            try:
                r = subprocess.run(["curl", "-sf", "http://127.0.0.1:9981/ping"], capture_output=True, timeout=5)
                tvh_up = r.returncode == 0
            except:
                tvh_up = False
            adapter_count = 1 if os.path.exists("/dev/dvb/adapter0") else 0
            channel_count = 0
            try:
                r = subprocess.run(["curl", "-s", "--digest", "-u", "admin:admin",
                                    "http://127.0.0.1:9981/api/channel/list"], capture_output=True, timeout=5)
                if r.returncode == 0:
                    channel_count = len(json.loads(r.stdout).get("entries", []))
            except:
                pass
            status = {"healthy": tvh_up and adapter_count > 0,
                      "adapters": adapter_count, "channels": channel_count}
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(json.dumps(status).encode())
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, *a): pass

with socketserver.TCPServer(("0.0.0.0", PORT), TVHHandler) as h:
    h.serve_forever()
PYEOF
chmod +x /opt/tvheadend/tvheadend-status-server.py

# Systemd service
cat > /etc/systemd/system/tvheadend-status.service << 'EOF'
[Unit]
Description=TVheadend Status API for Homepage
After=docker.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/tvheadend/tvheadend-status-server.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now tvheadend-status.service

# Homepage services.yaml widget hozzáadás
# (A TVheadend bejegyzés alá a widget: blokkot kell beilleszteni)
```

Homepage `services.yaml` TVheadend widget konfiguráció:

```yaml
- TVheadend:
    icon: tvheadend.png
    href: http://10.10.40.32:9981
    description: Live TV, EPG, DVR
    widget:
      type: customapi
      url: http://10.10.40.32:8050/status
      method: GET
      mappings:
        - field: healthy
          label: Status
        - field: adapters
          label: Adapters
        - field: channels
          label: Channels
```

Teszt: `curl -s http://10.10.40.32:8050/status`

### Monitoring & Karbantartási scriptek

Az alábbi scriptek a `/opt/tvheadend/` mappában találhatók CT302-n:

| Script | Funkció | Cron |
|---|---|---|
| `monitor-tvheadend.sh` | Prometheus metrics exportálás (signal, snr, ber, channels, EPG) | `*/2 * * * *` |
| `dvb-watchdog.sh` | Automatikus DVB adapter egészségügyi ellenőrzés + recovery triggerelés | `*/5 * * * *` |
| `tvh-benchmark.sh` | Streaming benchmark (bitrate, packet loss, latency csatornánként) | Kézi / heti |
| `fix-epg.sh` | EPG healthcheck és autojavítás | Kézi |
| `recover-tvheadend.sh` | Teljes recovery (USB unbind/bind, restart, EPG) + Telegram értesítés | Kézi / watchdog trigger |
| `tvh-auto-record.sh` | Automatikus DVR felvétel felírás EPG alapján | Kézi / naponta |
| `tvh-cleanup.sh` | Felvételek takarítása (régi, szemét törlése) | `0 3 * * *` |
| `media-healthcheck.sh` | Egységes media stack healthcheck (Jellyfin, Radarr, Sonarr, TVHeadend) | Kézi |
| `media-integrity.sh` | Hiányzó/szakadt fájl ellenőrző (Radarr/Sonarr vs lemez) | Kézi |

**Prometheus metrics:**
```bash
# Prometheus textfile collector számára:
*/2 * * * * /opt/tvheadend/monitor-tvheadend.sh > /opt/tvheadend/tvh.prom 2>/dev/null

# Metrics:
# tvh_container_healthy — Docker healthcheck (1=healthy)
# tvh_adapter_active — DVB adapter létezik-e
# tvh_adapter_signal_strength_dbm — Jelerősség dBm-ben
# tvh_adapter_snr_db — Jel/zaj arány dB-ben
# tvh_adapter_ber — Bit hiba arány
# tvh_adapter_unc_errors — Javíthatatlan hibák
# tvh_channel_count — Csatornák száma
# tvh_epg_size_bytes — guide.xml méret
# tvh_subscription_count — Aktív streaming subscription-ök
```

**DVB Watchdog:**
```bash
# Automatikus ellenőrzés + recovery:
*/5 * * * * /opt/tvheadend/dvb-watchdog.sh >> /opt/tvheadend/watchdog.log 2>&1

# Csak ellenőrzés (dry run):
/opt/tvheadend/dvb-watchdog.sh --dry-run

# Státusz JSON:
/opt/tvheadend/dvb-watchdog.sh --status
```

**Streaming benchmark:**
```bash
# Összes csatorna tesztelése (3mp/csatorna):
/opt/tvheadend/tvh-benchmark.sh

# Első 10 csatorna, 5mp teszt:
/opt/tvheadend/tvh-benchmark.sh --channels 10 --duration 5

# JSON kimenet:
/opt/tvheadend/tvh-benchmark.sh --json

# Jelentés fájlba:
/opt/tvheadend/tvh-benchmark.sh --output /opt/tvheadend/benchmark-report.md
```

**Telegram webhook beállítása:**
```bash
# A recover-tvheadend.sh automatikusan küld Telegram értesítést
# a recovery eseményekről, ha a TELEGRAM_WEBHOOK környezeti változó be van állítva:

export TELEGRAM_WEBHOOK="https://api.telegram.org/bot<BOT_TOKEN>/sendMessage?chat_id=<CHAT_ID>"

# Vagy a crontab-ban:
TELEGRAM_WEBHOOK="https://api.telegram.org/botXXX/sendMessage?chat_id=YYY"
0 * * * * /opt/tvheadend/dvb-watchdog.sh >> /opt/tvheadend/watchdog.log 2>&1
```

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
- [x] Jellyfin Live TV EPG beállítva (saját guide.xml — fájl ÉS HTTP is)
- [x] Jellyfin Media Player Windows desktop telepítve
- [x] EPG cron aktiválva (`/etc/cron.d/tvheadend`, napi 04:00)
- [x] HD-csatornák EPG dedupe scriptje (`hd_dedupe_epg.py`)
- [x] Idle Scan kikapcsolva mindkét DVB-C hálózaton
- [x] Hiányzó "Map services" pótlása — 46 új csatorna (`channel/create` API)
- [x] DUNA HD / M2 HD / M4 Sport HD / M1 HD / M5 HD / DUNA World EPG alias
- [x] SAT1 / VIASAT2 / VIASAT3 / TV5 Monde / English Club HD / HISTORY HD / Kölyök Klub HD /
      Magyar Sláger TV / The Fishing & Hunting HD / Fashion TV EPG alias (16 alias összesen)
- [x] `xml_escape` a `hd_dedupe_epg.py`-ban — `&`-t tartalmazó csatornanevek nem törik el a guide.xml-t
- [x] epg-http (nginx:alpine, port 8181) — guide.xml HTTP kiszolgálás Jellyfinnek
- [x] guide.xml másolás /mnt/mediastore/data/epg/-be — fájl-alapú elérés Jellyfinnek
- [ ] USB CI modul + CAM kártya (titkosított One csatornákhoz)
- [ ] DVR profilok hozzárendelése csatornákhoz
- [ ] 362MHz és 370MHz mux gyenge jelének kivizsgálása (kábelezés/splitter?)
- [ ] Teljes One "Family" csomag csatornalista összevetése a TVheadend állapottal (PDF alapján)

---

## Prerequisites

- Proxmox VE 9.2 (2026-09), LXC with Docker (CT302 @ pve-03)
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

Lásd fent, "EPG csendben nem importál semmit" szakasz — két lehetséges ok: **több `.xml` fájl a
`/config/data/` mappában**, vagy **escapeletlen speciális karakter** (pl. `&`) egy alias-névben. Mindkettőt
egy `ET.parse()`-os XML-validitás-ellenőrzéssel lehet gyorsan kizárni.

### TVheadend — Hiányos EPG (HD/eltérő nevű csatornáknak nincs műsorújsága)

Lásd fent, "Hiányos EPG" szakasz — `hd_dedupe_epg.py` script duplikálja a nem-HD forrás-csatornákat
HD változatra, és egy `ALIASES` szótár alapján explicit alias-channeleket is létrehoz az erősen eltérő
nevű csatornákhoz (DUNA HD, M2 HD, SAT1, VIASAT2/3 stb. — 16 alias jelenleg). Ellenőrizd, hogy a hívás
benne van-e az `epg_update.sh`-ban, és hogy az alias-nevek `xml_escape`-elve kerülnek be.

### TVheadend — Csatornák nem indulnak el ("No input detected")

Három lehetséges ok, lásd fent részletesen:
1. **Idle Scan bekapcsolva** → kapcsold ki mindkét hálózaton (`idlescan: false`)
2. **Beragadt USB DVB driver** restart(ok) után → USB unbind/bind + CT302 restart
3. **Gyenge jelű mux** (signal/snr = 0 az adott mux-on) → fizikai kábelezés/splitter probléma, nem szoftverhiba

### TVheadend — Csak a csatornák töredéke jelenik meg élőként

Lásd fent, "Csak a csatornák töredéke élő" szakasz — a `Map services` nem futott le minden mux-on,
`svc>0` de `chn=0` a `mpegts/mux/grid` API-ban. Pótlás a `channel/create` API-val tömegesen.

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

### Jellyfin Live TV EPG — saját guide.xml, nem a raw forrás vagy a TVheadend export

Lásd fent, "Saját guide.xml kiszolgálása Jellyfinnek" szakasz. Se a raw epgshare01 URL-t, se a
TVheadend `/xmltv/channels` exportot ne használd — mindkettő elveszíti a HD-dedupe/alias eredményét.

### Jellyfin Live TV — plugin passzív, nem próbál csatlakozni induláskor

Lásd fent, "Jellyfin Live TV — a plugin passzív" szakasz. Ne szerkeszd kézzel a `livetv.xml`
`TunerHosts` mezőjét — a `jellyfin-plugin-tvheadend` nem azon keresztül működik.

### Gluetun healthcheck

Ne használd a `condition: service_healthy` feltételt — `condition: service_started` a helyes.

### qBittorrent WebUI nem elérhető (connection reset) Gluetun újraindítás után

Ha a VPN kapcsolat rendben felépül (log: `Initialization Sequence Completed`, helyes IP), de a WebUI portra (8080) érkező kapcsolatok `connection reset`-tel végződnek, hiányzik a killswitch firewall engedélye a portra. Add hozzá a Gluetun environment blokkjához:

```
- FIREWALL_VPN_INPUT_PORTS=8080
- FIREWALL_INPUT_PORTS=8080
```

`FIREWALL_VPN_INPUT_PORTS` a `tun0` interfészen, `FIREWALL_INPUT_PORTS` a docker bridge (`eth0`) interfészen engedi be a portot — mindkettő kell, mert a host port-publish forgalom az `eth0`-n érkezik.

Ha a Gluetun konténert `docker compose up -d gluetun`-nal recreate-eled, a `network_mode: service:gluetun`-t használó qBittorrent konténer hálózati namespace-e is megszakad — utána azt is újra kell indítani:

```
docker compose up -d qbittorrent
```

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

*Tested on: Proxmox VE 7.0/8.3/9.2, AMD Ryzen Renoir iGPU, Docker 27.x, TVheadend 4.3-2660, Hauppauge WinTV-soloHD*
