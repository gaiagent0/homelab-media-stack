# Radarr & Sonarr – Setup Guide

## Core Principle: Hardlinks

Both apps must have `/data` mounted at the **same path** as qBittorrent. This is what makes hardlinks work — source (`/data/torrents/movies`) and target (`/data/movies`) are on the same filesystem. Import is instant, zero extra storage.

---

## Media Management Settings

**Settings → Media Management → enable:**

| Option | Value |
|---|---|
| Rename Movies / Episodes | ✅ |
| Replace Illegal Characters | ✅ |
| Use Hardlinks instead of Copy | ✅ |
| Import Using Script | ❌ |

If "Use Hardlinks" is greyed out or produces copies — your mounts are on different filesystems. Fix: ensure a single `/data` bind mount covers both torrents and media dirs.

---

## Root Folders

**Settings → Media Management → Root Folders:**

| App | Root Folder |
|---|---|
| Radarr | `/data/movies` |
| Sonarr | `/data/tv` |

---

## Download Client

**Settings → Download Clients → Add → qBittorrent:**

| Setting | Value |
|---|---|
| Host | `gluetun` |
| Port | `8080` |
| Username | `admin` |
| Password | your qBit WebUI password |
| Category | `radarr` (or `sonarr`) |
| Directory | *(leave empty — category handles it)* |

> Use `gluetun` as hostname — qBittorrent runs inside Gluetun's network namespace and has no separate hostname.

---

## Prowlarr Integration

**Settings → Indexers → (no manual indexers needed)**

Connect via Prowlarr sync instead:

In **Prowlarr → Settings → Apps → Add:**
- App: Radarr (or Sonarr)
- Prowlarr Server: `http://prowlarr:9696`
- App Server: `http://radarr:7878`
- API Key: from Radarr's Settings → General
- Sync Level: `Full Sync`

Prowlarr pushes all indexers automatically — no manual configuration in Radarr/Sonarr.

---

## Quality Profiles

Use **Profilarr** to sync TRaSH Guides quality profiles automatically (runs as a container, connects to Radarr/Sonarr API). Manual alternative: import from [trash-guides.info](https://trash-guides.info).

---

## Verify Hardlinks Are Working

After a successful import, check that source and library file share the same inode:

```bash
# Same inode number = hardlink (not a copy)
ls -lai /mnt/mediastore/data/torrents/movies/ | head -5
ls -lai /mnt/mediastore/data/movies/ | head -5
```

Both should show identical inode numbers for the same file.

---

## Troubleshooting

**Import fails with "already exists"** — check root folder path is exactly `/data/movies`, not `/data/media/movies`.

**Hardlinks not working, files are copied** — Radarr/Sonarr container doesn't see the same filesystem. Verify both `-v ${DATA_PATH}:/data` mounts point to the same host path.

**"No files found" after download** — qBittorrent category save path is relative. Fix in [docs/qbittorrent.md](qbittorrent.md).
