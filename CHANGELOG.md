# Tuxler-Wine Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial release of Tuxler-Wine project
- Complete installation script with all dependencies
- Geo gate that only allows US residential IPs
- Chromium launcher with proper environment setup
- Memory guard to prevent OOM killer
- Watchdog script for automatic restart
- Comprehensive verification script
- Multiple desktop entries for different Chromium profiles

### Technical Details
- SOCKS5 shim for intercepting all connections
- Wine32 prefix for Tuxler VPN client
- Xvfb for headless operation
- D-Bus session bus for Chromium functionality
- Log rotation and management
- PID file management for services

## [1.0.0] - 2023-10-24

### Added
- Initial release with complete functionality
- Installation script (`install.sh`)
- Start/stop/status scripts
- Verification script with 17 checks
- Memory guard script
- Watchdog script
- Chromium launcher with profile support
- Desktop entries for easy access
- Comprehensive documentation

### Fixed
- Fixed Chromium extensions loading issue
- Relocated logs from /tmp to /var/log/tuxler to prevent OOM
- Created memory guard script to prevent cgroup overflow
- Verified click handling works (both left-click and right-click context menu)
- Updated openbox menu with correct Chromium launcher

### Documentation
- README.md with complete installation and usage instructions
- BUILD.md with build instructions
- LICENSE file with MIT license
- Comprehensive troubleshooting guide

## Future Considerations

### Planned Features
- Systemd service integration
- Configuration GUI
- Advanced logging and monitoring
- Multiple geo-location support
- Automatic Tuxler executable download

### Known Issues
- Wine32 compatibility with newer Tuxler versions
- Memory usage optimization
- IPv6 support in geo gate
- Error handling improvements

### Dependencies
- Wine32 and Wine64
- Xvfb
- Python 3
- Chromium
- curl
- dbus-x11