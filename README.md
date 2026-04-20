# NaiveGui

A native macOS menu bar application for managing [NaiveProxy](https://github.com/klzgrad/naiveproxy) connections with a modern SwiftUI interface.

## Requirements

- macOS 13.0+ (Ventura or later)
- NaiveProxy binary
- (Optional) sing-box binary for routing support

## Features

### Profiles
- Create, edit, and manage multiple server profiles
- Drag-and-drop reordering
- One-click connect/disconnect

### Routing (sing-box)
- Visual rule editor with support for:
  - Domain
  - Domain Suffix
  - Domain Keyword
  - IP CIDR
  - Rule Set (GeoIP/GeoSite)
- Built-in CN direct template (CN GeoIP + CN GeoSite → Direct)
- Automatic system proxy configuration when routing is enabled
- Bundled geoip.dat and geosite.dat, with one-click update from GitHub or jsDelivr CDN

### Status
- Connection state indicator
- Active profile display
- Listen address URLs

### Logs
- Real-time log streaming from naive and sing-box processes
- Timestamped, color-coded output
- Clear logs functionality

### Settings
- Configure naive binary path and listen address/port
- HTTP proxy toggle and port configuration
- Enable/disable routing with sing-box binary path
- Routing listen address and port
- Auto system proxy toggle

## Architecture

- **SwiftUI** for the entire UI layer
- **AppKit** integration via `NSApplicationDelegate` for menu bar and termination handling
- **sing-box** for traffic routing with GeoIP/GeoSite support
- **UserDefaults** for profile persistence and settings storage

## Build

```
xcodebuild -project NaiveGui.xcodeproj -scheme NaiveGui -configuration Debug build
```

## Version

Current version: **1.2**