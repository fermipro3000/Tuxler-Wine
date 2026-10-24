#!/bin/bash

# Tuxler-Wine Installation Script
# This script installs Tuxler VPN with residential proxy functionality

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
INSTALL_DIR="/opt/tuxler-wine"
CACHE_DIR="$HOME/.cache/tuxler"
LOG_DIR="/var/log/tuxler"
CONFIG_DIR="$HOME/.config/tuxler-wine"
DESKTOP_DIR="$HOME/.local/share/applications"

# Check if running as root
if [[ $EUID -eq 0 ]]; then
   echo -e "${RED}This script should not be run as root${NC}"
   exit 1
fi

echo -e "${GREEN}Tuxler-Wine Installation Script${NC}"
echo "=================================="

# Create directories
echo -e "${YELLOW}Creating directories...${NC}"
sudo mkdir -p "$LOG_DIR"
sudo mkdir -p "$CACHE_DIR"
sudo mkdir -p "$CONFIG_DIR"
mkdir -p "$DESKTOP_DIR"
sudo chown -R $USER:$USER "$LOG_DIR" "$CACHE_DIR" "$CONFIG_DIR"

# Install dependencies
echo -e "${YELLOW}Installing dependencies...${NC}"
sudo apt-get update
sudo apt-get install -y wine32 wine64 xvfb python3 python3-pip dbus-x11

# Install Python dependencies
echo -e "${YELLOW}Installing Python dependencies...${NC}"
pip3 install --user -r requirements.txt

# Create wine prefix
echo -e "${YELLOW}Setting up Wine prefix...${NC}"
export WINEPREFIX="$CONFIG_DIR/wine32"
export WINEARCH="win32"
wineboot -u

# Copy application files
echo -e "${YELLOW}Copying application files...${NC}"
cp -r app "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/"*.sh
chmod +x "$INSTALL_DIR/"*.py

# Create desktop entries
echo -e "${YELLOW}Creating desktop entries...${NC}"
# Chromium launcher
cat > "$DESKTOP_DIR/chromium-tux.desktop" << EOF
[Desktop Entry]
Name=Chromium Tuxler
Comment=Chromium with Tuxler proxy
Exec=$INSTALL_DIR/chromium-tux
Icon=chromium
Terminal=false
Type=Application
Categories=Network;WebBrowser;
EOF

# Standard Chromium entry
cat > "$DESKTOP_DIR/chromium-tux-standard.desktop" << EOF
[Desktop Entry]
Name=Chromium Tuxler (Standard)
Comment=Chromium with Tuxler proxy - Standard profile
Exec=$INSTALL_DIR/chromium-tux standard
Icon=chromium
Terminal=false
Type=Application
Categories=Network;WebBrowser;
EOF

# US profile entry
cat > "$DESKTOP_DIR/chromium-tux-us.desktop" << EOF
[Desktop Entry]
Name=Chromium Tuxler (US Profile)
Comment=Chromium with Tuxler proxy - US profile
Exec=$INSTALL_DIR/chromium-tux us
Icon=chromium
Terminal=false
Type=Application
Categories=Network;WebBrowser;
EOF

# VNC optimized entry
cat > "$DESKTOP_DIR/chromium-tux-vnc.desktop" << EOF
[Desktop Entry]
Name=Chromium Tuxler (VNC)
Comment=Chromium with Tuxler proxy - VNC optimized
Exec=$INSTALL_DIR/chromium-tux vnc
Icon=chromium
Terminal=false
Type=Application
Categories=Network;WebBrowser;
EOF

# Tuxler launcher
cat > "$DESKTOP_DIR/tuxler-wine.desktop" << EOF
[Desktop Entry]
Name=Tuxler Wine
Comment=Tuxler VPN client running on Wine
Exec=$INSTALL_DIR/start.sh
Icon=applications-internet
Terminal=false
Type=Application
Categories=Network;
EOF

# Set up environment variables
echo -e "${YELLOW}Setting up environment variables...${NC}"
cat > "$CONFIG_DIR/env" << EOF
# Tuxler-Wine Environment Variables
export WINEPREFIX="$CONFIG_DIR/wine32"
export WINEARCH="win32"
export DISPLAY=:99
export XVFB_SIZE=1280x720x24
export GEO_GATE_PORT=23322
export TUXLER_SOCKS_PORT=23321
export PHONE_SOCKS_PORT=49070
export LOG_DIR="$LOG_DIR"
export CACHE_DIR="$CACHE_DIR"
EOF

# Create .bashrc additions
echo -e "${YELLOW}Setting up .bashrc additions...${NC}"
cat >> "$HOME/.bashrc" << EOF

# Tuxler-Wine Environment
if [ -f "$CONFIG_DIR/env" ]; then
    source "$CONFIG_DIR/env"
fi

# Tuxler-Wine Functions
tuxler-start() {
    cd "$INSTALL_DIR"
    ./start.sh
}

tuxler-stop() {
    cd "$INSTALL_DIR"
    ./stop.sh
}

tuxler-status() {
    cd "$INSTALL_DIR"
    ./status.sh
}

tuxler-verify() {
    cd "$INSTALL_DIR"
    ./verify.sh
}

alias tuxlog="tail -f $LOG_DIR/tuxler.log"
alias geolog="tail -f $LOG_DIR/geo-gate.log"
alias memlog="tail -f $LOG_DIR/memguard.log"
EOF

# Create systemd service (optional)
echo -e "${YELLOW}Creating systemd service...${NC}"
cat > "$CONFIG_DIR/tuxler-wine.service" << EOF
[Unit]
Description=Tuxler Wine Service
After=network.target

[Service]
Type=forking
User=$USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/start.sh
ExecStop=$INSTALL_DIR/stop.sh
Restart=on-failure
RestartSec=5
Environment=DISPLAY=:99
Environment=WINEPREFIX=$CONFIG_DIR/wine32
Environment=WINEARCH=win32

[Install]
WantedBy=multi-user.target
EOF

# Update desktop database
echo -e "${YELLOW}Updating desktop database...${NC}
update-desktop-database "$DESKTOP_DIR"

# Make scripts executable
echo -e "${YELLOW}Making scripts executable...${NC}
chmod +x "$INSTALL_DIR/"*.sh
chmod +x "$INSTALL_DIR/"*.py
chmod +x "$INSTALL_DIR/chromium-tux"

# Create symlinks for easy access
echo -e "${YELLOW}Creating symlinks...${NC}
ln -sf "$INSTALL_DIR/start.sh" "$HOME/.local/bin/tuxler-start"
ln -sf "$INSTALL_DIR/stop.sh" "$HOME/.local/bin/tuxler-stop"
ln -sf "$INSTALL_DIR/status.sh" "$HOME/.local/bin/tuxler-status"
ln -sf "$INSTALL_DIR/verify.sh" "$HOME/.local/bin/tuxler-verify"
ln -sf "$INSTALL_DIR/chromium-tux" "$HOME/.local/bin/chromium-tux"

# Add to PATH if not already there
if ! grep -q "$HOME/.local/bin" "$HOME/.bashrc"; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
fi

# Create symbolic links for logs
echo -e "${YELLOW}Setting up log symlinks...${NC}
ln -sf "$LOG_DIR/geo-gate.log" "$CACHE_DIR/"
ln -sf "$LOG_DIR/tuxler.log" "$CACHE_DIR/"
ln -sf "$LOG_DIR/memguard.log" "$CACHE_DIR/"
ln -sf "$LOG_DIR/chromium.log" "$CACHE_DIR/"

# Create initial configuration
echo -e "${YELLOW}Creating initial configuration...${NC}
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_DIR/config.ini" << EOF
# Tuxler-Wine Configuration
# This file contains configuration options for Tuxler-Wine

# Geo gate settings
geo_gate_enabled=true
geo_gate_port=23322
geo_gate_cache_dir=$CACHE_DIR

# Tuxler settings
tuxler_socks_port=23321
tuxler_log_file=$LOG_DIR/tuxler.log

# Memory settings
memory_guard_enabled=true
memory_guard_interval=60
memory_threshold_mb=1800
memory_cleanup_dir=/tmp

# Chromium settings
chromium_profile_dir=$HOME/.config/chromium
chromium_extensions_dir=$HOME/.config/chromium/Extensions
chromium_log_file=$LOG_DIR/chromium.log
EOF

echo -e "${GREEN}Installation completed successfully!${NC}"
echo ""
echo "Next steps:"
echo "1. Copy your Tuxler VPN executable to: $INSTALL_DIR/app/tuxlerVPN.exe"
echo "2. Run 'source ~/.bashrc' to load the new environment"
echo "3. Run 'tuxler-start' to start the service"
echo "4. Run 'tuxler-verify' to check that everything is working"
echo ""
echo "For more information, see the README.md file"