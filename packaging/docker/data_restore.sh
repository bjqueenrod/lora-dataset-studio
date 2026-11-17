#!/bin/bash
# Restores LDS_DATA_DIR (/data) from the network-volume snapshot that
# data_backup.sh maintains, on a container that is starting with no /data of
# its own yet.
#
# /data lives on the container's own ephemeral overlay disk. A pod RESTART
# keeps that disk, so this script is a no-op then (studio.db already exists).
# But terminating the pod, or deploying a fresh pod from the saved RunPod
# template, creates a brand-new container with an EMPTY /data — the template
# only bakes in the image, not any prior Bank database or Settings. Without
# this, that fresh container would silently seed a blank database and default
# config, even though a full backup is sitting right there on the network
# volume the new pod reattaches.
#
# Installed as /userscripts_dir/49-data-restore.sh — numbered just BEFORE
# 50-lora-dataset-studio.sh, so this has already run by the time the studio's
# own launch script checks for an existing database.
#
# Must ALWAYS exit 0, must never `set -e` — same contract as the other
# userscripts here: a non-zero return aborts the whole container boot, and a
# missed restore must never cost the user ComfyUI or the studio itself (it
# just means they start from a blank Bank, same as before this script
# existed).
set -u

SRC=${LDS_BACKUP_DIR:-/comfy/mnt/lds-data-backup}
DEST=${LDS_DATA_DIR:-/data}

log() { echo "[data-restore] $*"; }

# Never overwrite a database that's already there — that's a restart of THIS
# pod, with its own live data, which is always at least as fresh as the
# periodic backup.
if [ -f "$DEST/studio.db" ]; then
  log "$DEST/studio.db already exists — this is not a fresh container, skipping restore"
  exit 0
fi

if [ ! -f "$SRC/studio.db" ]; then
  log "no backup found at $SRC — nothing to restore, the studio will seed a fresh database"
  exit 0
fi

mkdir -p "$DEST" 2>/dev/null || true

log "restoring $SRC -> $DEST (fresh container, prior backup found)"

cp -f "$SRC/studio.db" "$DEST/studio.db" 2>/dev/null \
  && log "restored studio.db" \
  || log "failed to restore studio.db"

for f in config.json secret_key setup_state.json usage-statistics.json; do
  [ -f "$SRC/$f" ] && cp -f "$SRC/$f" "$DEST/$f" 2>/dev/null
done

if [ -d "$SRC/banks" ]; then
  rsync -a "$SRC/banks/" "$DEST/banks/" 2>/dev/null \
    || cp -r "$SRC/banks/." "$DEST/banks/" 2>/dev/null
fi

log "restore complete"
exit 0
