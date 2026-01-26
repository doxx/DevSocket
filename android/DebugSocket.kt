// SPDX-License-Identifier: MIT
// Copyright © 2026 doxx.net. All Rights Reserved.

package net.doxx.debugsocket

import android.annotation.SuppressLint
import android.os.Build
import android.provider.Settings
import android.util.Base64
import android.util.Log
import kotlinx.coroutines.*
import okhttp3.*
import okio.ByteString
import org.json.JSONObject
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.TimeUnit
import javax.net.ssl.*

/**
 * Remote debug log streaming for debug/beta builds.
 * Drop this file into your Android project and call DebugSocket.connectIfDebug(context) on app launch.
 *
 * Dependencies (add to build.gradle):
 *   implementation 'com.squareup.okhttp3:okhttp:4.12.0'
 *   implementation 'org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3'
 */
object DebugSocket {
    private const val TAG = "DebugSocket"

    // ========================================
    // CONFIGURATION - UPDATE THESE
    // ========================================
    private const val SERVER_URL = "wss://debug.doxx.net/stream"
    private const val SHARED_SECRET = "YOUR_SHARED_SECRET_HERE"

    // Certificate pinning (optional)
    // Set to null to use standard PKI validation
    // Set to base64-encoded DER certificate to pin to a specific cert
    // Generate with: make gencert (on the server side)
    private val PINNED_CERTIFICATE_BASE64: String? = null

    // Example pinned cert:
    // private val PINNED_CERTIFICATE_BASE64: String? = """
    // MIIB4zCCAYigAwIBAgIRAPAiLKkxJU39GLFOMYWqQNMwCgYIKoZIzj0EAwIwODEd
    // ... (paste from gencert output) ...
    // """.trimIndent()

    // ========================================
    // State
    // ========================================
    private var webSocket: WebSocket? = null
    private var client: OkHttpClient? = null
    private var isConnected = false
    private var shouldReconnect = true
    private var deviceHash: String? = null
    private var deviceName: String? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val isoDateFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }

    // ========================================
    // Public API
    // ========================================

    /**
     * Call this on app launch - only connects for debug builds
     * @param context Android context (Application or Activity)
     */
    @SuppressLint("HardwareIds")
    fun connectIfDebug(context: android.content.Context) {
        // Only connect in debug builds
        if (!BuildConfig.DEBUG) {
            // For release builds, you could check if it's a beta/internal track
            // For now, skip entirely in release
            return
        }

        // Get device identifier
        val androidId = Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
        deviceHash = md5Hash(androidId ?: UUID.randomUUID().toString())
        deviceName = "${Build.MANUFACTURER} ${Build.MODEL}"

        connect()
    }

    /**
     * Manually start connection
     */
    fun connect() {
        if (deviceHash == null) {
            Log.e(TAG, "Must call connectIfDebug(context) first")
            return
        }

        scope.launch {
            doConnect()
        }
    }

    /**
     * Stop streaming and disconnect
     */
    fun disconnect() {
        shouldReconnect = false
        webSocket?.close(1000, "Client disconnect")
        webSocket = null
        isConnected = false
    }

    /**
     * Send a log message to the debug server
     */
    fun log(message: String) {
        if (!isConnected || webSocket == null) return

        try {
            val entry = JSONObject().apply {
                put("ts", isoDateFormat.format(Date()))
                put("msg", message)
            }
            webSocket?.send(entry.toString())
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send log: ${e.message}")
        }
    }

    /**
     * Log with tag prefix (convenience method)
     */
    fun log(tag: String, message: String) {
        log("[$tag] $message")
    }

    // ========================================
    // Private Implementation
    // ========================================

    private fun doConnect() {
        if (webSocket != null) return

        val hash = deviceHash ?: return
        val name = deviceName?.let { java.net.URLEncoder.encode(it, "UTF-8") } ?: "Unknown"

        var urlString = "$SERVER_URL?device=$hash&name=$name&secret=$SHARED_SECRET"

        // Add tunnel IPs if available (hook into your VPN manager)
        getCurrentIPv4()?.let { urlString += "&ipv4=$it" }
        getCurrentIPv6()?.let { urlString += "&ipv6=$it" }

        // Build OkHttp client
        client = buildOkHttpClient()

        val request = Request.Builder()
            .url(urlString)
            .build()

        webSocket = client?.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                isConnected = true
                shouldReconnect = true
                Log.i(TAG, "Connected to $SERVER_URL")
                if (PINNED_CERTIFICATE_BASE64 != null) {
                    Log.i(TAG, "Using pinned certificate")
                }
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                // Server might send commands in future
            }

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                // Binary messages not used
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                Log.i(TAG, "Connection closing: $code $reason")
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                handleDisconnect()
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.e(TAG, "Connection failed: ${t.message}")
                handleDisconnect()
            }
        })
    }

    private fun handleDisconnect() {
        isConnected = false
        webSocket = null

        if (!shouldReconnect) return

        Log.i(TAG, "Disconnected, reconnecting in 5s...")
        scope.launch {
            delay(5000)
            doConnect()
        }
    }

    private fun buildOkHttpClient(): OkHttpClient {
        val builder = OkHttpClient.Builder()
            .pingInterval(30, TimeUnit.SECONDS)
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.SECONDS) // No timeout for WebSocket
            .writeTimeout(30, TimeUnit.SECONDS)

        // Apply certificate pinning if configured
        PINNED_CERTIFICATE_BASE64?.let { base64Cert ->
            try {
                val certBytes = Base64.decode(base64Cert.replace("\n", "").replace(" ", ""), Base64.DEFAULT)
                val certFactory = CertificateFactory.getInstance("X.509")
                val certificate = certFactory.generateCertificate(certBytes.inputStream()) as X509Certificate

                // Create trust manager that only trusts the pinned cert
                val trustManager = object : X509TrustManager {
                    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {}

                    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
                        if (chain.isNullOrEmpty()) {
                            throw javax.net.ssl.SSLException("No server certificate")
                        }
                        // Compare the server's certificate with our pinned certificate
                        if (!chain[0].encoded.contentEquals(certificate.encoded)) {
                            throw javax.net.ssl.SSLException("Certificate pinning: MISMATCH")
                        }
                        Log.d(TAG, "Certificate pinning: MATCHED")
                    }

                    override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf(certificate)
                }

                val sslContext = SSLContext.getInstance("TLS")
                sslContext.init(null, arrayOf(trustManager), SecureRandom())

                builder.sslSocketFactory(sslContext.socketFactory, trustManager)
                builder.hostnameVerifier { _, _ -> true } // We're pinning, so hostname doesn't matter

            } catch (e: Exception) {
                Log.e(TAG, "Failed to setup certificate pinning: ${e.message}")
            }
        }

        return builder.build()
    }

    private fun md5Hash(input: String): String {
        val md = MessageDigest.getInstance("MD5")
        val digest = md.digest(input.toByteArray())
        return digest.joinToString("") { "%02x".format(it) }
    }

    /**
     * Override this to provide current tunnel IPv4 address
     */
    private fun getCurrentIPv4(): String? {
        // TODO: Hook into your VPN/tunnel manager
        // Example: return VpnManager.currentTunnel?.assignedIP
        return null
    }

    /**
     * Override this to provide current tunnel IPv6 address
     */
    private fun getCurrentIPv6(): String? {
        // TODO: Hook into your VPN/tunnel manager
        // Example: return VpnManager.currentTunnel?.assignedIPv6
        return null
    }
}

// ========================================
// Integration Example
// ========================================

/*
 * 1. Add dependencies to build.gradle:
 *
 *    dependencies {
 *        implementation 'com.squareup.okhttp3:okhttp:4.12.0'
 *        implementation 'org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3'
 *    }
 *
 * 2. In your Application class:
 *
 *    class MyApp : Application() {
 *        override fun onCreate() {
 *            super.onCreate()
 *            DebugSocket.connectIfDebug(this)
 *        }
 *    }
 *
 * 3. Use in your code:
 *
 *    // Simple log
 *    DebugSocket.log("User tapped connect button")
 *
 *    // Log with tag
 *    DebugSocket.log("VPN", "Tunnel established: $serverName")
 *
 *    // Wrap existing logging
 *    fun myLog(tag: String, msg: String) {
 *        Log.d(tag, msg)
 *        DebugSocket.log(tag, msg)
 *    }
 */
