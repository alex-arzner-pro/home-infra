# Pi Flag Cam

Remote control for a [Luxafor Flag](https://luxafor.com/luxafor-flag/) USB LED indicator and a Microsoft LifeCam HD-3000 webcam connected to a Raspberry Pi Zero W.

## Hardware

- **Raspberry Pi Zero W** (headless, WiFi) — `pi-flag-cam.local`
- **Luxafor Flag** — USB HID LED status indicator (VID: 04d8, PID: f372)
- **Microsoft LifeCam HD-3000** — USB webcam (VID: 045e, PID: 0810)

## Architecture

```
[Local machine]                       [Raspberry Pi Zero W]
  scripts/lux  ───── HTTP:8080 ────►  server.py ──► Luxafor Flag (USB HID)
  scripts/snapshot ─ HTTP:8081 ────►  ustreamer ──► LifeCam HD-3000 (V4L2)
  scripts/stream ─── HTTP:8081 ────►  ustreamer ──► LifeCam HD-3000 (V4L2)
```

- **server.py** (port 8080) — Luxafor LED control via stdlib `ThreadingHTTPServer` (~14MB RAM, non-blocking)
- **ustreamer** (port 8081) — MJPEG video stream + snapshots, 720p@10fps (~7MB RAM, ~5% CPU)
- **overlayfs** — root filesystem is read-only, all writes go to tmpfs (SD card protection)
- **zram swap** — 475MB compressed swap in RAM
- **hardware watchdog** — auto-reboot if systemd hangs (10s timeout)
- **WiFi watchdog** — auto-restart wlan0 if gateway unreachable (cron, every 2 min)

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

Syncs server files to Pi, installs systemd services (pi-flag-cam, ustreamer, zram-swap), udev rules, SSH keepalive, WiFi watchdog cron. Auto-detects overlay mode.

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

### Camera (port 8081, ustreamer)

| Endpoint | Description |
|----------|-------------|
| `http://pi-flag-cam.local:8081/?action=stream` | Live MJPEG video stream (open in browser/VLC) |
| `http://pi-flag-cam.local:8081/?action=snapshot` | Single JPEG snapshot |

Camera streams hardware MJPEG at 1280x720@10fps — zero CPU encoding on Pi. FPS is limited to 10 to avoid kernel crashes from USB controller overload (Pi Zero W shares one USB bus for WiFi + camera + Luxafor). When no clients are watching, ustreamer reduces to 1fps (`--slowdown`).

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

`deploy.sh` auto-detects overlay mode and writes to the lower (real) filesystem. Reboot to apply.

### Emergency: Overlay Prevents Boot

Mount SD card boot partition on another computer, edit `cmdline.txt`, remove `overlayroot=tmpfs`.

## Self-Healing

| Problem | Protection | Recovery time |
|---------|-----------|---------------|
| systemd hangs | Hardware watchdog (BCM2835) | 10 sec → auto-reboot |
| WiFi drops | wifi-watchdog.sh via cron | up to 2 min → wlan0 restart |
| Service crash | `Restart=always` in systemd | 3 sec → process restart |
| SD card wear | overlayfs (root read-only) | prevented |
| No swap in overlay | zram-swap.service (independent of remount-fs) | boot-time setup |
| HID driver conflict | `hid_led` blocked (`install ... /bin/false`) | prevented |
| WiFi driver crash (streaming) | brcmfmac `roamoff=1` + power save off + bgscan disabled | mitigated |
| Crash diagnostics | crash-monitor.sh logs to boot partition (survives reboot) | continuous |

## Project Structure

```
pi-flag-cam/
  pi/                              # Files deployed to Pi
    server.py                      # HTTP API server (Luxafor control, resets LED on start)
    wifi-watchdog.sh               # WiFi connectivity watchdog (cron)
    crash-monitor.sh               # System state logger (boot partition, survives reboot)
    config/
      pi-flag-cam.service          # systemd: API server
      ustreamer.service            # systemd: MJPEG video streamer
      zram-swap.service            # systemd: zram swap (overlay-compatible)
      crash-monitor.service        # systemd: crash monitor (logs to /boot/firmware/)
      99-luxafor.rules             # udev: Luxafor HID access (hidraw + libusb)
      70-wifi-powersave.rules      # udev: disable WiFi power save
      sshd_keepalive.conf          # SSH keepalive (30s interval)
      journald-pi-flag-cam.conf    # volatile logging (RAM, not SD)
      modprobe-blacklist.conf      # blacklist: hid_led, bluetooth, audio, CSI, DRM, IPv6, fuse, iptables
      brcmfmac.conf                # WiFi driver stability (roamoff=1)
  scripts/
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

**Luxafor "open failed"**: Run `./scripts/deploy.sh`, check `/dev/bus/usb/001/*` permissions are `0666`.

**No video stream**: Check `systemctl status ustreamer` on Pi. Verify camera at `/dev/video0`.

**Pi unreachable**: WiFi on Pi Zero W is unreliable. Wait 1-2 min (wifi-watchdog will restart wlan0). If mDNS fails, use IP: `PI_FLAG_CAM_HOST=192.168.86.55 ./scripts/lux red`.

**SSH drops**: WiFi power save should be off (`sudo iw dev wlan0 get power_save`). SSH keepalive is 30s.

**No swap in overlay mode**: Check `systemctl status zram-swap`. Service sets up zram independently of `systemd-remount-fs` (which is masked in overlay mode).

**Pi keeps rebooting**: Check crash log: `ssh pi-flag-cam.local 'tail -20 /boot/firmware/crash-monitor.log'`. This log survives reboots (stored on boot partition). Also check `journalctl -b -p err`.

**Pi crashes during video streaming**: Multiple concurrent MJPEG streams can cause kernel oops in UDP receive queue (`udp_fail_queue_rcv_skb`). The Pi Zero W's single-core CPU cannot handle the throughput. Mitigations: `roamoff=1` (see `pi/config/brcmfmac.conf`), power save off, bgscan disabled. If crashes persist with a single stream, reduce resolution/fps in `pi/config/ustreamer.service`.

**Luxafor color slow to respond**: Fixed by using `ThreadingHTTPServer` instead of single-threaded `HTTPServer`. If a stale HTTP connection blocks, other requests still go through.

**Luxafor LED errors in dmesg**: The `hid_led` kernel module conflicts with userspace HID access. It should be blocked via `install hid_led /bin/false` in modprobe config (deployed by `deploy.sh`).

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PI_FLAG_CAM_HOST` | `pi-flag-cam.local` | Pi hostname or IP |
| `PI_FLAG_CAM_PORT` | `8080` | API server port |
| `PI_FLAG_CAM_CAM_PORT` | `8081` | ustreamer port |
| `PI_FLAG_CAM_USER` | `aarzner` | SSH user |
