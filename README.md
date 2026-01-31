# DevSocket

by Barrett Lyon @ doxx.net

Stream console logs from iOS/Android devices over WebSocket.

Created to enable Cursor AI assistance with mobile apps during development. Console messages from TestFlight builds are impossible to extract in real-time, making debugging a guessing game. This streams logs directly to your dev environment so you can see what's happening on device while working in Cursor.

**NOT for production use.** This is a dev/beta debugging tool only. The purpose is to speed up development and reduce guesswork during mobile app debugging.

MIT License

## Quick Start

### Server

```bash
# Build
make build

# Run (HTTP, IPv4 only)
./bin/DebugSocket_darwin_arm64 --secret=your-secret --bind-v4=0.0.0.0:8765

# Run (HTTPS, dual-stack)
./bin/DebugSocket_linux_amd64 \
    --secret=your-secret \
    --bind-v4=0.0.0.0:443 \
    --bind-v6=[::]:443 \
    --tls \
    --cert=/path/to/your.crt \
    --key=/path/to/your.key
```

### Command Line Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--secret` | (required) | Shared secret for auth |
| `--bind-v4` | | IPv4 bind address, e.g. `0.0.0.0:8765` |
| `--bind-v6` | | IPv6 bind address, e.g. `[::]:8765` |
| `--tls` | false | Enable TLS |
| `--cert` | | TLS certificate path |
| `--key` | | TLS private key path |

At least one of `--bind-v4` or `--bind-v6` is required.

### iOS Client

1. Copy `swift/DebugSocket.swift` into your project
2. Update `serverURL` and `sharedSecret` in the file
3. Initialize on app launch:

```swift
// App.swift or AppDelegate
@main
struct MyApp: App {
    init() {
        // Auto-connect for TestFlight/Debug builds only
        DebugSocket.shared.connectIfTestFlight()
        
        // OR: Connect only if user enabled toggle in settings
        // DebugSocket.shared.initializeIfEnabled()
    }
}
```

4. Stream your logs:

```swift
// In your logging function
func log(_ message: String) {
    print(message)
    DebugSocket.shared.log(message)
}
```

5. (Optional) Add a settings page for user control. See `swift/DebugSocketSettingsView.swift` for a complete SwiftUI detail view with toggle, device name input, status indicator, and documentation.

### Android Client

1. Copy `android/DebugSocket.kt` into your project
2. Add to `build.gradle`:
   ```gradle
   implementation 'com.squareup.okhttp3:okhttp:4.12.0'
   implementation 'org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3'
   ```
3. Update `SERVER_URL` and `SHARED_SECRET`
4. Call `DebugSocket.connectIfDebug(this)` in Application.onCreate()
5. Log with `DebugSocket.log(msg)`

### Certificate Pinning

Generate a self-signed cert to embed in the client:

```bash
make gencert
# or: go run gencert.go debug.doxx.net
```

Outputs:
- `debugsocket.crt` - PEM cert for server
- `debugsocket.key` - PEM key for server
- Base64 to paste into client

In `DebugSocket.swift`:

```swift
private let pinnedCertificateBase64: String? = """
MIIB4zCCAYigAwIBAgIRAPAiLKkxJU39GLFOMYWqQNMwCgYIKoZIzj0EAwIwODEd
... (paste generated base64) ...
"""
```

Start server with the cert:

```bash
./bin/DebugSocket_darwin_arm64 \
    --secret=your-secret \
    --bind-v4=0.0.0.0:8765 \
    --tls \
    --cert=debugsocket.crt \
    --key=debugsocket.key
```

## Usage

### List Connected Devices

```bash
curl "https://debug.doxx.net/devices?secret=your-secret"
```

```json
[
  {
    "device": "abc123def456...",
    "name": "Ben's iPhone 16",
    "ipv4": "10.99.1.5",
    "ipv6": "fd00::5",
    "connected": "2026-01-26T15:00:00Z",
    "log_count": 347
  }
]
```

### Dump Session Logs

```bash
# JSON
curl "https://debug.doxx.net/logs/abc123...?secret=your-secret"

# Text
curl "https://debug.doxx.net/logs/abc123...?secret=your-secret&format=text"
```

### Filter Logs

```bash
# Last 5 minutes
curl "https://debug.doxx.net/logs/abc123...?secret=your-secret&since=5m"

# Regex
curl "https://debug.doxx.net/logs/abc123...?secret=your-secret&regex=Error"

# Combined
curl "https://debug.doxx.net/logs/abc123...?secret=your-secret&since=30m&regex=\[API\]"
```

### Live Tail

```bash
websocat "wss://debug.doxx.net/tail/abc123...?secret=your-secret"
wscat -c "wss://debug.doxx.net/tail/abc123...?secret=your-secret"
```

## API

| Endpoint | Method | Auth | Description |
|----------|--------|------|-------------|
| `/stream` | WebSocket | `?secret=X` | Phone connects, streams logs |
| `/tail/{device}` | WebSocket | `?secret=X` | Dev connects, receives logs |
| `/devices` | GET | `?secret=X` | List connected devices |
| `/logs/{device}` | GET | `?secret=X` | Get session logs |
| `/health` | GET | None | Health check |

### /logs Query Params

| Param | Example | Description |
|-------|---------|-------------|
| `since` | `5m`, `1h`, `30s` | Time filter |
| `regex` | `Error\|Warning` | Regex filter |
| `format` | `json`, `text` | Output format |

## Session Behavior

- New connection clears previous logs
- Logs exist only while device connected
- Reconnect = fresh session

## Building

```bash
make build      # linux/amd64 + darwin/arm64
make run        # local dev, HTTP
make run-tls    # local dev, TLS
make gencert    # generate self-signed cert
make clean      # remove binaries
```

Output: `./bin/DebugSocket_linux_amd64`, `./bin/DebugSocket_darwin_arm64`

## Cursor

See [CURSOR_DEBUGGING.md](CURSOR_DEBUGGING.md) for usage examples.

## Examples

```bash
# Dev
./bin/DebugSocket_darwin_arm64 --secret=dev123 --bind-v4=127.0.0.1:8765

# Prod dual-stack
./bin/DebugSocket_linux_amd64 \
    --secret=prod-secret \
    --bind-v4=0.0.0.0:443 \
    --bind-v6=[::]:443 \
    --tls \
    --cert=/path/to/your.crt \
    --key=/path/to/your.key

# IPv6 only
./bin/DebugSocket_linux_amd64 --secret=your-secret --bind-v6=[::]:8765
```
