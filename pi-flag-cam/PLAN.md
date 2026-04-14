# Pi Flag Cam — Implementation Plan

## Context

Raspberry Pi Zero W (`pi-flag-cam.local`, 192.168.86.55) — headless IoT device with two USB peripherals:
- **Luxafor Flag** (VID: 04d8, PID: f372) — USB HID LED status indicator
- **Microsoft LifeCam HD-3000** (VID: 045e, PID: 0810) — USB webcam at `/dev/video0`

**Pi specs**: single-core ARMv6 (BCM2835), 427MB RAM, WiFi, 64GB SD card, Raspbian Trixie (Debian 13), Python 3.13.5, SSH enabled.

**Pi current state**: Clean system. Old Luxafor scripts deleted. System packages `python3-hid` (0.14.0) and `python3-hidapi` (0.2.2) installed. Incorrect udev rules exist (target `SUBSYSTEM=="usb"` instead of `SUBSYSTEM=="hidraw"`, so `/dev/hidraw0` is root-only).

**Remnants to clean up**:
- `/etc/udev/rules.d/10-luxafor.rules` — empty file
- `/etc/udev/rules.d/99-luxafor.rules` — incorrect rule
- No other custom remnants found (checked modprobe, systemd, crontab, pip, venvs, /opt, /usr/local/bin)

**Camera capabilities** (confirmed via v4l2-ctl):
- MJPEG: up to 1280x720@30fps (hardware-compressed, zero CPU load)
- YUYV: up to 640x480@30fps, 1280x720@10fps

## Architecture

Single Python HTTP server on the Pi using stdlib `http.server` (zero extra dependencies, ~10MB RAM). Serves both Luxafor control and camera snapshots. Local CLI scripts use curl to talk to it.

**Dependencies on Pi** (installed via script):
- `python3-hid` — already installed, for HID control of Luxafor
- `fswebcam` — needs install (43KB package), for JPEG capture from webcam
- `v4l-utils` — already installed (v4l2-ctl)

## Project Structure

```
pi-flag-cam/
  pi/                                # Files deployed to Pi
    server.py                        # HTTP API server (Luxafor + camera)
    config/
      pi-flag-cam.service            # systemd unit
      99-luxafor.rules               # udev — HID access for Luxafor
      journald-pi-flag-cam.conf      # journald — volatile logging
      modprobe-blacklist.conf        # blacklist unnecessary kernel modules
  scripts/
    optimize-pi.sh                   # One-time system optimization + cleanup
    deploy.sh                        # Deploy server and configs to Pi
    test.sh                          # Automated smoke tests
    lux                              # Local CLI — Luxafor control
    snapshot                         # Local CLI — camera snapshot
  PLAN.md                            # This file — living plan document
  README.md                          # Project documentation + testing guide
```

---

## Phase 0: Cleanup Old Remnants

- [x] Remove `/etc/udev/rules.d/10-luxafor.rules` (empty file)
- [x] Remove `/etc/udev/rules.d/99-luxafor.rules` (incorrect rule)
- [x] Reload udev rules

*Included in `scripts/optimize-pi.sh`.*

---

## Phase 1: System Optimization

Create `scripts/optimize-pi.sh` — one-time script that runs on the Pi via SSH.

### 1.1 Disable Unnecessary Services
- [x] Disable cloud-init suite (cloud-config, cloud-final, cloud-init-local, cloud-init-main, cloud-init-network) — saves 25+ sec boot time
- [x] Disable headless-unnecessary: udisks2, console-setup, keyboard-setup
- [x] Disable rpi-eeprom-update (Pi Zero W has no EEPROM), regenerate_ssh_host_keys (already done)
- [x] Disable NetworkManager-wait-online (delays boot 6+ sec), man-db.timer

### 1.2 Boot Config (`/boot/firmware/config.txt`)
- [x] Set `dtparam=audio=off` (was `on`)
- [x] Add `dtoverlay=disable-bt` (disable Bluetooth hardware)
- [x] Add `gpu_mem=16` (camera uses uvcvideo via USB, not GPU)
- [x] Set `camera_auto_detect=0` (no CSI camera)
- [x] Set `display_auto_detect=0` (headless)
- [x] Remove `dtoverlay=vc4-kms-v3d`, `max_framebuffers=2`, `disable_fw_kms_setup=1`
- [x] Add `dtparam=watchdog=on`

### 1.3 Blacklist Kernel Modules
- [x] Deploy `pi/config/modprobe-blacklist.conf` → `/etc/modprobe.d/pi-flag-cam-blacklist.conf`

### 1.4 Journald — Volatile Logging
- [x] Deploy `pi/config/journald-pi-flag-cam.conf` → `/etc/systemd/journald.conf.d/`

### 1.5 Watchdog
- [x] Add `RuntimeWatchdog=10s` to `/etc/systemd/system.conf`

### 1.6 Verify fstab
- [x] Confirm root is mounted with `noatime` (already confirmed)

### 1.7 Install Required Software
- [x] `sudo apt install -y fswebcam`

### 1.8 Reboot and Verify
- [x] Reboot Pi
- [x] Check boot time: 1m 06s (was 1m 34s) — **-28s**
- [x] Check RAM: 391Mi available (was 327Mi) — **+64Mi**
- [x] Check modules: 32 (was 66) — **-34 modules**
- [x] Verify camera: OK (v4l2-ctl works, YUYV+MJPEG)
- [x] Verify Luxafor HID: OK (1 device found)
- [x] Verify fswebcam: installed at /usr/bin/fswebcam
- [x] Verify watchdog: /dev/watchdog present

---

## Phase 2: HTTP Server + Luxafor Control

### 2.1 Luxafor Protocol Reference

Luxafor Flag is a USB HID device. Control via 8-byte HID reports:
- Byte 0: `0x00` (report ID)
- Byte 1: command (`0x01`=static, `0x02`=fade, `0x03`=strobe, `0x04`=wave, `0x06`=pattern)
- Byte 2: zone (`0x01`=front, `0x02-0x06`=individual LEDs, `0xFF`=all)
- Bytes 3-5: R, G, B (0-255)

Python library `hid` (system package `python3-hid`) opens device by VID/PID and writes bytes.

### 2.2 Create Config Files
- [x] `pi/config/99-luxafor.rules` — udev rules for both hidraw and libusb backends
- [x] `pi/config/pi-flag-cam.service` — systemd unit (User=aarzner, Restart=always, hardening)

### 2.3 Create Server
- [x] `pi/server.py` — HTTP API server with all endpoints (Luxafor + camera + health)

### 2.4 Create Deploy Script
- [x] `scripts/deploy.sh` — rsync + systemd + udev deployment

### 2.5 Create Local CLI
- [x] `scripts/lux` — Luxafor control CLI (named colors + RGB)

### 2.6 Deploy and Test Luxafor
- [x] Deployed and tested: red, green, blue, RGB, off — all working
- [x] Note: needed both hidraw AND libusb udev rules (python3-hid uses libusb backend)

---

## Phase 3: Camera Integration

### 3.1 Add Camera Endpoint to Server
- [x] Camera endpoint included in `pi/server.py` from the start

### 3.2 Create Local CLI
- [x] `scripts/snapshot` — saves JPEG to local file with timestamp

### 3.3 Deploy and Test Camera
- [x] Tested: 720p snapshot = 57KB valid JPEG (1280x720)
- [x] Tested: 480p snapshot = 40KB valid JPEG
- [x] JPEG magic bytes verified (FFD8)

---

## Phase 4: Smoke Tests

- [x] Created `scripts/test.sh` — 12 automated smoke tests, all passing:
  1. Pi connectivity (ping)
  2. SSH access
  3. Service running (systemctl is-active)
  4. Health endpoint (GET /health → 200)
  5. Health JSON valid (status=ok)
  6. Luxafor off
  7. Luxafor red (visual check)
  8. Luxafor RGB green
  9. Luxafor off (cleanup)
  10. Camera snapshot (GET /cam/snapshot → 200)
  11. Snapshot valid JPEG (43KB, magic=ffd8)
  12. 404 for unknown endpoint

---

## Phase 5: Documentation

- [x] Created `README.md` with:
  - Project description + architecture diagram
  - Hardware requirements
  - Quick start (optimize → deploy → use)
  - API reference (all endpoints)
  - CLI usage (lux, snapshot)
  - Testing instructions (test.sh + manual checks)
  - Troubleshooting guide
  - Environment variables reference

---

## Phase 6: Read-Only Filesystem (overlayfs)

### 6.1 Setup
- [x] Install `overlayroot` package
- [x] Build initramfs with overlayroot hooks for running kernel (`6.12.58+`)
- [x] Copy initramfs to `/boot/firmware/initramfs`
- [x] Fix dpkg (v7/v8 initramfs segfault on armv6 — removed unused kernel packages)

### 6.2 Scripts
- [x] `scripts/pi-ro.sh` — enable overlayfs (add `overlayroot=tmpfs` to cmdline, reboot)
- [x] `scripts/pi-rw.sh` — disable overlayfs (remove from cmdline, reboot)
- [x] `scripts/pi-update.sh` — rw → apt upgrade → ro
- [x] `scripts/deploy.sh` — adapted for overlay mode (remount lower FS rw, write, remount ro)

### 6.3 Fix: systemd-remount-fs + swap
- [x] Mask `systemd-remount-fs.service` in overlay mode (cannot remount overlayfs root, causes cascade failures)
- [x] Create `pi/config/zram-swap.service` — independent zram swap setup (not dependent on remount-fs)
- [x] `pi-ro.sh` masks remount-fs, `pi-rw.sh` unmasks it

### 6.4 WiFi / SSH stability
- [x] WiFi power save disabled via udev rule (`70-wifi-powersave.rules`)
- [x] SSH keepalive configured (`ClientAliveInterval 30`, `ClientAliveCountMax 3`)
- [x] `pi/wifi-watchdog.sh` — pings gateway, restarts wlan0 if unreachable (cron every 2 min)

### 6.5 Verification
- [x] Overlayfs active: `overlay on / type overlay (lowerdir=/media/root-ro, upperdir=tmpfs)`
- [x] Swap 475Mi via zram-swap.service (independent of remount-fs)
- [x] No systemd error loops after boot
- [x] All 14 smoke tests pass with overlayfs active
- [x] Deploy works in overlay mode (writes to lower FS)
- [x] Survives power cycle — all services auto-start

---

## Phase 7: Video Streaming (ustreamer)

- [x] Install `ustreamer` package (124KB, from Debian Trixie)
- [x] Create `pi/config/ustreamer.service` — MJPEG stream on port 8081, 1280x720@10fps, --slowdown, --drop-same-frames
- [x] Update `pi/server.py` — remove fswebcam, redirect /cam/* to ustreamer
- [x] Update `scripts/snapshot` — use ustreamer snapshot endpoint
- [x] Create `scripts/stream` — open live video in browser
- [x] Update `scripts/deploy.sh` — deploy ustreamer service
- [x] Update `scripts/test.sh` — 14 tests (added ustreamer service, stream, snapshot checks)
- [x] Verified: 14/14 tests pass, stream works, snapshot instant (vs 2-3s with fswebcam)

---

## Phase 8: Crash Investigation & WiFi Stability

### 8.1 Crash diagnostics
- [x] Created `pi/crash-monitor.sh` — logs system state every 30s to `/boot/firmware/` (survives reboot)
- [x] Created `pi/config/crash-monitor.service` — runs as root (needs boot partition write access)
- [x] Crash-monitor remounts boot partition rw on startup
- [x] Added to deploy.sh (both normal + overlay modes) and optimize-pi.sh

### 8.2 Root cause analysis
- [x] Crash log confirmed: all metrics normal right before crash (mem, temp, throttle, WiFi signal)
- [x] Cause: **brcmfmac WiFi driver kernel crash** under sustained MJPEG streaming load
- [x] Reproduced: 3 concurrent video streams → instant crash within minutes
- [x] Reference: raspberrypi/linux#2555

### 8.3 Fixes applied
- [x] `pi/config/brcmfmac.conf` — `roamoff=1` (disables WiFi roaming, main fix from #2555)
- [x] `hid_led` blocked via `install hid_led /bin/false` (was causing USB contention errors)
- [x] wpa_supplicant `bgscan=""` disabled (prevents background scanning during streaming)
- [x] server.py resets Luxafor to off on startup (flag retains color in hardware across reboots)
- [x] All fixes in deploy.sh, optimize-pi.sh, README.md

### 8.4 Stress test results
- [x] Reboot with roamoff=1 — applied successfully (`/sys/module/brcmfmac/parameters/roamoff` = 1)
- [x] 3 concurrent MJPEG streams → kernel Oops in `udp_fail_queue_rcv_skb` (UDP buffer overflow)
- [x] Root cause: Pi Zero W single-core ARM cannot handle multiple 720p streams — kernel network stack crashes
- [x] roamoff=1 alone doesn't prevent this — the issue is throughput, not roaming

### 8.5 System hardening
- [x] Blacklisted additional kernel modules: DRM (~600KB), IPv6 (~508KB), fuse, iptables, binfmt_misc, uio
- [x] Disabled useless timers with overlayfs: apt-daily, apt-daily-upgrade, fstrim, e2scrub, logrotate, dpkg-db-backup
- [x] Disabled serial-getty@ttyAMA0 (no UART debugging)
- [x] dwc_otg FIQ already enabled (checked, no changes needed)

### 8.6 Additional fixes
- [x] `server.py` switched to `ThreadingHTTPServer` — fixes 60s+ delay on Luxafor commands when connections stall
- [x] `server.py` resets Luxafor to off on startup — flag retains color in hardware across reboots
- [x] All changes in deploy.sh, optimize-pi.sh, README.md

---

## Risks and Mitigation

| Risk | Mitigation |
|------|------------|
| `gpu_mem=16` breaks camera | uvcvideo doesn't use GPU; increase to 32 if needed |
| SD card wear | **overlayfs active** — root is read-only, writes go to tmpfs |
| HID device contention | server.py opens/closes HID per-request |
| Overlayfs prevents boot | Edit cmdline.txt on boot partition from another PC, remove `overlayroot=tmpfs` |
| WiFi drops | Power save disabled + SSH keepalive + wifi-watchdog cron (2 min) |
| WiFi crash under streaming | brcmfmac `roamoff=1` + bgscan disabled (raspberrypi/linux#2555) |
| No swap in overlay | zram-swap.service (independent of masked systemd-remount-fs) |
| Pi hangs | Hardware watchdog: 10s → auto-reboot |
