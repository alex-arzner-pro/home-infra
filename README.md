# home-infra

Home infrastructure automation.

## Structure

- `pi-control/` — Raspberry Pi 4 (central control node)
  - `setup.sh` — Initial server setup and optimization
  - `config/` — Reference configuration files
  - `backup/` — Backup scripts and schedules
- `pi-flag-cam/` — Raspberry Pi Zero W (Luxafor Flag + USB webcam)
  - `pi/` — Files deployed to Pi (server, configs, watchdogs)
  - `scripts/` — Local CLI tools (deploy, lux, snapshot, stream, test)
  - `plans/` — Future plans (cat detection)
  - See [`pi-flag-cam/README.md`](pi-flag-cam/README.md) for full documentation
