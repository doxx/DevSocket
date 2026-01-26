// SPDX-License-Identifier: MIT
// Copyright © 2026 doxx.net. All Rights Reserved.

import Foundation
import UIKit
import Security

/// Remote debug log streaming for TestFlight builds
/// Drop this file into your iOS project and call DebugSocket.shared.connectIfTestFlight() on app launch
public class DebugSocket: NSObject {
    public static let shared = DebugSocket()

    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private let queue = DispatchQueue(label: "com.doxx.debugsocket", qos: .utility)
    private var isConnected = false
    private var shouldReconnect = true

    // MARK: - Configuration (UPDATE THESE)
    
    private let serverURL = "wss://debug.doxx.net/stream"  // Your server URL
    private let sharedSecret = "YOUR_SHARED_SECRET_HERE"   // Must match --secret on server
    
    // Certificate pinning (optional)
    // Set to nil to use standard PKI validation
    // Set to base64-encoded DER certificate to pin to a specific cert
    private let pinnedCertificateBase64: String? = nil
    
    // Example pinned cert (replace with your own from: make gencert):
    // private let pinnedCertificateBase64: String? = """
    // MIIBkTCB+wIJAKHBfpegPfHtMA0GCSqGSIb3DQEBCwUAMBExDzANBgNVBAMMBmRl
    // YnVnczAeFw0yNjAxMjYwMDAwMDBaFw0zNjAxMjYwMDAwMDBaMBExDzANBgNVBAMM
    // BmRlYnVnczBcMA0GCSqGSIb3DQEBAQUAA0sAMEgCQQC7o... (truncated)
    // """
    
    private override init() {
        super.init()
    }

    // MARK: - Public API

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
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        isConnected = false
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

        let deviceHash = DeviceIdentification.deviceHash
        let deviceName = UIDevice.current.name
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Unknown"

        var urlString = "\(serverURL)?device=\(deviceHash)&name=\(deviceName)&secret=\(sharedSecret)"

        // Add tunnel IPs if available (hook into your TunnelManager)
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

        // Create session with optional certificate pinning
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        
        if pinnedCertificateBase64 != nil {
            // Use delegate for certificate pinning
            session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        } else {
            // Standard PKI validation
            session = URLSession(configuration: config)
        }
        
        socket = session?.webSocketTask(with: url)
        socket?.resume()
        isConnected = true
        shouldReconnect = true

        print("[DebugSocket] Connected to \(serverURL)")
        if pinnedCertificateBase64 != nil {
            print("[DebugSocket] Using pinned certificate")
        }

        // Keep connection alive with ping
        schedulePing()
        receiveLoop()
    }

    /// Override this to provide the current tunnel IPv4 address
    private func getCurrentIPv4() -> String? {
        // TODO: Hook into your TunnelManager to get assigned IPv4
        // Example: return TunnelManager.shared.currentTunnel?.assignedIP
        return nil
    }

    /// Override this to provide the current tunnel IPv6 address
    private func getCurrentIPv6() -> String? {
        // TODO: Hook into your TunnelManager to get assigned IPv6
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
                // Keep listening (server might send commands in future)
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

        // Retry after 5 seconds
        print("[DebugSocket] Disconnected, reconnecting in 5s...")
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.doConnect()
        }
    }
    
    // MARK: - Certificate Pinning Helper
    
    private func loadPinnedCertificate() -> SecCertificate? {
        guard let base64 = pinnedCertificateBase64,
              let data = Data(base64Encoded: base64.replacingOccurrences(of: "\n", with: "")
                                                    .replacingOccurrences(of: " ", with: "")) else {
            return nil
        }
        return SecCertificateCreateWithData(nil, data as CFData)
    }
}

// MARK: - URLSessionDelegate for Certificate Pinning

extension DebugSocket: URLSessionDelegate {
    public func urlSession(_ session: URLSession,
                          didReceive challenge: URLAuthenticationChallenge,
                          completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        // If no pinned certificate, use default validation
        guard let pinnedCert = loadPinnedCertificate() else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        
        // Get server certificate
        let serverCertCount = SecTrustGetCertificateCount(serverTrust)
        guard serverCertCount > 0 else {
            print("[DebugSocket] No server certificate found")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        // Compare certificates
        if #available(iOS 15.0, *) {
            // iOS 15+ uses SecTrustCopyCertificateChain
            guard let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
                  let serverCert = certChain.first else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            
            let serverCertData = SecCertificateCopyData(serverCert) as Data
            let pinnedCertData = SecCertificateCopyData(pinnedCert) as Data
            
            if serverCertData == pinnedCertData {
                print("[DebugSocket] Certificate pinning: MATCHED")
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                print("[DebugSocket] Certificate pinning: MISMATCH - rejecting connection")
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        } else {
            // iOS 14 and earlier (deprecated API)
            guard let serverCert = SecTrustGetCertificateAtIndex(serverTrust, 0) else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            
            let serverCertData = SecCertificateCopyData(serverCert) as Data
            let pinnedCertData = SecCertificateCopyData(pinnedCert) as Data
            
            if serverCertData == pinnedCertData {
                print("[DebugSocket] Certificate pinning: MATCHED")
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                print("[DebugSocket] Certificate pinning: MISMATCH - rejecting connection")
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}

// MARK: - Integration with existing Logger

/*
 Add this to your wg_log() function in Logger.swift:

 func wg_log(_ type: OSLogType, message msg: String) {
     os_log("%{public}s", log: OSLog.default, type: type, msg)
     guard Logger.isEnabled else { return }
     Logger.global?.log(message: msg)

     // Stream to DebugSocket (add this line)
     DebugSocket.shared.log(msg)
 }

 And in your App.swift or AppDelegate:

 @main
 struct MyApp: App {
     init() {
         DebugSocket.shared.connectIfTestFlight()
     }
     // ...
 }
*/
