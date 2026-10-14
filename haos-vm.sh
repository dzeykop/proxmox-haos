#!/usr/bin/env bash
# =============================================================
#  Home Assistant OS VM – interaktiver Installer fuer Proxmox VE
#  Test-/Lernskript. Ausfuehren als root auf dem Proxmox-Host.
# =============================================================
set -euo pipefail

TITLE="Home Assistant OS – VM Installer"
TMPDIR_HAOS=""

cleanup() { [[ -n "$TMPDIR_HAOS" && -d "$TMPDIR_HAOS" ]] && rm -rf "$TMPDIR_HAOS"; }
trap cleanup EXIT

abbruch() { whiptail --title "$TITLE" --msgbox "Abgebrochen. Es wurde nichts veraendert." 8 50; exit 1; }
fehler()  { echo -e "\n\e[31m[FEHLER]\e[0m $1"; exit 1; }
info()    { echo -e "\e[32m[OK]\e[0m $1"; }

# --- Vorpruefungen -------------------------------------------
[[ $EUID -eq 0 ]] || fehler "Bitte als root ausfuehren."
command -v qm >/dev/null || fehler "Kein Proxmox-Host (qm nicht gefunden)."
command -v whiptail >/dev/null || apt-get install -y whiptail >/dev/null

# --- Aktuelle HAOS-Version holen -----------------------------
RELEASE_JSON=$(curl -fsSL https://api.github.com/repos/home-assistant/operating-system/releases/latest) \
  || fehler "Konnte GitHub-API nicht erreichen (Internet?)."
HAOS_VER=$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' <<< "$RELEASE_JSON")
[[ -n "$HAOS_VER" ]] || fehler "HAOS-Version nicht in der Antwort gefunden."

# --- Abfragen ------------------------------------------------
NEXTID=$(pvesh get /cluster/nextid)

VMID=$(whiptail --title "$TITLE" --inputbox "VM-ID:" 8 50 "$NEXTID" 3>&1 1>&2 2>&3) || abbruch
qm status "$VMID" &>/dev/null && fehler "VM-ID $VMID existiert bereits."

VMNAME=$(whiptail --title "$TITLE" --inputbox "VM-Name:" 8 50 "homeassistant" 3>&1 1>&2 2>&3) || abbruch

CORES=$(whiptail --title "$TITLE" --menu "CPU-Kerne:" 13 50 4 \
  "2" "Standard (empfohlen)" "4" "Viele Add-ons" "1" "Minimal" "6" "Gross" \
  3>&1 1>&2 2>&3) || abbruch

RAM=$(whiptail --title "$TITLE" --menu "Arbeitsspeicher (MB):" 13 50 4 \
  "4096" "4 GB (empfohlen)" "2048" "2 GB (Minimum)" "8192" "8 GB" "16384" "16 GB" \
  3>&1 1>&2 2>&3) || abbruch

DISK=$(whiptail --title "$TITLE" --menu "Festplattengroesse (GB):" 13 50 4 \
  "32" "32 GB (Standard)" "64" "64 GB (viel Historie/Backups)" "128" "128 GB" "48" "48 GB" \
  3>&1 1>&2 2>&3) || abbruch

# Storage-Auswahl automatisch aus Proxmox auslesen
mapfile -t STORAGES < <(pvesm status -content images | awk 'NR>1 {print $1; print $2}')
[[ ${#STORAGES[@]} -gt 0 ]] || fehler "Kein Storage fuer VM-Disks gefunden."
STORAGE=$(whiptail --title "$TITLE" --menu "Speicherort:" 14 50 5 "${STORAGES[@]}" 3>&1 1>&2 2>&3) || abbruch

# Netzwerk-Bridge auswaehlen
mapfile -t BRIDGES < <(ip -o link show type bridge | awk -F': ' '{print $2; print "Bridge"}')
BRIDGE=$(whiptail --title "$TITLE" --menu "Netzwerk-Bridge:" 13 50 4 "${BRIDGES[@]}" 3>&1 1>&2 2>&3) || abbruch

START="nein"
whiptail --title "$TITLE" --yesno "VM nach der Installation sofort starten?" 8 50 && START="ja"

# --- Zusammenfassung -----------------------------------------
whiptail --title "$TITLE" --yesno "Bitte pruefen:

  HAOS-Version : $HAOS_VER
  VM-ID        : $VMID
  Name         : $VMNAME
  CPU-Kerne    : $CORES
  RAM          : $RAM MB
  Disk         : $DISK GB auf $STORAGE
  Netzwerk     : $BRIDGE
  Autostart    : $START

Jetzt installieren?" 20 55 || abbruch

# --- Download ------------------------------------------------
TMPDIR_HAOS=$(mktemp -d)
IMG="$TMPDIR_HAOS/haos_ova-${HAOS_VER}.qcow2"
URL="https://github.com/home-assistant/operating-system/releases/download/${HAOS_VER}/haos_ova-${HAOS_VER}.qcow2.xz"

echo "Lade HAOS $HAOS_VER herunter ..."
curl -fL --progress-bar "$URL" -o "$IMG.xz" || fehler "Download fehlgeschlagen."
info "Download fertig"
echo "Entpacke ..."
unxz "$IMG.xz"
info "Entpackt"

# --- VM erstellen --------------------------------------------
qm create "$VMID" \
  --name "$VMNAME" \
  --machine q35 \
  --bios ovmf \
  --ostype l26 \
  --cores "$CORES" \
  --cpu host \
  --memory "$RAM" \
  --net0 "virtio,bridge=$BRIDGE" \
  --scsihw virtio-scsi-pci \
  --agent enabled=1 \
  --tablet 0 \
  --onboot 1 \
  --description "Home Assistant OS $HAOS_VER – erstellt mit haos-vm.sh from JFFK"
info "VM $VMID angelegt"

# EFI-Disk (Secure Boot AUS – sonst bootet HAOS nicht)
qm set "$VMID" --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=0" >/dev/null
info "EFI-Disk erstellt"

# HAOS-Image als Systemplatte importieren
qm set "$VMID" --scsi0 "${STORAGE}:0,import-from=${IMG},discard=on,ssd=1" >/dev/null
qm resize "$VMID" scsi0 "${DISK}G" >/dev/null
qm set "$VMID" --boot order=scsi0 >/dev/null
info "Systemplatte importiert und auf ${DISK} GB vergroessert"

# --- Start ---------------------------------------------------
if [[ "$START" == "ja" ]]; then
  qm start "$VMID"
  info "VM gestartet"
fi

echo
info "Fertig! Home Assistant ist in ca. 5–10 Min erreichbar unter:"
echo "     http://homeassistant.local:8123  (oder http://<IP-der-VM>:8123)"
echo "     IP findest du in Proxmox unter VM $VMID > Summary oder in deinem Router."
