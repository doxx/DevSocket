# DebugSocket + Cursor

## Setup

### 1. Start Server

```bash
cd /Users/blyon/go_projects/DebugSocket
make run          # HTTP
make run-tls      # HTTPS (generates cert)
```

### 2. Configure Client

**iOS** (`swift/DebugSocket.swift`):
```swift
private let serverURL = "wss://debug.doxx.net/stream"
private let sharedSecret = "dev-secret"
```

**Android** (`android/DebugSocket.kt`):
```kotlin
private const val SERVER_URL = "wss://debug.doxx.net/stream"
private const val SHARED_SECRET = "dev-secret"
```

### 3. Add to App

**iOS:**
```swift
DebugSocket.shared.connectIfTestFlight()
DebugSocket.shared.log(msg)
```

**Android:**
```kotlin
DebugSocket.connectIfDebug(this)
DebugSocket.log("message")
```

## Shell Commands

### List Devices

```bash
curl -s "http://localhost:8765/devices?secret=dev-secret" | jq
```

```json
[
  {
    "device": "abc123def456789...",
    "name": "Ben's iPhone 16",
    "ipv4": "10.99.1.5",
    "ipv6": "fd00::5",
    "connected": "2026-01-26T15:00:00Z",
    "log_count": 347
  }
]
```

### Get Logs

```bash
curl -s "http://localhost:8765/logs/DEVICE_HASH?secret=dev-secret" | jq
curl -s "http://localhost:8765/logs/DEVICE_HASH?secret=dev-secret&format=text"
```

### Filter by Time

```bash
curl -s "http://localhost:8765/logs/DEVICE_HASH?secret=dev-secret&since=5m&format=text"
curl -s "http://localhost:8765/logs/DEVICE_HASH?secret=dev-secret&since=30s&format=text"
curl -s "http://localhost:8765/logs/DEVICE_HASH?secret=dev-secret&since=1h&format=text"
```

### Filter by Regex

```bash
curl -s "http://localhost:8765/logs/DEVICE_HASH?secret=dev-secret&regex=Error&format=text"
curl -s "http://localhost:8765/logs/DEVICE_HASH?secret=dev-secret&regex=\[API\]&format=text"
curl -s "http://localhost:8765/logs/DEVICE_HASH?secret=dev-secret&regex=Tunnel|WireGuard&format=text"
curl -s "http://localhost:8765/logs/DEVICE_HASH?secret=dev-secret&regex=(?i)error&format=text"
```

### Combined

```bash
curl -s "http://localhost:8765/logs/DEVICE_HASH?secret=dev-secret&since=10m&regex=Error&format=text"
curl -s "http://localhost:8765/logs/DEVICE_HASH?secret=dev-secret&since=5m&regex=\[API\]&format=text"
```

### Live Tail

```bash
# websocat (brew install websocat)
websocat "ws://localhost:8765/tail/DEVICE_HASH?secret=dev-secret"

# wscat (npm install -g wscat)
wscat -c "ws://localhost:8765/tail/DEVICE_HASH?secret=dev-secret"
```

## Cursor Agent Prompts

```
"Show me the connected devices"
-> curl -s "http://localhost:8765/devices?secret=dev-secret" | jq

"Get the last 5 minutes of logs from the iPhone"
-> curl -s "http://localhost:8765/logs/abc123...?secret=dev-secret&since=5m&format=text"

"Find any errors in the device logs"
-> curl -s "http://localhost:8765/logs/abc123...?secret=dev-secret&regex=Error|error|ERROR&format=text"

"What API calls happened in the last minute?"
-> curl -s "http://localhost:8765/logs/abc123...?secret=dev-secret&since=1m&regex=API&format=text"
```

## Helper Script

```bash
#!/bin/bash
# debug.sh

SECRET="dev-secret"
HOST="http://localhost:8765"

case "$1" in
  devices|ls)
    curl -s "$HOST/devices?secret=$SECRET" | jq
    ;;
  logs)
    DEVICE="$2"
    SINCE="${3:-}"
    REGEX="${4:-}"
    URL="$HOST/logs/$DEVICE?secret=$SECRET&format=text"
    [ -n "$SINCE" ] && URL="$URL&since=$SINCE"
    [ -n "$REGEX" ] && URL="$URL&regex=$REGEX"
    curl -s "$URL"
    ;;
  tail)
    DEVICE="$2"
    websocat "ws://localhost:8765/tail/$DEVICE?secret=$SECRET"
    ;;
  *)
    echo "Usage:"
    echo "  $0 devices"
    echo "  $0 logs HASH [since] [regex]"
    echo "  $0 tail HASH"
    ;;
esac
```

```bash
./debug.sh devices
./debug.sh logs abc123... 5m
./debug.sh logs abc123... 10m "Error|Warning"
./debug.sh tail abc123...
```

## Troubleshooting

### Device Not Showing

1. Check server: `curl http://localhost:8765/health`
2. Check app console for `[DebugSocket] Connected`
3. Verify secret matches

### No Logs

1. Logs cleared on each reconnect
2. Verify `DebugSocket.shared.log(msg)` is called
3. Check device hash in curl

### TLS Issues

```bash
# Dev: skip TLS
--bind-v4=127.0.0.1:8765

# Remote: pin cert
make gencert
# Copy base64 to client
```

### WebSocket Tail

```bash
brew install websocat
# or
npm install -g wscat
```

## Production

```bash
./bin/DebugSocket_linux_amd64 \
    --secret=STRONG_SECRET \
    --bind-v4=0.0.0.0:443 \
    --bind-v6=[::]:443 \
    --tls \
    --cert=/etc/certs/pki/2025-2026/debug.doxx.net.crt \
    --key=/etc/certs/pki/2025-2026/debug.doxx.net.key
```

Self-signed:
```bash
make gencert
./bin/DebugSocket_linux_amd64 \
    --secret=STRONG_SECRET \
    --bind-v4=0.0.0.0:8765 \
    --tls \
    --cert=debugsocket.crt \
    --key=debugsocket.key
```
