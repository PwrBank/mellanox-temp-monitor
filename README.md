# Mellanox Temperature Monitor for Proxmox

This bundle installs a small `systemd` service that polls `mget_temp` and writes to syslog when a Mellanox card exceeds a configured temperature threshold.

Use plain `KEY=VALUE` lines in `/etc/default/mellanox-temp-monitor` because the monitor script sources that file as root.

## Files

- `mellanox-temp-monitor.sh` - polling script
- `mellanox-temp-monitor.env` - threshold and device configuration
- `mellanox-temp-monitor.service` - systemd unit
- `install.sh` - installs and enables the service

## Prerequisites

Install Mellanox MFT and verify these work on the node:

```bash
mst start
mst status
mget_temp -d /dev/mst/mt4127_pciconf0
```

## Install

```bash
chmod +x ./install.sh ./mellanox-temp-monitor.sh
sudo ./install.sh
```

## Configure

Edit `/etc/default/mellanox-temp-monitor`:

```bash
DEVICES="/dev/mst/mt4127_pciconf0"
THRESHOLD_C=80
POLL_INTERVAL_SEC=60
REMINDER_INTERVAL_SEC=900
MST_AUTOSTART=1
```

`POLL_INTERVAL_SEC` must be at least `1`.

You can monitor multiple cards by listing more than one MST device path:

```bash
DEVICES="/dev/mst/mt4127_pciconf0 /dev/mst/mt4127_pciconf1"
```

Then restart the service:

```bash
sudo systemctl restart mellanox-temp-monitor.service
```

## Test once

Run a single read without the service loop:

```bash
sudo /usr/local/sbin/mellanox-temp-monitor.sh --check-once
```

## View alerts

```bash
journalctl -u mellanox-temp-monitor.service
journalctl -t mellanox-temp-monitor
```

The script logs:

- `warning` when a card first crosses the threshold
- `warning` reminders while it remains above threshold
- `notice` when it cools back below threshold
- `err` if temperature reads fail
