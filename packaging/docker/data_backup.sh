#!/bin/bash
# Periodically snapshots LDS_DATA_DIR (/data) onto the persistent network
# volume. /data lives on the container's own ephemeral overlay disk — a pod
# restart keeps it, but a terminate/recreate (host migration, a fresh pod from
# this template) wipes it, taking the Bank's entire database (every scan,
# score, caption, keep/reject decision) with it. Nothing else backs this up:
# the network volume only ever held the source photos and model weights
# until this script existed.
#
# Installed as /userscripts_dir/52-data-backup.sh — after 50-/51-, same
# reasoning: no ordering dependency on the studio or Ollama coming up first.
#
# Must ALWAYS exit 0, must never `set -e` — same contract as the other
# userscripts here: a non-zero return aborts the whole container boot, and a
# missed backup must never cost the user ComfyUI or the studio itself.
set -u

DEST=${LDS_BACKUP_DIR:-/comfy/mnt/lds-data-backup}
SRC=${LDS_DATA_DIR:-/data}
INTERVAL=${LDS_BACKUP_INTERVAL_SECONDS:-900}

log() { echo "[data-backup] $*"; }

if [ ! -d "$(dirname "$DEST")" ]; then
  log "$(dirname "$DEST") does not exist — no network volume mounted, skipping"
  exit 0
fi

mkdir -p "$DEST/banks" 2>/dev/null || true
chmod -R 777 "$DEST" 2>/dev/null || true

snapshot_once() {
  if [ -f "$SRC/studio.db" ] && command -v sqlite3 >/dev/null 2>&1; then
    # .backup takes a consistent snapshot (checkpointing the WAL) without
    # blocking the live app — safe to run against a DB that's being written.
    sqlite3 "$SRC/studio.db" ".backup '$DEST/studio.db.tmp'" 2>/dev/null \
      && mv -f "$DEST/studio.db.tmp" "$DEST/studio.db"
  fi
  for f in config.json secret_key setup_state.json usage-statistics.json; do
    [ -f "$SRC/$f" ] && cp -f "$SRC/$f" "$DEST/$f.tmp" 2>/dev/null \
      && mv -f "$DEST/$f.tmp" "$DEST/$f"
  done
  # Thumbnail cache: nice to have (saves a rescan's thumb regeneration after a
  # restore) but fully regenerable from the source photos, so best-effort only.
  if [ -d "$SRC/banks" ]; then
    rsync -a --delete "$SRC/banks/" "$DEST/banks/" 2>/dev/null \
      || cp -r "$SRC/banks/." "$DEST/banks/" 2>/dev/null
  fi
  # Real per-dataset/per-run data that would be expensive or impossible to
  # reproduce if lost: full-res reference/generated/imported images per
  # dataset, encoded training video, and durable trained LoRA weights from
  # cloud runs. Each is created lazily on first use, so on a fresh install
  # none of these exist yet and the loop below is a no-op — deliberately NOT
  # including cloud_runs/ (working/staging for a cloud run, explicitly safe
  # to delete once it ends) or the thumbnail-only video_banks/.
  for d in datasets checkpoints video_datasets bank_sources video_bank_sources run_images; do
    if [ -d "$SRC/$d" ]; then
      rsync -a --delete "$SRC/$d/" "$DEST/$d/" 2>/dev/null \
        || cp -r "$SRC/$d/." "$DEST/$d/" 2>/dev/null
    fi
  done
  chmod -R 777 "$DEST" 2>/dev/null || true
}

(
  while true; do
    snapshot_once
    sleep "$INTERVAL"
  done
) &

log "snapshotting $SRC -> $DEST every ${INTERVAL}s"
exit 0
