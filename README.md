# proxmox-haos

One-command installer for a **Home Assistant OS** virtual machine on **Proxmox VE**.

Run one command on your Proxmox host, pick your settings in simple menus, and the script does the rest: it downloads the latest Home Assistant OS image, creates the VM and starts it.

**Current version: 1.2**

## Quick start

Log in to your Proxmox host as `root` (SSH is recommended, e.g. from a Mac or Linux terminal) and run:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/dzeykop/proxmox-haos/main/haos-vm.sh)"
```

After 5–10 minutes Home Assistant is reachable at:

- `http://homeassistant.local:8123`, or
- `http://<VM-IP>:8123` (the IP is shown in Proxmox under the VM → Summary, or in your router)

## Requirements

- Proxmox VE 8 or 9 (tested on both)
- Internet access on the Proxmox host
- Root access to the Proxmox host

## What the script does

1. Checks that it runs as root on a Proxmox host
2. Reads the host's hardware: CPU cores, installed and available RAM, free storage
3. Fetches the latest Home Assistant OS version from GitHub
4. Asks for your settings in menus (see below)
5. Warns you if your selection exceeds the available resources
6. Shows a summary – nothing is changed until you confirm
7. Downloads the image, creates the VM and starts it (optional)

Temporary files are removed automatically when the script ends.

## Settings you can choose

| Setting | Default | Custom input |
| --- | --- | --- |
| VM ID | next free ID | any free ID |
| VM name | HA-OS | any name |
| CPU cores | 2 | any whole number ≥ 1 |
| Memory | 4096 MB | any whole number in MB, ≥ 512 |
| Disk size | 32 GB | any whole number in GB, ≥ 32 |
| Storage | – | only active storages, with free space shown |
| Network bridge | – | only existing bridges |
| USB devices | none | e.g. Zigbee / Z-Wave / Thread stick |
| Start after install | yes | yes / no |

**Notes**

- **Memory:** 1 GB = 1024 MB (e.g. 8 GB = 8192). A warning appears below 2048 MB, the Home Assistant minimum.
- **Disk:** The minimum is 32 GB, because the Home Assistant OS image is 32 GB and a disk cannot be shrunk.
- **USB devices** are passed through by vendor/product ID, so the stick keeps working if you plug it into another USB port.
- **Warnings** are shown when the selected CPU, memory or disk is larger than what the host has available. You can still continue on purpose – "No" is preselected.

## VM configuration

The VM is created with: q35 machine, UEFI (OVMF) with Secure Boot disabled, CPU type `host`, VirtIO network, VirtIO SCSI disk with discard/SSD emulation, QEMU guest agent enabled, start on boot enabled.

## Troubleshooting

| Problem | Solution |
| --- | --- |
| The menu title does not show the latest version | GitHub caches files for a few minutes – wait 2–5 minutes and run the command again |
| `Could not reach the GitHub API` | Check internet and DNS on the Proxmox host, e.g. `ping github.com` |
| `VM ID ... already exists` | Choose another ID or delete the old VM |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` (SSH) | Run `ssh-keygen -R <IP>` on your computer and connect again |
| `homeassistant.local:8123` does not load | Wait up to 10 minutes on first boot, then try the VM's IP address |

## Changelog

| Version | Changes |
| --- | --- |
| 1.2 | Default VM name changed to `HA-OS` |
| 1.1 | "Custom..." input for CPU, memory and disk with validation; warning when memory is below 2048 MB |
| 1.0 | Hardware detection (CPU/memory/disk) and warnings when the selection exceeds available resources |
| – | Earlier: English UI, USB passthrough, active-storage filter, HAOS version detection fix |

## Disclaimer

This script runs as root and creates a VM on your Proxmox host. Read the script before running it and use it at your own risk.

Author: **JFFK** ([dzeykop](https://github.com/dzeykop))
