# NaiveGui

A native macOS menu bar application for managing [NaiveProxy](https://github.com/klzgrad/naiveproxy) connections with a modern SwiftUI interface.

## Requirements

- macOS 13.0+ (Ventura or later)
- NaiveProxy binary

## Features

### Profiles
- Create, edit, and manage multiple server profiles
- Move profiles up/down with toolbar buttons
- One-click connect/disconnect

### Routing
- Visual rule editor with support for:
  - Domain
  - Domain Suffix
  - Domain Keyword
  - IP CIDR
  - Rule Set (GeoIP/GeoSite)
- Built-in CN direct template (CN GeoIP + CN GeoSite -> Direct)
- Configurable default outbound (`Direct` or `Proxy`)
- Optional automatic system proxy configuration
- Native SOCKS/HTTP routing proxy with GeoIP/GeoSite `.srs` rule-set cache

### Status
- Connection state indicator
- Active profile display
- Listen address URLs

### Logs
- Real-time log streaming from naive and the native router
- Timestamped, color-coded output
- Clear logs functionality

### Settings
- Configure naive binary path and listen address/port
- HTTP proxy toggle and port configuration
- Configure native routing defaults, listen address, and ports
- Routing default outbound, listen address, and port
- Auto system proxy toggle

## Architecture

- **SwiftUI** for the entire UI layer
- **AppKit** integration via `NSApplicationDelegate` for menu bar and termination handling
- Native Swift routing proxy with GeoIP/GeoSite rule-set support
- **UserDefaults** for profile persistence and settings storage

## Build

```
xcodebuild -project NaiveGui.xcodeproj -scheme NaiveGui -configuration Debug build
```

## Version

Current version: **3.0**
