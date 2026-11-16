#!/bin/bash
# Starts Ollama inside the ComfyUI-Nvidia container so LDS's "Existing host
# Ollama" mode (Settings > Local tools) has something to find.
#
# Installed as /userscripts_dir/51-ollama.sh — same extension point as
# 50-lora-dataset-studio.sh, numbered after it on purpose: the studio's own
# seed/launch logic has no dependency on Ollama being up first, so ordering
# between the two doesn't matter, but the "50-" script already documents the
# convention and this just follows it.
#
# This script must ALWAYS exit 0 and must never `set -e`, for the same reason
# as 50-lora-dataset-studio.sh: upstream's init script treats a non-zero
# return as fatal to the whole container boot, and Ollama being optional must
# never cost the user ComfyUI or the studio.
set -u

log() { echo "[ollama] $*"; }

# LDS's "Existing host Ollama" mode is hardcoded to check
# http://host.docker.internal:11434 — written for the normal docker-compose
# deployment, where Ollama genuinely runs on a separate host/container.
# Here Ollama runs in this SAME container, so the alias just needs to resolve
# to ourselves. Docker regenerates /etc/hosts fresh on every container start,
# so this must happen here at runtime, not as a Dockerfile RUN step (that
# edit would be silently discarded on first boot).
if ! grep -q 'host.docker.internal' /etc/hosts 2>/dev/null; then
  echo '127.0.0.1 host.docker.internal' | sudo tee -a /etc/hosts > /dev/null \
    && log "aliased host.docker.internal -> 127.0.0.1" \
    || log "could not add host.docker.internal to /etc/hosts — LDS's reachability check will fail"
fi

# Model weights (several GB each) belong on the persistent network volume,
# not the container's own ephemeral disk — same reasoning as the SDXL
# checkpoint and Klein files under /comfy/mnt/ComfyUI/models. Falls back to
# Ollama's own default location when no network volume is mounted, e.g. a
# pod without /comfy/mnt attached, so this script still works standalone.
if [ -d /comfy/mnt ]; then
  export OLLAMA_MODELS=/comfy/mnt/ollama-models
  mkdir -p "${OLLAMA_MODELS}" 2>/dev/null || true
  chmod 777 "${OLLAMA_MODELS}" 2>/dev/null || true
fi

if ! command -v ollama >/dev/null 2>&1; then
  log "ollama binary not found — skipping (image was built without it?)"
  exit 0
fi

# Backgrounded supervisor loop, same pattern as the studio's own launch loop:
# nothing else restarts Ollama if it dies, and this must never block boot.
(
  while true; do
    ollama serve 2>&1 | sed -u 's/^/[ollama] /'
    log "ollama serve exited — restarting it in 5s"
    sleep 5
  done
) &

log "starting on 127.0.0.1:11434 (models in ${OLLAMA_MODELS:-the default ~/.ollama/models})"
exit 0
