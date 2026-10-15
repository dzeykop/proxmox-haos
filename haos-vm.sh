#!/usr/bin/env bash
# =============================================================
#  Home Assistant OS VM - interactive installer for Proxmox VE
#  Run as root on the Proxmox host.
#  Author: JFFK
#
#  Version: 1.2
#  Changelog:
#    1.2 - Default VM name changed to "HA-OS".
#    1.1 - "Custom..." option for CPU, RAM and disk with input
#          validation; warning when RAM is below 2048 MB.
#    1.0 - Hardware detection (CPU/RAM/disk) + warnings when the
#          selection exceeds available resources.
#          Earlier unnumbered milestones: English UI, USB
#          passthrough, active-storage filter, HAOS version fix.
#
#  Versioning scheme:
#    small fixes      -> raise the minor number (1.1, 1.2, ...)
#    big new features -> raise the major number (2.0, 3.0, ...)
# =============================================================
set -euo pipefail

VERSION="1.2"
TITLE="Home Assistant OS - VM Installer v$VERSION"
TMPDIR_HAOS=""

cleanup() { [[ -n "$TMPDIR_HAOS" && -d "$TMPDIR_HAOS" ]] && rm -rf "$TMPDIR_HAOS"; }
trap cleanup EXIT

cancel() { whiptail --title "$TITLE" --msgbox "Cancelled. Nothing was changed." 8 50; exit 1; }
error()  { echo -e "\n\e[31m[ERROR]\e[0m $1"; exit 1; }
info()   { echo -e "\e[32m[OK]\e[0m $1"; }

# Ask for a whole number until the input is valid.
# Usage: ask_number <VARIABLE> "<prompt>" <default> <minimum>
ask_number() {
  local val
  while true; do
    val=$(whiptail --title "$TITLE" --inputbox "$2" 10 60 "$3" 3>&1 1>&2 2>&3) || cancel
    if [[ "$val" =~ ^[1-9][0-9]*$ ]] && (( val >= $4 )); then
      printf -v "$1" '%s' "$val"
      return
    fi
    whiptail --title "$TITLE" --msgbox "Invalid input: '$val'\n\nPlease enter a whole number of at least $4." 10 60
  done
}

# --- Pre-checks ----------------------------------------------
[[ $EUID -eq 0 ]] || error "Please run as root."
command -v qm >/dev/null || error "This is not a Proxmox host (qm not found)."
command -v whiptail >/dev/null || apt-get install -y whiptail >/dev/null

# --- Read host resources -------------------------------------
HOST_CORES=$(nproc)
MEM_TOTAL_MB=$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)
MEM_AVAIL_MB=$(awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo)

# --- Get latest HAOS version ---------------------------------
RELEASE_JSON=$(curl -fsSL https://api.github.com/repos/home-assistant/operating-system/releases/latest) \
  || error "Could not reach the GitHub API (internet?)."
HAOS_VER=$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' <<< "$RELEASE_JSON")
[[ -n "$HAOS_VER" ]] || error "HAOS version not found in the API response."

# --- Questions -----------------------------------------------
NEXTID=$(pvesh get /cluster/nextid)

VMID=$(whiptail --title "$TITLE" --inputbox "VM ID:" 8 50 "$NEXTID" 3>&1 1>&2 2>&3) || cancel
qm status "$VMID" &>/dev/null && error "VM ID $VMID already exists."

VMNAME=$(whiptail --title "$TITLE" --inputbox "VM name:" 8 50 "HA-OS" 3>&1 1>&2 2>&3) || cancel

CORES=$(whiptail --title "$TITLE" --menu "CPU cores\nThis host has $HOST_CORES cores." 14 50 4 \
  "2" "Default (recommended)" "4" "Many add-ons" "1" "Minimal" "6" "Large" "C" "Custom..." \
  3>&1 1>&2 2>&3) || cancel
if [[ "$CORES" == "C" ]]; then
  ask_number CORES "Number of CPU cores (this host has $HOST_CORES):" 2 1
fi

RAM=$(whiptail --title "$TITLE" --menu "Memory (MB)\nInstalled: $MEM_TOTAL_MB MB, available: $MEM_AVAIL_MB MB" 15 60 5 \
  "4096" "4 GB (recommended)" "2048" "2 GB (minimum)" "8192" "8 GB" "16384" "16 GB" "C" "Custom..." \
  3>&1 1>&2 2>&3) || cancel
if [[ "$RAM" == "C" ]]; then
  ask_number RAM "Memory in MB (1 GB = 1024 MB)\nInstalled: $MEM_TOTAL_MB MB, available: $MEM_AVAIL_MB MB" 4096 512
fi

# Minimum 32 GB: the HAOS image is 32 GB and a disk cannot be shrunk
DISK=$(whiptail --title "$TITLE" --menu "Disk size (GB):" 14 50 5 \
  "32" "32 GB (default)" "64" "64 GB (more history/backups)" "128" "128 GB" "48" "48 GB" "C" "Custom..." \
  3>&1 1>&2 2>&3) || cancel
if [[ "$DISK" == "C" ]]; then
  ask_number DISK "Disk size in GB (minimum 32):" 32 32
fi

# Storage list read from Proxmox - only active storages, with free space
mapfile -t STORAGES < <(pvesm status -content images 2>/dev/null \
  | awk 'NR>1 && $3=="active" {print $1; printf "%s (%.0f GB free)\n", $2, $6/1024/1024}')
[[ ${#STORAGES[@]} -gt 0 ]] || error "No active storage for VM disks found."
STORAGE=$(whiptail --title "$TITLE" --menu "Storage:" 14 60 5 "${STORAGES[@]}" 3>&1 1>&2 2>&3) || cancel
STORAGE_FREE_GB=$(pvesm status -storage "$STORAGE" 2>/dev/null | awk 'NR>1 {printf "%d", $6/1024/1024}')

# Network bridge
mapfile -t BRIDGES < <(ip -o link show type bridge | awk -F': ' '{print $2; print "Bridge"}')
BRIDGE=$(whiptail --title "$TITLE" --menu "Network bridge:" 13 50 4 "${BRIDGES[@]}" 3>&1 1>&2 2>&3) || cancel

# USB passthrough (e.g. Zigbee/Z-Wave/Thread stick) - optional
# Lists all USB devices except internal root hubs (vendor 1d6b)
USB_SELECTED=()
mapfile -t USB_LIST < <(lsusb 2>/dev/null \
  | awk '$6 !~ /^1d6b:/ {id=$6; $1=$2=$3=$4=$5=$6=""; sub(/^ +/,""); print id; print substr($0,1,40); print "OFF"}')
if [[ ${#USB_LIST[@]} -gt 0 ]]; then
  USB_CHOICE=$(whiptail --title "$TITLE" --checklist \
    "USB devices to pass through to the VM (SPACE = select, ENTER = confirm):" \
    18 70 8 "${USB_LIST[@]}" 3>&1 1>&2 2>&3) || cancel
  read -r -a USB_SELECTED <<< "$(tr -d '"' <<< "$USB_CHOICE")"
fi
USB_TEXT="${USB_SELECTED[*]:-none}"

START="no"
whiptail --title "$TITLE" --yesno "Start the VM right after installation?" 8 50 && START="yes"

# --- Resource check (warn, but let the user decide) ----------
WARNINGS=""
if (( CORES > HOST_CORES )); then
  WARNINGS+="- CPU: you selected $CORES cores, but the host has only $HOST_CORES.\n"
fi
if (( RAM > MEM_AVAIL_MB )); then
  WARNINGS+="- Memory: you selected $RAM MB, but only $MEM_AVAIL_MB MB is available ($MEM_TOTAL_MB MB installed).\n"
fi
if (( RAM < 2048 )); then
  WARNINGS+="- Memory: $RAM MB is below the Home Assistant minimum of 2048 MB.\n"
fi
if [[ -n "${STORAGE_FREE_GB:-}" ]] && (( DISK > STORAGE_FREE_GB )); then
  WARNINGS+="- Disk: you selected $DISK GB, but only $STORAGE_FREE_GB GB is free on $STORAGE.\n"
fi
if [[ -n "$WARNINGS" ]]; then
  whiptail --title "$TITLE - WARNING" --yesno --defaultno \
    "Your selection exceeds the available resources:\n\n${WARNINGS}\nContinue anyway?" 16 70 || cancel
fi

# --- Summary -------------------------------------------------
whiptail --title "$TITLE" --yesno "Please review:

  HAOS version : $HAOS_VER
  VM ID        : $VMID
  Name         : $VMNAME
  CPU cores    : $CORES
  Memory       : $RAM MB
  Disk         : $DISK GB on $STORAGE
  Network      : $BRIDGE
  USB devices  : $USB_TEXT
  Auto start   : $START

Install now?" 21 60 || cancel

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

# Attach selected USB devices by vendor:product ID (works on any USB port)
i=0
for dev in "${USB_SELECTED[@]}"; do
  qm set "$VMID" --usb$i "host=$dev" >/dev/null
  info "USB device $dev passed through as usb$i"
  i=$((i+1))
done

# --- Start ---------------------------------------------------
if [[ "$START" == "yes" ]]; then
  qm start "$VMID"
  info "VM started"
fi

echo
info "Done! Home Assistant will be reachable in about 5-10 minutes at:"
echo "     http://homeassistant.local:8123  (or http://<VM-IP>:8123)"
echo "     Find the IP in Proxmox under VM $VMID > Summary or in your router."
