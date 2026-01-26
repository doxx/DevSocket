// SPDX-License-Identifier: MIT
// Copyright © 2026 doxx.net. All Rights Reserved.

package main

import (
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// LogEntry represents a single log message from a device
type LogEntry struct {
	Timestamp time.Time `json:"ts"`
	Message   string    `json:"msg"`
}

// Session represents a connected device's debug session
type Session struct {
	DeviceHash string            `json:"device"`
	Name       string            `json:"name"`
	IPv4       string            `json:"ipv4,omitempty"`
	IPv6       string            `json:"ipv6,omitempty"`
	Connected  time.Time         `json:"connected"`
	Logs       []LogEntry        `json:"-"` // Not serialized in device list
	LogCount   int               `json:"log_count"`
	conn       *websocket.Conn   // Producer connection (phone)
	connMu     sync.Mutex        // Protects conn writes
	tailConns  []*websocket.Conn // Consumer connections (dev clients watching tail)
	tailMu     sync.RWMutex      // Protects tailConns
	logMu      sync.RWMutex      // Protects Logs slice
}

// Server handles WebSocket connections and log storage
type Server struct {
	sessions   map[string]*Session // deviceHash -> Session
	sessionsMu sync.RWMutex
	upgrader   websocket.Upgrader
	secret     string
}

func NewServer(secret string) *Server {
	return &Server{
		sessions: make(map[string]*Session),
		upgrader: websocket.Upgrader{
			CheckOrigin: func(r *http.Request) bool {
				return true // Accept all origins for debug tool
			},
		},
		secret: secret,
	}
}

// checkSecret validates the shared secret from query params
func (s *Server) checkSecret(r *http.Request) bool {
	return r.URL.Query().Get("secret") == s.secret
}

// handleStream handles WebSocket connections from phones (log producers)
func (s *Server) handleStream(w http.ResponseWriter, r *http.Request) {
	if !s.checkSecret(r) {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	deviceHash := r.URL.Query().Get("device")
	if deviceHash == "" {
		http.Error(w, "Missing device parameter", http.StatusBadRequest)
		return
	}

	deviceName := r.URL.Query().Get("name")
	if deviceName == "" {
		deviceName = "Unknown Device"
	}

	ipv4 := r.URL.Query().Get("ipv4")
	ipv6 := r.URL.Query().Get("ipv6")

	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[STREAM] Failed to upgrade connection from %s: %v", r.RemoteAddr, err)
		return
	}

	// Create new session (clears any existing logs for this device)
	s.sessionsMu.Lock()
	oldSession := s.sessions[deviceHash]
	if oldSession != nil {
		// Close old connection if exists
		if oldSession.conn != nil {
			oldSession.conn.Close()
		}
		log.Printf("[STREAM] Device reconnected, clearing old session: %s (%s)", deviceHash[:min(16, len(deviceHash))], deviceName)
	}

	session := &Session{
		DeviceHash: deviceHash,
		Name:       deviceName,
		IPv4:       ipv4,
		IPv6:       ipv6,
		Connected:  time.Now(),
		Logs:       make([]LogEntry, 0, 1000), // Pre-allocate
		conn:       conn,
		tailConns:  make([]*websocket.Conn, 0),
	}
	s.sessions[deviceHash] = session
	s.sessionsMu.Unlock()

	log.Printf("[STREAM] 📱 Device connected: %s (%s) from %s", deviceHash[:min(16, len(deviceHash))], deviceName, r.RemoteAddr)
	if ipv4 != "" || ipv6 != "" {
		log.Printf("[STREAM]    IPv4: %s, IPv6: %s", ipv4, ipv6)
	}

	// Handle incoming log messages
	defer func() {
		conn.Close()
		log.Printf("[STREAM] 📱 Device disconnected: %s (%s)", deviceHash[:min(16, len(deviceHash))], deviceName)
	}()

	for {
		_, message, err := conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
				log.Printf("[STREAM] Read error from %s: %v", deviceHash[:min(16, len(deviceHash))], err)
			}
			break
		}

		// Parse log entry
		var entry LogEntry
		if err := json.Unmarshal(message, &entry); err != nil {
			// If not JSON, treat as raw message
			entry = LogEntry{
				Timestamp: time.Now(),
				Message:   string(message),
			}
		}

		// If timestamp is zero, set to now
		if entry.Timestamp.IsZero() {
			entry.Timestamp = time.Now()
		}

		// Store log entry
		session.logMu.Lock()
		session.Logs = append(session.Logs, entry)
		session.LogCount = len(session.Logs)
		session.logMu.Unlock()

		// Forward to tail consumers
		s.broadcastToTail(session, entry)
	}
}

// broadcastToTail sends a log entry to all tail WebSocket consumers
func (s *Server) broadcastToTail(session *Session, entry LogEntry) {
	session.tailMu.RLock()
	defer session.tailMu.RUnlock()

	if len(session.tailConns) == 0 {
		return
	}

	msg, _ := json.Marshal(entry)

	var deadConns []*websocket.Conn
	for _, conn := range session.tailConns {
		conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
		if err := conn.WriteMessage(websocket.TextMessage, msg); err != nil {
			deadConns = append(deadConns, conn)
		}
	}

	// Clean up dead connections (upgrade lock)
	if len(deadConns) > 0 {
		session.tailMu.RUnlock()
		session.tailMu.Lock()
		for _, dead := range deadConns {
			for i, conn := range session.tailConns {
				if conn == dead {
					session.tailConns = append(session.tailConns[:i], session.tailConns[i+1:]...)
					conn.Close()
					break
				}
			}
		}
		session.tailMu.Unlock()
		session.tailMu.RLock()
	}
}

// handleTail handles WebSocket connections from dev clients (log consumers)
func (s *Server) handleTail(w http.ResponseWriter, r *http.Request) {
	if !s.checkSecret(r) {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	// Extract device hash from path: /tail/{device}
	path := strings.TrimPrefix(r.URL.Path, "/tail/")
	deviceHash := strings.TrimSuffix(path, "/")

	if deviceHash == "" {
		http.Error(w, "Missing device hash in path", http.StatusBadRequest)
		return
	}

	s.sessionsMu.RLock()
	session := s.sessions[deviceHash]
	s.sessionsMu.RUnlock()

	if session == nil {
		http.Error(w, "Device not found", http.StatusNotFound)
		return
	}

	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[TAIL] Failed to upgrade: %v", err)
		return
	}

	// Add to tail consumers
	session.tailMu.Lock()
	session.tailConns = append(session.tailConns, conn)
	session.tailMu.Unlock()

	log.Printf("[TAIL] 👀 Dev client connected to %s (%s) from %s", deviceHash[:min(16, len(deviceHash))], session.Name, r.RemoteAddr)

	// Keep connection alive - just read and discard (wait for close)
	defer func() {
		session.tailMu.Lock()
		for i, c := range session.tailConns {
			if c == conn {
				session.tailConns = append(session.tailConns[:i], session.tailConns[i+1:]...)
				break
			}
		}
		session.tailMu.Unlock()
		conn.Close()
		log.Printf("[TAIL] 👀 Dev client disconnected from %s", deviceHash[:min(16, len(deviceHash))])
	}()

	for {
		if _, _, err := conn.ReadMessage(); err != nil {
			break
		}
	}
}

// handleDevices returns list of connected devices
func (s *Server) handleDevices(w http.ResponseWriter, r *http.Request) {
	if !s.checkSecret(r) {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	s.sessionsMu.RLock()
	devices := make([]map[string]interface{}, 0, len(s.sessions))
	for _, session := range s.sessions {
		session.logMu.RLock()
		devices = append(devices, map[string]interface{}{
			"device":    session.DeviceHash,
			"name":      session.Name,
			"ipv4":      session.IPv4,
			"ipv6":      session.IPv6,
			"connected": session.Connected.Format(time.RFC3339),
			"log_count": len(session.Logs),
		})
		session.logMu.RUnlock()
	}
	s.sessionsMu.RUnlock()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(devices)
}

// handleLogs returns logs for a device with optional filtering
func (s *Server) handleLogs(w http.ResponseWriter, r *http.Request) {
	if !s.checkSecret(r) {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	// Extract device hash from path: /logs/{device}
	path := strings.TrimPrefix(r.URL.Path, "/logs/")
	deviceHash := strings.TrimSuffix(path, "/")

	if deviceHash == "" {
		http.Error(w, "Missing device hash in path", http.StatusBadRequest)
		return
	}

	s.sessionsMu.RLock()
	session := s.sessions[deviceHash]
	s.sessionsMu.RUnlock()

	if session == nil {
		http.Error(w, "Device not found", http.StatusNotFound)
		return
	}

	// Get filter parameters
	regexPattern := r.URL.Query().Get("regex")
	sinceStr := r.URL.Query().Get("since")

	// Copy logs for filtering
	session.logMu.RLock()
	logs := make([]LogEntry, len(session.Logs))
	copy(logs, session.Logs)
	session.logMu.RUnlock()

	// Filter by time (since parameter: 5m, 1h, 30s, etc.)
	if sinceStr != "" {
		duration, err := parseDuration(sinceStr)
		if err != nil {
			http.Error(w, fmt.Sprintf("Invalid since parameter: %v", err), http.StatusBadRequest)
			return
		}
		cutoff := time.Now().Add(-duration)
		filtered := make([]LogEntry, 0)
		for _, entry := range logs {
			if entry.Timestamp.After(cutoff) {
				filtered = append(filtered, entry)
			}
		}
		logs = filtered
	}

	// Filter by regex
	if regexPattern != "" {
		re, err := regexp.Compile(regexPattern)
		if err != nil {
			http.Error(w, fmt.Sprintf("Invalid regex: %v", err), http.StatusBadRequest)
			return
		}
		filtered := make([]LogEntry, 0)
		for _, entry := range logs {
			if re.MatchString(entry.Message) {
				filtered = append(filtered, entry)
			}
		}
		logs = filtered
	}

	// Check format parameter
	format := r.URL.Query().Get("format")
	if format == "text" {
		w.Header().Set("Content-Type", "text/plain")
		for _, entry := range logs {
			fmt.Fprintf(w, "%s  %s\n", entry.Timestamp.Format("2006-01-02 15:04:05.000"), entry.Message)
		}
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(logs)
}

// parseDuration parses duration strings like "5m", "1h", "30s"
func parseDuration(s string) (time.Duration, error) {
	return time.ParseDuration(s)
}

// handleHealth returns health check
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	if !s.checkSecret(r) {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	s.sessionsMu.RLock()
	deviceCount := len(s.sessions)
	s.sessionsMu.RUnlock()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status":  "ok",
		"devices": deviceCount,
		"ts":      time.Now().Format(time.RFC3339),
	})
}

// startHTTPServer starts an HTTP/HTTPS server on the given address
func startHTTPServer(addr string, useTLS bool, certFile, keyFile string, handler http.Handler, wg *sync.WaitGroup) {
	defer wg.Done()

	if useTLS {
		cert, err := tls.LoadX509KeyPair(certFile, keyFile)
		if err != nil {
			log.Fatalf("Failed to load TLS certificate: %v", err)
		}

		tlsConfig := &tls.Config{
			Certificates: []tls.Certificate{cert},
			MinVersion:   tls.VersionTLS12,
		}

		httpServer := &http.Server{
			Addr:      addr,
			Handler:   handler,
			TLSConfig: tlsConfig,
		}

		log.Printf("🔒 Starting HTTPS/WSS server on %s", addr)
		if err := httpServer.ListenAndServeTLS("", ""); err != nil {
			log.Fatalf("ListenAndServeTLS: %v", err)
		}
	} else {
		log.Printf("🔌 Starting HTTP/WS server on %s", addr)
		if err := http.ListenAndServe(addr, handler); err != nil {
			log.Fatalf("ListenAndServe: %v", err)
		}
	}
}

func main() {
	// Network binding flags
	bindV4 := flag.String("bind-v4", "", "IPv4 bind address (e.g., 0.0.0.0:8765)")
	bindV6 := flag.String("bind-v6", "", "IPv6 bind address (e.g., [::]:8765)")

	// TLS/PKI flags
	useTLS := flag.Bool("tls", false, "Enable TLS/SSL")
	certFile := flag.String("cert", "/etc/certs/pki/2025-2026/doxx.net.crt", "Path to TLS certificate")
	keyFile := flag.String("key", "/etc/certs/pki/2025-2026/doxx.net.key", "Path to TLS private key")

	// Auth
	secret := flag.String("secret", "", "Shared secret for authentication (required)")

	flag.Parse()

	// Validate required flags
	if *secret == "" {
		log.Fatal("--secret is required")
	}

	if *bindV4 == "" && *bindV6 == "" {
		log.Fatal("At least one of --bind-v4 or --bind-v6 is required")
	}

	server := NewServer(*secret)

	// WebSocket endpoints
	http.HandleFunc("/stream", server.handleStream) // Phone connects here
	http.HandleFunc("/tail/", server.handleTail)    // Dev tail WebSocket

	// REST endpoints
	http.HandleFunc("/devices", server.handleDevices) // List devices
	http.HandleFunc("/logs/", server.handleLogs)      // Get/filter logs

	// Health check (no auth)
	http.HandleFunc("/health", server.handleHealth)

	// Print startup info
	log.Printf("🔌 DebugSocket starting...")
	log.Printf("   Secret: %s...", (*secret)[:min(8, len(*secret))])
	if *useTLS {
		log.Printf("   TLS: enabled")
		log.Printf("   Cert: %s", *certFile)
		log.Printf("   Key:  %s", *keyFile)
	} else {
		log.Printf("   TLS: disabled")
	}
	log.Printf("")
	log.Printf("   Endpoints:")
	log.Printf("   📱 Phone:   ws[s]://HOST/stream?device=X&name=Y&secret=Z")
	log.Printf("   👀 Tail:    ws[s]://HOST/tail/{device}?secret=Z")
	log.Printf("   📋 Devices: GET /devices?secret=Z")
	log.Printf("   📄 Logs:    GET /logs/{device}?secret=Z[&since=5m][&regex=X][&format=text]")
	log.Printf("   ❤️  Health:  GET /health?secret=Z")
	log.Printf("")

	var wg sync.WaitGroup

	// Start IPv4 server if specified
	if *bindV4 != "" {
		wg.Add(1)
		go startHTTPServer(*bindV4, *useTLS, *certFile, *keyFile, nil, &wg)
	}

	// Start IPv6 server if specified
	if *bindV6 != "" {
		wg.Add(1)
		go startHTTPServer(*bindV6, *useTLS, *certFile, *keyFile, nil, &wg)
	}

	// Wait for servers to exit
	wg.Wait()
}
