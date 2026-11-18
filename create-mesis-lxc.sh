#!/usr/bin/env bash
# Crea un container LXC (Debian 13) su Proxmox VE con Docker e avvia il servizio
# mesis-menu-json prelevando l'immagine da ghcr.io.
# Da eseguire come root sull'host Proxmox (one-liner, parametri passati inline):
#   IP_CIDR=172.16.1.16/22 GATEWAY=172.16.0.1 \
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/virgafox/mesis-menu-json/master/create-mesis-lxc.sh)"
set -euo pipefail

### ---- Configurazione (modifica a piacere, o passa come variabili d'ambiente) ----
CTID="${CTID:-$(pvesh get /cluster/nextid)}"
CT_HOSTNAME="${CT_HOSTNAME:-mesis-menu}"
ROOTFS_STORAGE="${ROOTFS_STORAGE:-local-lvm}"   # storage del disco del container (es. local-lvm, local-zfs)
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"   # storage dei template (di solito "local")
DISK_GB="${DISK_GB:-6}"                         # Debian + Docker + immagine Playwright (stima, non misurato)
MEMORY_MB="${MEMORY_MB:-1024}"                  # è un tetto, non una riserva: l'host usa solo la RAM realmente occupata
SWAP_MB="${SWAP_MB:-256}"
CORES="${CORES:-1}"
BRIDGE="${BRIDGE:-vmbr0}"
IP_CIDR="${IP_CIDR:-dhcp}"                      # "dhcp" oppure un IP/CIDR statico (es. 172.16.1.16/22)
GATEWAY="${GATEWAY:-}"                          # richiesto solo con IP statico
DNS="${DNS:-}"                                  # opzionale, es. 192.168.1.1
VLAN_TAG="${VLAN_TAG:-}"                        # opzionale

# Immagine su ghcr (VERIFICA il nome esatto nella tab "Packages" del repo / nel workflow)
IMAGE="${IMAGE:-ghcr.io/virgafox/mesis-menu-json:latest}"
GHCR_USER="${GHCR_USER:-}"                      # solo se il package è privato
GHCR_TOKEN="${GHCR_TOKEN:-}"                    # PAT con scope read:packages

HOST_PORT="${HOST_PORT:-8000}"
MESIS_MUNICIPIO="${MESIS_MUNICIPIO:-4}"
MESIS_CICLO="${MESIS_CICLO:-4}"
CACHE_TTL_SECONDS="${CACHE_TTL_SECONDS:-21600}"
TIMEZONE="${TIMEZONE:-Europe/Rome}"
### ----------------------------------------------------------------------------

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "Esegui come root sull'host Proxmox."; exit 1; }
command -v pct >/dev/null || { echo "pct non trovato: questo script va eseguito su un host Proxmox VE."; exit 1; }
if pct status "$CTID" &>/dev/null; then echo "Il CTID $CTID esiste già."; exit 1; fi

ARCH="$(dpkg --print-architecture)"   # amd64 su un normale PC/server x86
log "Cerco il template Debian 13 ($ARCH)"
pveam update >/dev/null
TEMPLATE="$(pveam available --section system | awk '{print $2}' | grep -E "^debian-13-standard_.*_${ARCH}\.tar" | sort -V | tail -1)"
[[ -n "$TEMPLATE" ]] || { echo "Template debian-13-standard ($ARCH) non trovato in pveam."; exit 1; }
if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
  log "Scarico $TEMPLATE"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

NET="name=eth0,bridge=${BRIDGE},ip=${IP_CIDR}"
[[ "$IP_CIDR" != "dhcp" && -n "$GATEWAY" ]] && NET+=",gw=${GATEWAY}"
[[ -n "$VLAN_TAG" ]] && NET+=",tag=${VLAN_TAG}"

log "Creo il container LXC $CTID ($CT_HOSTNAME)"
PCT_ARGS=(
  "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"
  --hostname "$CT_HOSTNAME"
  --cores "$CORES" --memory "$MEMORY_MB" --swap "$SWAP_MB"
  --rootfs "${ROOTFS_STORAGE}:${DISK_GB}"
  --net0 "$NET"
  --arch "$ARCH"
  --unprivileged 1
  --features nesting=1,keyctl=1          # necessari per Docker in LXC non privilegiato
  --onboot 1
  --ostype debian
  --timezone "$TIMEZONE"
  --tags "docker;mesis"
)
[[ -n "$DNS" ]] && PCT_ARGS+=(--nameserver "$DNS")
pct create "${PCT_ARGS[@]}"

log "Avvio il container"
pct start "$CTID"

log "Attendo la rete"
for _ in $(seq 1 30); do
  pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break
  sleep 2
done
pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null || { echo "Il container non risolve i DNS: controlla bridge/IP/DNS."; exit 1; }

log "Installo Docker"
pct exec "$CTID" -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq docker.io ca-certificates curl >/dev/null && systemctl enable --now docker"

if [[ -n "$GHCR_USER" && -n "$GHCR_TOKEN" ]]; then
  log "Login a ghcr.io"
  pct exec "$CTID" -- bash -c "echo '$GHCR_TOKEN' | docker login ghcr.io -u '$GHCR_USER' --password-stdin"
fi

log "Scarico l'immagine $IMAGE (può richiedere qualche minuto)"
pct exec "$CTID" -- docker pull "$IMAGE"

log "Avvio il servizio"
pct exec "$CTID" -- docker run -d \
  --name mesis-menu-api \
  --restart unless-stopped \
  --init --ipc=host \
  -p "${HOST_PORT}:8000" \
  -e MESIS_MUNICIPIO="$MESIS_MUNICIPIO" \
  -e MESIS_CICLO="$MESIS_CICLO" \
  -e CACHE_TTL_SECONDS="$CACHE_TTL_SECONDS" \
  -e TZ="$TIMEZONE" \
  "$IMAGE"

log "Verifico l'healthcheck"
OK=0
for _ in $(seq 1 30); do
  if pct exec "$CTID" -- curl -fsS "http://localhost:${HOST_PORT}/health" >/dev/null 2>&1; then OK=1; break; fi
  sleep 2
done

CT_IP="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"
echo
if [[ $OK -eq 1 ]]; then
  echo "Fatto. API disponibile su:  http://${CT_IP}:${HOST_PORT}/menu/day?date=$(date +%F)"
  echo "Docs interattive:            http://${CT_IP}:${HOST_PORT}/docs"
else
  echo "Container creato (IP ${CT_IP}) ma l'healthcheck non risponde ancora."
  echo "Controlla i log con:  pct exec $CTID -- docker logs mesis-menu-api"
fi
echo
echo "Aggiornare l'immagine in futuro:"
echo "  pct exec $CTID -- bash -c 'docker pull $IMAGE && docker rm -f mesis-menu-api && docker run -d --name mesis-menu-api --restart unless-stopped --init --ipc=host -p ${HOST_PORT}:8000 -e MESIS_MUNICIPIO=$MESIS_MUNICIPIO -e MESIS_CICLO=$MESIS_CICLO -e CACHE_TTL_SECONDS=$CACHE_TTL_SECONDS -e TZ=$TIMEZONE $IMAGE'"