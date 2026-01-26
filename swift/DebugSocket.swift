// SPDX-License-Identifier: MIT
// DebugSocket - Remote debug log streaming for iOS
// https://github.com/doxx/DebugSocket

import Foundation
import UIKit
import CryptoKit

/// Remote debug log streaming for TestFlight/development builds
/// Streams console logs to DebugSocket server for real-time debugging in Cursor or other tools
public class DebugSocket: NSObject {
    public static let shared = DebugSocket()

    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private let queue = DispatchQueue(label: "com.debugsocket.client", qos: .utility)
    private var isConnected = false
    private var shouldReconnect = true

    // MARK: - Configuration (UPDATE THESE FOR YOUR PROJECT)

    /// Your DebugSocket server URL (wss:// for TLS, ws:// for local dev)
    private let serverURL = "wss://your-server.com/stream"

    /// Shared secret - must match --secret on server
    private let sharedSecret = "YOUR_SECRET_HERE"

    /// UserDefaults key for enable/disable toggle
    private static let enabledKey = "com.debugsocket.enabled"

    /// UserDefaults key for custom device name
    private static let deviceNameKey = "com.debugsocket.deviceName"

    /// Log handler - set this to receive log calls from your logging system
    /// Example: DebugSocket.logHandler = { msg in DebugSocket.shared.log(msg) }
    public static var logHandler: ((String) -> Void)?

    /// Connection status for UI display
    public var connectionStatus: String {
        isConnected ? "Connected" : "Disconnected"
    }

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// Check if DebugSocket is enabled (persisted setting)
    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if newValue {
                shared.connect()
            } else {
                shared.disconnect()
            }
        }
    }

    /// Get/set custom device name for identification
    public static var deviceName: String {
        get { UserDefaults.standard.string(forKey: deviceNameKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: deviceNameKey)
            // Reconnect to update name on server
            if isEnabled {
                shared.disconnect()
                shared.connect()
            }
        }
    }

    /// Initialize on app launch - connects if previously enabled
    public func initializeIfEnabled() {
        if Self.isEnabled {
            connect()
        }
    }

    /// Call this on app launch - only connects for TestFlight/Debug builds
    public func connectIfTestFlight() {
        #if DEBUG
        connect()
        #else
        // Check if this is a TestFlight build (sandbox receipt)
        if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" {
            connect()
        }
        #endif
    }

    /// Manually start connection
    public func connect() {
        queue.async { [weak self] in
            self?.doConnect()
        }
    }

    /// Stop streaming and disconnect
    public func disconnect() {
        shouldReconnect = false
        isConnected = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session = nil
    }

    /// Send a log message to the debug server
    public func log(_ message: String) {
        guard isConnected, let socket = socket else { return }

        let entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "msg": message
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              let json = String(data: data, encoding: .utf8) else { return }

        socket.send(.string(json)) { error in
            if error != nil {
                // Connection might be dead, will reconnect
            }
        }
    }

    // MARK: - Private

    private func doConnect() {
        guard socket == nil else { return }
        shouldReconnect = true

        let deviceHash = Self.deviceHash

        // Use custom name from settings if set, otherwise fall back to device model
        let customName = Self.deviceName
        let deviceName: String
        if !customName.isEmpty {
            deviceName = customName
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Unknown"
        } else {
            // Fall back to device model + hash suffix
            let suffix = String(deviceHash.suffix(4))
            let model = Self.modelName
            deviceName = "\(model) (\(suffix))"
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Unknown"
        }

        // URL-encode the secret
        let encodedSecret = sharedSecret
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sharedSecret

        var urlString = "\(serverURL)?device=\(deviceHash)&name=\(deviceName)&secret=\(encodedSecret)"

        // Add tunnel IPs if available (override getCurrentIPv4/v6 for your app)
        if let ipv4 = getCurrentIPv4() {
            urlString += "&ipv4=\(ipv4)"
        }
        if let ipv6 = getCurrentIPv6() {
            urlString += "&ipv6=\(ipv6)"
        }

        guard let url = URL(string: urlString) else {
            print("[DebugSocket] Invalid URL")
            return
        }

        // Create session
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        session = URLSession(configuration: config)

        socket = session?.webSocketTask(with: url)
        socket?.resume()
        isConnected = true

        print("[DebugSocket] Connected to \(serverURL)")

        // Keep connection alive with ping
        schedulePing()
        receiveLoop()
    }

    /// Override this to provide the current tunnel IPv4 address
    private func getCurrentIPv4() -> String? {
        // Hook into your TunnelManager to get assigned IPv4
        // Example: return TunnelManager.shared.currentTunnel?.assignedIP
        return nil
    }

    /// Override this to provide the current tunnel IPv6 address
    private func getCurrentIPv6() -> String? {
        // Hook into your TunnelManager to get assigned IPv6
        // Example: return TunnelManager.shared.currentTunnel?.assignedIPv6
        return nil
    }

    private func schedulePing() {
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self = self, self.isConnected else { return }
            self.socket?.sendPing { error in
                if error == nil {
                    self.schedulePing()
                } else {
                    self.handleDisconnect()
                }
            }
        }
    }

    private func receiveLoop() {
        socket?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.receiveLoop()
            case .failure:
                self.handleDisconnect()
            }
        }
    }

    private func handleDisconnect() {
        isConnected = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil

        guard shouldReconnect else { return }

        print("[DebugSocket] Disconnected, reconnecting in 5s...")
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.doConnect()
        }
    }

    // MARK: - Device Identification

    /// MD5 hash of device's identifierForVendor for privacy
    private static var deviceHash: String {
        guard let vendorId = UIDevice.current.identifierForVendor?.uuidString else {
            return md5Hash(UUID().uuidString)
        }
        return md5Hash(vendorId)
    }

    private static func md5Hash(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    /// Human-readable device model name (e.g. "iPhone 15 Pro Max")
    private static var modelName: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return mapToModelName(identifier)
    }

    private static func mapToModelName(_ identifier: String) -> String {
        switch identifier {
        // iPhone 17 series
        case "iPhone18,1": return "iPhone 17"
        case "iPhone18,2": return "iPhone 17 Pro Max"
        case "iPhone18,3": return "iPhone 17 Pro"
        case "iPhone18,4": return "iPhone 17 Air"
        // iPhone 16 series
        case "iPhone17,1": return "iPhone 16 Pro"
        case "iPhone17,2": return "iPhone 16 Pro Max"
        case "iPhone17,3": return "iPhone 16"
        case "iPhone17,4": return "iPhone 16 Plus"
        // iPhone 15 series
        case "iPhone16,1": return "iPhone 15 Pro"
        case "iPhone16,2": return "iPhone 15 Pro Max"
        case "iPhone15,4": return "iPhone 15"
        case "iPhone15,5": return "iPhone 15 Plus"
        // iPhone 14 series
        case "iPhone15,2": return "iPhone 14 Pro"
        case "iPhone15,3": return "iPhone 14 Pro Max"
        case "iPhone14,7": return "iPhone 14"
        case "iPhone14,8": return "iPhone 14 Plus"
        // iPhone 13 series
        case "iPhone14,5": return "iPhone 13"
        case "iPhone14,4": return "iPhone 13 mini"
        case "iPhone14,2": return "iPhone 13 Pro"
        case "iPhone14,3": return "iPhone 13 Pro Max"
        // iPad Pro
        case "iPad13,4", "iPad13,5", "iPad13,6", "iPad13,7": return "iPad Pro 11-inch (3rd gen)"
        case "iPad13,8", "iPad13,9", "iPad13,10", "iPad13,11": return "iPad Pro 12.9-inch (5th gen)"
        // Simulator
        case "i386", "x86_64", "arm64": return "Simulator"
        default: return identifier
        }
    }
}

// MARK: - Integration Example

/*
 ## Quick Integration Guide

 ### 1. Add to your project

 Copy DebugSocket.swift and DebugSocketSettingsView.swift into your iOS project.

 ### 2. Configure

 Update these values in DebugSocket.swift:
 - serverURL: Your DebugSocket server URL
 - sharedSecret: Must match --secret on server

 ### 3. Initialize on app launch

 In your App.swift or AppDelegate:

 ```swift
 @main
 struct MyApp: App {
     init() {
         // Auto-connect for TestFlight/Debug builds
         DebugSocket.shared.connectIfTestFlight()

         // OR: Connect only if user enabled in settings
         DebugSocket.shared.initializeIfEnabled()
     }
 }
 ```

 ### 4. Stream your logs

 In your logging function:

 ```swift
 func log(_ message: String) {
     print(message)
     DebugSocket.shared.log(message)
 }
 ```

 Or use the callback:

 ```swift
 // In app init
 DebugSocket.logHandler = { msg in
     DebugSocket.shared.log(msg)
 }

 // Then in your logger, call the handler
 DebugSocket.logHandler?(message)
 ```

 ### 5. Add Settings UI

 Use the provided DebugSocketSettingsView for a complete settings page:

 ```swift
 // In your navigation destinations
 NavigationLink(destination: DebugSocketSettingsView()) {
     HStack {
         Image(systemName: "ant.fill")
             .foregroundColor(.yellow)
         VStack(alignment: .leading) {
             Text("Developer Debug")
             Text(DebugSocket.isEnabled ? "Enabled" : "Disabled")
                 .font(.caption)
                 .foregroundColor(.secondary)
         }
         Spacer()
         Image(systemName: "chevron.right")
             .foregroundColor(.secondary)
     }
 }
 ```

 The settings view includes:
 - Enable/disable toggle
 - Device name input for identification
 - Connection status indicator
 - Documentation and warnings

 For dark-themed apps, use DebugSocketSettingsViewDark instead.

 ### 6. Query logs from Cursor/terminal

 ```bash
 # List devices
 curl "https://your-server/devices?secret=YOUR_SECRET"

 # Get logs
 curl "https://your-server/logs/DEVICE_HASH?secret=YOUR_SECRET&format=text"

 # Filter by time
 curl "https://your-server/logs/DEVICE_HASH?secret=YOUR_SECRET&since=5m&format=text"

 # Filter by regex
 curl "https://your-server/logs/DEVICE_HASH?secret=YOUR_SECRET&regex=Error&format=text"

 # Live tail
 websocat "wss://your-server/tail/DEVICE_HASH?secret=YOUR_SECRET"
 ```

 ## Important

 - Remove or disable before App Store submission
 - Logs are cleared on each device reconnection
 - Device hash is derived from identifierForVendor (privacy-preserving)
 */
