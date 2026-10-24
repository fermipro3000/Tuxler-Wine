# Tuxler-Wine Project

A complete residential proxy solution using Tuxler VPN running under Wine32 with a geo gate that only allows US residential IPs.

## Features

- Tuxler VPN client running on Wine32
- Geo gate that only allows traffic through US residential IPs
- Chromium browser configured with real profile containing SwitchyOmega and webrtc-control extensions
- LD_PRELOAD shim to intercept all connections through phone tunnel
- Comprehensive monitoring and watchdog scripts
- Memory guard to prevent OOM killer
- Easy installation script

## Architecture

```
Browser -> geo-gate (127.0.0.1:23322, SOCKS5) -> Tuxler (127.0.0.1:23321, SOCKS5) -> phone -> internet
```

The geo gate continuously checks the exit IP through Tuxler and only allows connections when the IP is geolocated to the US. If the IP is not US, all connections are immediately dropped.

## Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/fermipro3000/Tuxler-Wine.git
   cd Tuxler-Wine
   ```

2. Run the installation script:
   ```bash
   chmod +x install.sh
   ./install.sh
   ```

3. Copy your Tuxler VPN executable to `/opt/tuxler-wine/app/tuxlerVPN.exe`

4. Source the environment:
   ```bash
   source ~/.bashrc
   ```

5. Start the service:
   ```bash
   tuxler-start
   ```

6. Verify everything is working:
   ```bash
   tuxler-verify
   ```

## Usage

### Starting and Stopping

- `tuxler-start` - Start the Tuxler service
- `tuxler-stop` - Stop the Tuxler service
- `tuxler-status` - Check service status
- `tuxler-verify` - Run comprehensive health check

### Chromium Profiles

The installation creates multiple desktop entries for Chromium:

- **Chromium Tuxler** - Standard profile
- **Chromium Tuxler (US Profile)** - US profile
- **Chromium Tuxler (VNC)** - VNC optimized profile

You can also launch Chromium directly:
```bash
# Standard profile
/opt/tuxler-wine/app/chromium-tux

# US profile
/opt/tuxler-wine/app/chromium-tux us

# VNC optimized
/opt/tuxler-wine/app/chromium-tux vnc
```

### Logs

- `tuxlog` - View Tuxler log
- `geolog` - View geo-gate log
- `memlog` - View memory guard log

## Configuration

The configuration file is located at `~/.config/tuxler-wine/config.ini`. You can modify the following settings:

- `geo_gate_enabled` - Enable/disable geo gate
- `geo_gate_port` - Port for geo gate (default: 23322)
- `tuxler_socks_port` - Port for Tuxler SOCKS (default: 23321)
- `memory_guard_enabled` - Enable/disable memory guard
- `memory_threshold_mb` - Memory threshold in MB (default: 1800)

## Components

### geo-gate.py
A SOCKS5 proxy that only allows traffic when the exit IP is geolocated to the US. It checks the IP every 3 seconds and drops all connections if the IP is not US.

### socks5shim.c
LD_PRELOAD shim that intercepts all connections and routes them through a SOCKS5 proxy. Used to tunnel all Tuxler traffic through a phone.

### watchdog.sh
Monitors the Tuxler process and restarts it if it crashes. Also checks that the phone tunnel is alive.

### memguard.sh
Prevents OOM killer by cleaning up temporary files and capping log sizes when memory usage is high.

### chromium-tux
Chromium launcher that ensures the right environment variables are set and the D-Bus session bus is running.

## Requirements

- Wine32 and Wine64
- Xvfb
- Python 3
- Chromium
- curl
- dbus-x11

## Troubleshooting

1. If verification fails, check the logs:
   ```bash
   tuxlog
   geolog
   memlog
   ```

2. If memory usage is high, the memory guard should automatically clean up. You can manually trigger it by:
   ```bash
   sudo systemctl restart tuxler-wine-memguard
   ```

3. If the geo gate is not allowing connections, check that the exit IP is actually in the US:
   ```bash
   curl -x socks5h://127.0.0.1:23322 http://ip-api.com/json/
   ```

## License

This project is for educational purposes only. Please ensure you comply with Tuxler's terms of service and applicable laws.