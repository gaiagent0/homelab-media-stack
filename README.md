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

### ⚠️ Hiányos EPG — sok " HD" végű csatornának nincs műsorújsága

**Tünet:** az EPG import sikeres (`broadcasts new > 0`), de csak a csatornák egy része (pl. 29 a 101-ből)
kap tényleges műsoradatot. A hiányzók jellemzően a `" HD"` végződésű csatornanevek (ATV HD, TV2 HD, RTL HD,
M4 Sport HD, DUNA HD stb.) — miközben a nem-HD csatornáknál (ATV, RTL, TV2) minden rendben.

**Ok:** az epgshare01 HU1 forrás a legtöbb csatornát **HD jelző nélkül** listázza (pl. `"ATV"`, `"m2 HD"`,
`"Duna TV"`), a `tv_grab_file` fuzzy name-matchingje pedig kis/nagybetűre és a saját TVheadend-csatornaneved
pontos formájára (`"ATV HD"`, `"M2 / Petőfi TV HD"`, `"DUNA HD"`) érzékeny — a kettő nem mindig párosul
automatikusan.

**Megoldás:** a letöltés után egy Python post-processzáló minden nem-HD `<channel>` blokkot (és a hozzá
tartozó `<programme>` elemeket) duplikál egy `" HD"` toldalékos ID-vel és display-name-mel, hogy a fuzzy
matcher a helyi HD-elnevezésű csatornákra is ráilljen:

```bash
cat > /opt/tvheadend/hd_dedupe_epg.py << 'PYEOF'
#!/usr/bin/env python3
"""guide.xml minden nem-HD csatornajahoz letrehoz egy ' HD' duplikatumot
(channel + programme elemek), hogy a tv_grab_file fuzzy matching-je
a helyi HD-elnevezesu csatornakra is illeszkedjen."""
import re

GUIDE = '/opt/tvheadend/config/data/guide.xml'

with open(GUIDE, 'r', encoding='utf-8') as f:
    content = f.read()

channel_blocks = re.findall(r'<channel id="[^"]+">.*?</channel>', content, re.DOTALL)

extra_channels = []
extra_programmes_map = {}

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

print(f"Extra HD channel: {len(extra_channels)}, extra HD programme: {len(extra_programmes)}")
PYEOF

# Fűzd hozzá az epg_update.sh végéhez, hogy minden napi frissítés után lefusson:
echo "python3 /opt/tvheadend/hd_dedupe_epg.py" >> /opt/tvheadend/epg_update.sh
chown 1000:1000 /opt/tvheadend/config/data/guide.xml

# Ezután Re-run Internal EPG Grabbers KÉTSZER (1. csatorna-felismerés, 2. tartalom),
# szükség esetén teljes EPG reset is (lásd fenti szakasz)
```

**Megjegyzés:** néhány csatorlnál (pl. DUNA HD, M2/Petőfi TV HD, M4 Sport HD) a névformátum annyira eltér
(`"Duna TV"`, `"m2 HD"`, `"m4"`), hogy még a HD-dedupe után sem párosul automatikusan — ezekhez kézi
csatorna-ID alias szükséges a scriptben. A helyi/kábeltévés csatornák egy része (pl. Kispest TV, Buda TV,
felnőtt csatornák) pedig **nincs is benne** az epgshare01 HU1 forrásban — ezekhez nincs ingyenes magyar EPG.

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
| CNN, Discovery Channel, TLC, Disney Channel, Cartoon Network, Nickelodeon, Nat Geo HD, +40 további | ⚠️ csatorna létrehozva, néhány mux (362MHz, 370MHz) gyenge jelű — lásd "Csak a csatornák töredéke élő" |

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
- [x] HD-csatornák EPG dedupe scriptje (`hd_dedupe_epg.py`)
- [x] Idle Scan kikapcsolva mindkét DVB-C hálózaton
- [x] Hiányzó "Map services" pótlása — 46 új csatorna (`channel/create` API)
- [ ] USB CI modul + CAM kártya (titkosított One csatornákhoz)
- [ ] DVR profilok hozzárendelése csatornákhoz
- [ ] DUNA HD / M2 HD / M4 Sport HD EPG kézi channel-alias
- [ ] 362MHz és 370MHz mux gyenge jelének kivizsgálása (kábelezés/splitter?)

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

### TVheadend — Hiányos EPG (HD csatornáknak nincs műsorújsága)

Lásd fent, "Hiányos EPG" szakasz — `hd_dedupe_epg.py` script duplikálja a nem-HD forrás-csatornákat
HD változatra is, hogy a fuzzy name-matching megtalálja őket.

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

### Jellyfin Live TV EPG — UUID alapú ID-k

Ne használd a `http://tvheadend:9981/xmltv/channels` URL-t — UUID alapú channel ID-kat exportál.
Használd helyette közvetlenül: `https://epgshare01.online/epgshare01/epg_ripper_HU1.xml.gz`

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

*Tested on: Proxmox VE 7.0/8.3, AMD Ryzen Renoir iGPU, Docker 27.x, TVheadend 4.3-2660, Hauppauge WinTV-soloHD*
