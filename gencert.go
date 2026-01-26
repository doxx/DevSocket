// SPDX-License-Identifier: MIT
// Copyright © 2026 doxx.net. All Rights Reserved.

//go:build ignore

// gencert generates a self-signed certificate for DebugSocket
// Run with: go run gencert.go [hostname]
// Output: debugsocket.crt, debugsocket.key, and base64 for Swift embedding

package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"os"
	"time"
)

func main() {
	hostname := "debugsocket"
	if len(os.Args) > 1 {
		hostname = os.Args[1]
	}

	// Generate ECDSA private key (smaller than RSA, faster)
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to generate private key: %v\n", err)
		os.Exit(1)
	}

	// Certificate valid for 10 years
	notBefore := time.Now()
	notAfter := notBefore.Add(10 * 365 * 24 * time.Hour)

	// Generate serial number
	serialNumber, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to generate serial number: %v\n", err)
		os.Exit(1)
	}

	// Create certificate template
	template := x509.Certificate{
		SerialNumber: serialNumber,
		Subject: pkix.Name{
			CommonName:   hostname,
			Organization: []string{"doxx.net DebugSocket"},
		},
		NotBefore:             notBefore,
		NotAfter:              notAfter,
		KeyUsage:              x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              []string{hostname, "localhost"},
		IPAddresses:           []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")},
	}

	// Self-sign the certificate
	derBytes, err := x509.CreateCertificate(rand.Reader, &template, &template, &privateKey.PublicKey, privateKey)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create certificate: %v\n", err)
		os.Exit(1)
	}

	// Write certificate to file
	certFile, err := os.Create("debugsocket.crt")
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create cert file: %v\n", err)
		os.Exit(1)
	}
	pem.Encode(certFile, &pem.Block{Type: "CERTIFICATE", Bytes: derBytes})
	certFile.Close()

	// Write private key to file
	keyFile, err := os.Create("debugsocket.key")
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create key file: %v\n", err)
		os.Exit(1)
	}
	keyBytes, err := x509.MarshalECPrivateKey(privateKey)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to marshal private key: %v\n", err)
		os.Exit(1)
	}
	pem.Encode(keyFile, &pem.Block{Type: "EC PRIVATE KEY", Bytes: keyBytes})
	keyFile.Close()

	// Output base64 DER for Swift embedding
	base64Cert := base64.StdEncoding.EncodeToString(derBytes)

	fmt.Println("✅ Generated self-signed certificate")
	fmt.Println("")
	fmt.Println("Files created:")
	fmt.Println("  📄 debugsocket.crt  (PEM certificate)")
	fmt.Println("  🔑 debugsocket.key  (PEM private key)")
	fmt.Println("")
	fmt.Println("Server usage:")
	fmt.Printf("  ./bin/DebugSocket_* --secret=xxx --bind-v4=0.0.0.0:8765 --tls --cert=debugsocket.crt --key=debugsocket.key\n")
	fmt.Println("")
	fmt.Println("Swift pinned certificate (copy this to DebugSocket.swift):")
	fmt.Println("────────────────────────────────────────────────────────────")
	fmt.Println("private let pinnedCertificateBase64: String? = \"\"\"")
	
	// Print base64 in 64-char lines for readability
	for i := 0; i < len(base64Cert); i += 64 {
		end := i + 64
		if end > len(base64Cert) {
			end = len(base64Cert)
		}
		fmt.Println(base64Cert[i:end])
	}
	fmt.Println("\"\"\"")
	fmt.Println("────────────────────────────────────────────────────────────")
	fmt.Println("")
	fmt.Printf("Certificate valid: %s to %s\n", notBefore.Format("2006-01-02"), notAfter.Format("2006-01-02"))
	fmt.Printf("Hostname/SNI: %s (also valid for localhost, 127.0.0.1, ::1)\n", hostname)
}
