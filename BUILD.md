# Tuxler-Wine Build Instructions

This document provides instructions for building the Tuxler-Wine project from source.

## Prerequisites

### System Dependencies
```bash
sudo apt-get update
sudo apt-get install -y build-essential wine32 wine64 xvfb python3 python3-pip dbus-x11
```

### Python Dependencies
```bash
pip3 install --user -r requirements.txt
```

## Build Steps

### 1. Compile the SOCKS5 Shim
```bash
cd app
gcc -shared -fPIC -ldl -o socks5shim.so socks5shim.c
gcc -shared -fPIC -ldl -o socks5shim64.so socks5shim.c
```

### 2. Create Wine Prefix
```bash
export WINEPREFIX=/root/.config/tuxler-wine/wine32
export WINEARCH=win32
wineboot -u
```

### 3. Set Up Directories
```bash
sudo mkdir -p /var/log/tuxler
sudo mkdir -p /root/.cache/tuxler
sudo mkdir -p /root/.config/tuxler-wine
mkdir -p /root/.local/share/applications
```

### 4. Make Scripts Executable
```bash
chmod +x app/*.sh
chmod +x app/*.py
chmod +x app/chromium-tux
```

### 5. Create Desktop Entries
The installation script will create desktop entries, but you can also create them manually:

```bash
# Chromium launcher
cat > ~/.local/share/applications/chromium-tux.desktop << EOF
[Desktop Entry]
Name=Chromium Tuxler
Comment=Chromium with Tuxler proxy
Exec=/opt/tuxler-wine/app/chromium-tux
Icon=chromium
Terminal=false
Type=Application
Categories=Network;WebBrowser;
EOF

# Tuxler launcher
cat > ~/.local/share/applications/tuxler-wine.desktop << EOF
[Desktop Entry]
Name=Tuxler Wine
Comment=Tuxler VPN client running on Wine
Exec=/opt/tuxler-wine/app/start.sh
Icon=applications-internet
Terminal=false
Type=Application
Categories=Network;
EOF
```

## Testing

### 1. Start the Service
```bash
/opt/tuxler-wine/app/start.sh
```

### 2. Run Verification Script
```bash
/opt/tuxler-wine/app/verify.sh
```

### 3. Test Chromium
```bash
/opt/tuxler-wine/app/chromium-tux https://ip-api.com/json/
```

## Build Verification

The verification script checks the following components:
1. Tuxler process running
2. Geo gate listening
3. Chromium with extensions
4. US IP geolocation
5. Memory usage

All checks should pass for a successful build.

## Troubleshooting

### Compilation Errors
If you encounter errors during compilation:
- Ensure all dependencies are installed
- Check Wine is properly installed
- Verify gcc version compatibility

### Runtime Errors
If components fail to start:
- Check logs in `/var/log/tuxler/`
- Verify Wine prefix creation
- Ensure Tuxler VPN executable is in place

### Memory Issues
If you encounter OOM errors:
- The memory guard should automatically clean up
- Check memory usage with `free -h`
- Adjust memory threshold in config if needed