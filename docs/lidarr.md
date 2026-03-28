# Lidarr – Setup Guide

## The Prowlarr Category Problem

This is the most common Lidarr failure mode. Lidarr recognizes these Prowlarr categories:

| Category ID | Name |
|---|---|
| 3000 | Audio |
| 3010 | Audio/MP3 |
| 3040 | Audio/Lossless |
| 3050 | Audio/Other |

**Lidarr ignores `Audio/Other` (3050) alone.** Many Hungarian trackers (e.g. Majomparádé) return results tagged only as `Audio/Other`. Fix this in Prowlarr, not in Lidarr.

### Fix: Prowlarr indexer category mapping

**Prowlarr → Indexers → [your indexer] → Edit → Categories:**

Add all of these alongside whatever the indexer uses:
- ✅ `Audio` (3000)
- ✅ `Audio/MP3` (3010)
- ✅ `Audio/Lossless` (3040)
- ✅ `Music` (if available)

Without this, Lidarr's search returns zero results even when the indexer has the content.

---

## Root Folder & Download Client

**Settings → Root Folders:** `/data/music`

**Settings → Download Clients → Add → qBittorrent:**

| Setting | Value |
|---|---|
| Host | `gluetun` |
| Port | `8080` |
| Category | `lidarr` |

---

## Metadata Profile

**Settings → Metadata Profiles:**

Default "Standard" profile works for most use cases. For classical music or compilations, create a separate profile with relaxed matching rules.

---

## Import Settings

Same hardlink principle as Radarr/Sonarr — Lidarr maps to `/data/music`, qBittorrent saves to `/data/torrents/music`. Both must be on the same filesystem.

**Settings → Media Management:**
- ✅ Rename Tracks
- ✅ Use Hardlinks instead of Copy
- Standard track format: `{Artist Name}/{Album Title}/{track:00} - {Track Title}`

---

## Prowlarr Integration

**Prowlarr → Settings → Apps → Add Lidarr:**
- App Server: `http://lidarr:8686`
- API Key: from Lidarr → Settings → General
- Sync Level: `Full Sync`

---

## Troubleshooting

**No search results** → Prowlarr indexer missing Audio category mapping (see top of this doc).

**Found but not imported** → Check `/data/torrents/music` category path is absolute in qBittorrent.

**Wrong album matched** → Use "Manual Import" in Lidarr to force-match a release to the correct album.
