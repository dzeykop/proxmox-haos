#!/usr/bin/env bash
# =============================================================
#  Home Assistant OS VM - interactive installer for Proxmox VE
#  Run as root on the Proxmox host.
# =============================================================
set -euo pipefail

TITLE="Home Assistant OS - VM Installer"
TMPDIR_HAOS=""

cleanup() { [[ -n "$TMPDIR_HAOS" && -d "$TMPDIR_HAOS" ]] && rm -rf "$TMPDIR_HAOS"; }
trap cleanup EXIT

cancel() { whiptail --title "$TITLE" --msgbox "Cancelled. Nothing was changed." 8 50; exit 1; }
error()  { echo -e "\n\e[31m[ERROR]\e[0m $1"; exit 1; }
info()   { echo -e "\e[32m[OK]\e[0m $1"; }

# --- Pre-checks ----------------------------------------------
[[ $EUID -eq 0 ]] || error "Please run as root."
command -v qm >/dev/null || error "This is not a Proxmox host (qm not found)."
command -v whiptail >/dev/null || apt-get install -y whiptail >/dev/null

# --- Get latest HAOS version ---------------------------------
RELEASE_JSON=$(curl -fsSL https://api.github.com/repos/home-assistant/operating-system/releases/latest) \
  || error "Could not reach the GitHub API (internet?)."
HAOS_VER=$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' <<< "$RELEASE_JSON")
[[ -n "$HAOS_VER" ]] || error "HAOS version not found in the API response."

# --- Questions -----------------------------------------------
NEXTID=$(pvesh get /cluster/nextid)

VMID=$(whiptail --title "$TITLE" --inputbox "VM ID:" 8 50 "$NEXTID" 3>&1 1>&2 2>&3) || cancel
qm status "$VMID" &>/dev/null && error "VM ID $VMID already exists."

VMNAME=$(whiptail --title "$TITLE" --inputbox "VM name:" 8 50 "homeassistant" 3>&1 1>&2 2>&3) || cancel

CORES=$(whiptail --title "$TITLE" --menu "CPU cores:" 13 50 4 \
  "2" "Default (recommended)" "4" "Many add-ons" "1" "Minimal" "6" "Large" \
  3>&1 1>&2 2>&3) || cancel

RAM=$(whiptail --title "$TITLE" --menu "Memory (MB):" 13 50 4 \
  "4096" "4 GB (recommended)" "2048" "2 GB (minimum)" "8192" "8 GB" "16384" "16 GB" \
  3>&1 1>&2 2>&3) || cancel

DISK=$(whiptail --title "$TITLE" --menu "Disk size (GB):" 13 50 4 \
  "32" "32 GB (default)" "64" "64 GB (more history/backups)" "128" "128 GB" "48" "48 GB" \
  3>&1 1>&2 2>&3) || cancel

# Storage list read from Proxmox - only active storages, with free space
mapfile -t STORAGES < <(pvesm status -content images 2>/dev/null \
  | awk 'NR>1 && $3=="active" {print $1; printf "%s (%.0f GB free)\n", $2, $6/1024/1024}')
[[ ${#STORAGES[@]} -gt 0 ]] || error "No active storage for VM disks found."
STORAGE=$(whiptail --title "$TITLE" --menu "Storage:" 14 60 5 "${STORAGES[@]}" 3>&1 1>&2 2>&3) || cancel

# Network bridge
mapfile -t BRIDGES < <(ip -o link show type bridge | awk -F': ' '{print $2; print "Bridge"}')
BRIDGE=$(whiptail --title "$TITLE" --menu "Network bridge:" 13 50 4 "${BRIDGES[@]}" 3>&1 1>&2 2>&3) || cancel

START="no"
whiptail --title "$TITLE" --yesno "Start the VM right after installation?" 8 50 && START="yes"

# --- Summary -------------------------------------------------
whiptail --title "$TITLE" --yesno "Please review:

  HAOS version : $HAOS_VER
  VM ID        : $VMID
  Name         : $VMNAME
  CPU cores    : $CORES
  Memory       : $RAM MB
  Disk         : $DISK GB on $STORAGE
  Network      : $BRIDGE
  Auto start   : $START

Install now?" 20 55 || cancel

# --- Download ------------------------------------------------
TMPDIR_HAOS=$(mktemp -d)
IMG="$TMPDIR_HAOS/haos_ova-${HAOS_VER}.qcow2"
URL="https://github.com/home-assistant/operating-system/releases/download/${HAOS_VER}/haos_ova-${HAOS_VER}.qcow2.xz"

echo "Downloading HAOS $HAOS_VER ..."
curl -fL --progress-bar "$URL" -o "$IMG.xz" || error "Download failed."
info "Download complete"
echo "Extracting ..."
unxz "$IMG.xz"
info "Extracted"

# --- Create VM -----------------------------------------------
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
  --description "Home Assistant OS $HAOS_VER - created with haos-vm.sh from JFFK"
info "VM $VMID created"

# EFI disk (Secure Boot OFF - otherwise HAOS will not boot)
qm set "$VMID" --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=0" >/dev/null
info "EFI disk created"

# Import HAOS image as system disk
qm set "$VMID" --scsi0 "${STORAGE}:0,import-from=${IMG},discard=on,ssd=1" >/dev/null
qm resize "$VMID" scsi0 "${DISK}G" >/dev/null
qm set "$VMID" --boot order=scsi0 >/dev/null
info "System disk imported and resized to ${DISK} GB"

# --- Start ---------------------------------------------------
if [[ "$START" == "yes" ]]; then
  qm start "$VMID"
  info "VM started"
fi

echo
info "Done! Home Assistant will be reachable in about 5-10 minutes at:"
echo "     http://homeassistant.local:8123  (or http://<VM-IP>:8123)"
echo "     Find the IP in Proxmox under VM $VMID > Summary or in your router."
