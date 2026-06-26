# Pi Flag Cam

Remote control for a [Luxafor Flag](https://luxafor.com/luxafor-flag/) USB LED indicator and a Microsoft LifeCam HD-3000 webcam connected to a Raspberry Pi Zero W.

## Hardware

- **Raspberry Pi Zero W** (headless, WiFi) — static IP `192.168.86.7` (also reachable via mDNS `pi-flag-cam.local`)
- **Luxafor Flag** — USB HID LED status indicator (VID: 04d8, PID: f372)
- **Microsoft LifeCam HD-3000** — USB webcam (VID: 045e, PID: 0810)

## Architecture

```
[Local machine]                       [Raspberry Pi Zero W]
  scripts/lux  ───── HTTP:8080 ────►  server.py ──► Luxafor Flag (USB HID)
  scripts/snapshot ─ HTTP:8081 ────►  ustreamer ──► LifeCam HD-3000 (V4L2)
  scripts/stream ─── HTTP:8081 ────►  ustreamer ──► LifeCam HD-3000 (V4L2)
```

- **server.py** (port 8080) — Luxafor LED control via stdlib `ThreadingHTTPServer`; one locked, long-lived HID handle
- **ustreamer** (port 8081) — MJPEG camera, **on-demand only**: socket-activated (`ustreamer.socket`) and idle-stopped 30s after the last client via `systemd-socket-proxyd`, gated on `/dev/video0`. While idle the camera holds no USB bandwidth, so the device is a rock-solid Luxafor Flag. Default 640x480@10fps (720p opt-in).
- **firewall** — `:8080`/`:8081` reachable only from the operator laptop + localhost via systemd `IPAddressAllow` (iptables is blacklisted, so this is cgroup-based)
- **overlayfs** — root filesystem is read-only, all writes go to tmpfs (SD card protection)
- **zram swap** — compressed swap in RAM, hard-capped at 50% RAM via `mem_limit`
- **hardware watchdog** — auto-reboot if systemd hangs (10s timeout)
- **WiFi watchdog** — after 2 consecutive gateway failures: soft `nmcli reconnect`, then a wlan0 bounce

## Quick Start

### 1. Optimize Pi (one-time)

```bash
./scripts/optimize-pi.sh
ssh aarzner@pi-flag-cam.local sudo reboot
```

Disables unnecessary services (cloud-init, bluetooth, audio, serial-getty@ttyAMA0), disables useless timers (apt-daily, fstrim, logrotate, dpkg-backup — pointless with overlayfs), reduces GPU memory, blacklists ~30 kernel modules (~1.8MB RAM saved: DRM, IPv6, FUSE, iptables, etc.), enables watchdog, installs packages (ustreamer, fswebcam, overlayroot), sets up WiFi watchdog cron, builds initramfs with overlayroot, configures volatile journald and zram swap.

### 2. Deploy

```bash
./scripts/deploy.sh
```

Syncs server files, installs systemd units (pi-flag-cam, ustreamer.socket + proxy, zram-swap, crash-monitor), udev rules, NetworkManager power-save, sysctl tuning, SSH keepalive, and the WiFi-watchdog cron. Enables the camera **socket** (on-demand), not an always-on streamer. Auto-detects overlay mode (writes to the lower fs and enables units offline via `systemctl --root`).

### 3. Enable Read-Only Mode

```bash
./scripts/pi-ro.sh    # enables overlayfs, reboots
```

### 4. Use

```bash
# Luxafor LED colors
./scripts/lux red
./scripts/lux yellow
./scripts/lux green
./scripts/lux off
./scripts/lux 255 165 0      # arbitrary RGB

# Camera
./scripts/snapshot            # save JPEG snapshot
./scripts/stream              # open live video in browser
```

## API Reference

### Luxafor Control (port 8080)

| Endpoint | Description |
|----------|-------------|
| `GET /lux/color/<name>` | Set named color: red, green, blue, yellow, cyan, magenta, white, orange, off |
| `GET /lux/rgb/<r>/<g>/<b>` | Set arbitrary RGB (0-255 each) |
| `GET /lux/off` | Turn off LED |
| `GET /cam/snapshot` | Redirect to ustreamer snapshot |
| `GET /cam/stream` | Redirect to ustreamer stream |
| `GET /health` | JSON health status |

### Camera (port 8081, ustreamer — on-demand)

| Endpoint | Description |
|----------|-------------|
| `http://192.168.86.7:8081/?action=stream` | Live MJPEG video stream (open in browser/VLC) |
| `http://192.168.86.7:8081/?action=snapshot` | Single JPEG snapshot |

The camera is **on-demand**. `ustreamer.socket` listens on `:8081`; the first request activates `systemd-socket-proxyd`, which starts `ustreamer` (gated on `ConditionPathExists=/dev/video0`) and idle-stops it 30s after the last client. While idle, `/dev/video0` is closed and no USB bandwidth is used — this is what keeps WiFi stable. If the camera is unplugged, `/cam/*` returns `503 camera not connected`.

Default profile is **640x480@10fps** (the stable ceiling for the Pi Zero W's single shared USB bus). For 720p, change `--resolution` in `pi/config/ustreamer.service` (higher USB load while streaming).

## Testing

Run automated smoke tests (14 checks):

```bash
./scripts/test.sh
```

Tests: connectivity, SSH, services (pi-flag-cam, ustreamer), health endpoint, Luxafor colors, camera snapshot, video stream, JPEG validation, error handling.

## Read-Only Filesystem (overlayfs)

Root filesystem is read-only via overlayfs. All writes go to tmpfs in RAM and are lost on reboot. SD card is protected from wear.

```bash
# Check current mode
ssh pi-flag-cam.local 'grep -q "overlayroot=tmpfs" /proc/cmdline && echo "RO" || echo "RW"'

# Switch to read-write (for maintenance)
./scripts/pi-rw.sh

# Switch back to read-only
./scripts/pi-ro.sh

# System updates (auto: rw → apt upgrade → ro)
./scripts/pi-update.sh
```

`deploy.sh` auto-detects overlay mode, writes to the lower (real) filesystem, enables units offline (`systemctl --root`), and installs the cron there. Reboot to apply.

`pi-rw.sh` unmasks `systemd-remount-fs` **in the lower fs** (not the live overlay tmpfs) and verifies `findmnt /` shows `rw` after reboot — otherwise the root would silently stay read-only and writes (nmcli/apt) would fail.

### Emergency: root stuck read-only after pi-rw

If a write fails with "Read-only file system" while in rw mode:

```bash
ssh 192.168.86.7 'sudo mount -o remount,rw /'          # quick fix for this boot
# permanent: while overlay is active, remove the mask from the lower fs
ssh 192.168.86.7 'sudo mount -o remount,rw /media/root-ro && \
  sudo rm -f /media/root-ro/etc/systemd/system/systemd-remount-fs.service && \
  sudo mount -o remount,ro /media/root-ro'
```

### Emergency: Overlay Prevents Boot

Mount SD card boot partition on another computer, edit `cmdline.txt`, remove `overlayroot=tmpfs`.

## Self-Healing

| Problem | Protection | Recovery time |
|---------|-----------|---------------|
| systemd hangs | Hardware watchdog (BCM2835) | 10 sec → auto-reboot |
| WiFi drops | wifi-watchdog: 2 consecutive fails → `nmcli reconnect`, then wlan0 bounce | up to ~4 min |
| Service crash | `Restart=always` (API) / socket re-activation (camera) | ~3 sec → restart |
| SD card wear | overlayfs (root read-only); crash log flushes to /boot only on errors | prevented |
| WiFi instability under load | **camera on-demand** (no idle USB load) + `roamoff=1` + durable power-save off (NetworkManager) | root cause removed |
| Memory pressure | zram `mem_limit` 50% RAM + `vm.min_free_kbytes`/`swappiness` tuning | OOM-thrash avoided |
| HID driver conflict | `hid_led` blocked (`install ... /bin/false`) | prevented |
| Crash diagnostics | crash-monitor logs to /boot on new errors (survives reboot) | continuous |

## Project Structure

```
pi-flag-cam/
  pi/                              # Files deployed to Pi
    server.py                      # HTTP API server (Luxafor control, resets LED on start)
    wifi-watchdog.sh               # WiFi connectivity watchdog (cron)
    crash-monitor.sh               # System state logger (boot partition, survives reboot)
    config/
      pi-flag-cam.service          # systemd: API server (+ firewall IPAddressAllow)
      ustreamer.service            # systemd: MJPEG streamer (on-demand, 127.0.0.1:8082)
      ustreamer.socket             # systemd: public :8081 socket (on-demand activation)
      ustreamer-proxy.service      # systemd: socket-proxyd, idle-stops the camera
      zram-swap.service            # systemd: zram swap (mem_limit 50%, overlay-compatible)
      crash-monitor.service        # systemd: crash monitor (logs to /boot/firmware/)
      99-luxafor.rules             # udev: Luxafor HID access (plugdev group, 0660)
      70-wifi-powersave.rules      # udev: disable WiFi power save (early boot)
      wifi-powersave-nm.conf       # NetworkManager: durable WiFi power-save off
      99-pi-flag-cam-sysctl.conf   # sysctl: memory-pressure tuning
      sshd_keepalive.conf          # SSH keepalive (30s interval)
      journald-pi-flag-cam.conf    # volatile logging (RAM, not SD)
      modprobe-blacklist.conf      # blacklist: hid_led, bluetooth, audio, CSI, DRM, IPv6, fuse, iptables
      brcmfmac.conf                # WiFi driver stability (roamoff=1)
  scripts/
    config.sh                      # Shared config: host/IP, ports, SSH user (sourced by all scripts)
    optimize-pi.sh                 # One-time Pi optimization + package install
    deploy.sh                      # Deploy to Pi (handles overlay mode)
    test.sh                        # Automated smoke tests (14 checks)
    pi-ro.sh                       # Enable read-only mode (overlayfs)
    pi-rw.sh                       # Disable read-only mode
    pi-update.sh                   # System update (rw → apt upgrade → ro)
    lux                            # CLI: Luxafor LED control
    snapshot                       # CLI: camera snapshot
    stream                         # CLI: open live video in browser
```

## Pi System Dependencies

Installed via `optimize-pi.sh`:
- `python3-hid` (pre-installed) — USB HID for Luxafor
- `ustreamer` — MJPEG video streaming
- `fswebcam` — JPEG capture (fallback)
- `overlayroot` — read-only root filesystem

## Troubleshooting

**Luxafor "open failed"**: Run `./scripts/deploy.sh`. The Luxafor `/dev/hidraw*` node should be group `plugdev`, mode `0660`; `server.py` runs with `SupplementaryGroups=plugdev` and keeps one locked HID handle (so concurrent requests no longer race the exclusive open).

**No video stream**: The camera is on-demand — check `systemctl status ustreamer.socket` (should be listening) and that `/dev/video0` exists. First request has a ~1-3s cold start. `/cam/*` returns `503` if the camera is unplugged.

**Pi unreachable**: WiFi on Pi Zero W is unreliable. Wait 1-2 min (wifi-watchdog will restart wlan0). The default host is the static IP `192.168.86.7` (set in `scripts/config.sh`). To target it by mDNS name instead: `PI_FLAG_CAM_HOST=pi-flag-cam.local ./scripts/lux red`.

**SSH drops**: WiFi power save should be off (`sudo iw dev wlan0 get power_save`). SSH keepalive is 30s.

**No swap in overlay mode**: Check `systemctl status zram-swap`. Service sets up zram independently of `systemd-remount-fs` (which is masked in overlay mode).

**Pi keeps rebooting**: Check crash log: `ssh pi-flag-cam.local 'tail -20 /boot/firmware/crash-monitor.log'`. This log survives reboots (stored on boot partition). Also check `journalctl -b -p err`.

**Pi crashes/reboot-loops during video streaming**: `udp_fail_queue_rcv_skb` is a memory-pressure oops under simultaneous WiFi + USB-isochronous (camera) load on the single shared USB bus. The real fix is the **on-demand camera** (no idle USB load), plus `roamoff=1`, durable power-save off, zram `mem_limit`, and `vm.min_free_kbytes`. If it still happens while actively streaming, keep 640x480 (don't raise to 720p) in `pi/config/ustreamer.service`.

**Luxafor color slow to respond**: Fixed by using `ThreadingHTTPServer` instead of single-threaded `HTTPServer`. If a stale HTTP connection blocks, other requests still go through.

**Luxafor LED errors in dmesg**: The `hid_led` kernel module conflicts with userspace HID access. It should be blocked via `install hid_led /bin/false` in modprobe config (deployed by `deploy.sh`).

## Environment Variables

Defaults live in `scripts/config.sh` (sourced by every script). Override any of them via the environment.

| Variable | Default | Description |
|----------|---------|-------------|
| `PI_FLAG_CAM_HOST` | `192.168.86.7` | Pi hostname or IP |
| `PI_FLAG_CAM_PORT` | `8080` | API server port |
| `PI_FLAG_CAM_CAM_PORT` | `8081` | ustreamer port |
| `PI_FLAG_CAM_USER` | `aarzner` | SSH user |
| `PI_FLAG_CAM_ALLOW_IP` | `192.168.86.86` | LAN client (t14) allowed through the firewall |
