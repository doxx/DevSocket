// SPDX-License-Identifier: MIT
// DebugSocket Settings View - SwiftUI detail page for Developer Debug
// https://github.com/doxx/DebugSocket

import SwiftUI

/// Complete settings detail view for DebugSocket configuration
/// Provides toggle, device name input, status display, and documentation
///
/// Usage:
/// 1. Add to your navigation destination
/// 2. Link from your Settings view with a navigation row
///
/// Example navigation row in Settings:
/// ```swift
/// NavigationLink(destination: DebugSocketSettingsView()) {
///     HStack {
///         Image(systemName: "ant.fill")
///             .foregroundColor(.yellow)
///         Text("Developer Debug")
///         Spacer()
///         Text(DebugSocket.isEnabled ? "Enabled" : "Disabled")
///             .foregroundColor(.secondary)
///     }
/// }
/// ```
struct DebugSocketSettingsView: View {
    @State private var isEnabled: Bool = DebugSocket.isEnabled
    @State private var deviceName: String = DebugSocket.deviceName
    @FocusState private var isNameFieldFocused: Bool

    var body: some View {
        List {
            // Main toggle section
            Section {
                Toggle("Enable Debug Streaming", isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, newValue in
                        DebugSocket.isEnabled = newValue
                    }
            } footer: {
                Text("Streams console logs to DebugSocket server for remote debugging.")
            }

            // Device identification (only when enabled)
            if isEnabled {
                Section("Device Identification") {
                    HStack {
                        Text("Device Name")
                        Spacer()
                        TextField("e.g. Test Phone", text: $deviceName)
                            .multilineTextAlignment(.trailing)
                            .focused($isNameFieldFocused)
                            .onSubmit {
                                DebugSocket.deviceName = deviceName
                            }
                    }

                    HStack {
                        Text("Status")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                            Text(DebugSocket.shared.connectionStatus)
                                .foregroundColor(.secondary)
                        }
                    }
                } footer: {
                    Text("Set a name to identify this device in debug logs. Leave blank to use device model.")
                }
            }

            // About section
            Section("About") {
                Text("Developer Debug streams console logs from this device to a remote server in real-time. This enables debugging of TestFlight builds without being connected to Xcode.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Use cases section
            Section("Use Cases") {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("TestFlight Debugging")
                            .font(.body)
                        Text("Debug beta builds without tethering to Mac")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: "iphone.and.arrow.forward")
                        .foregroundColor(.yellow)
                }

                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cursor Integration")
                            .font(.body)
                        Text("AI assistant can query device logs in real-time")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: "terminal.fill")
                        .foregroundColor(.yellow)
                }

                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Filter and Search")
                            .font(.body)
                        Text("Query logs by time range or regex patterns")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.yellow)
                }
            }

            // Warning section
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Development Only")
                            .font(.headline)
                        Text("This feature is for development and testing. Disable before distributing to end users. Logs may contain sensitive information.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                }
            }
        }
        .navigationTitle("Developer Debug")
        .onAppear {
            isEnabled = DebugSocket.isEnabled
            deviceName = DebugSocket.deviceName
        }
        .onChange(of: isNameFieldFocused) { _, focused in
            if !focused && deviceName != DebugSocket.deviceName {
                DebugSocket.deviceName = deviceName
            }
        }
    }
}

// MARK: - Alternative: Custom Dark Theme Version

/// Dark-themed version for apps with custom dark UI
/// Uses manual styling instead of system List appearance
struct DebugSocketSettingsViewDark: View {
    @State private var isEnabled: Bool = DebugSocket.isEnabled
    @State private var deviceName: String = DebugSocket.deviceName
    @FocusState private var isNameFieldFocused: Bool

    private let accentColor = Color.yellow

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Main toggle
                toggleSection

                // Device name (when enabled)
                if isEnabled {
                    deviceSection
                }

                // About
                aboutSection

                // Use cases
                useCasesSection

                // Warning
                warningSection

                Spacer(minLength: 100)
            }
            .padding(.horizontal, 16)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Developer Debug")
        .onAppear {
            isEnabled = DebugSocket.isEnabled
            deviceName = DebugSocket.deviceName
        }
    }

    private var toggleSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Enable Debug Streaming")
                    .font(.body)
                    .foregroundColor(.white)
                Text(isEnabled ? "Streaming to server" : "Stream logs for remote debugging")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
            }

            Spacer()

            Toggle("", isOn: $isEnabled)
                .toggleStyle(SwitchToggleStyle(tint: accentColor))
                .labelsHidden()
                .onChange(of: isEnabled) { _, newValue in
                    DebugSocket.isEnabled = newValue
                }
        }
        .padding(16)
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Device Identification")
                .font(.headline)
                .foregroundColor(.white.opacity(0.8))

            VStack(spacing: 0) {
                HStack {
                    Text("Device Name")
                        .foregroundColor(.white)
                    Spacer()
                    TextField("e.g. Test Phone", text: $deviceName)
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.plain)
                        .focused($isNameFieldFocused)
                        .frame(maxWidth: 180)
                        .onSubmit {
                            DebugSocket.deviceName = deviceName
                        }
                }
                .padding(16)

                Divider().background(Color.white.opacity(0.1))

                HStack {
                    Text("Status")
                        .foregroundColor(.white)
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text(DebugSocket.shared.connectionStatus)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                .padding(16)
            }
            .background(Color.white.opacity(0.05))
            .cornerRadius(12)

            Text("Set a name to identify this device in debug logs.")
                .font(.caption)
                .foregroundColor(.white.opacity(0.5))
                .padding(.horizontal, 4)
        }
        .onChange(of: isNameFieldFocused) { _, focused in
            if !focused && deviceName != DebugSocket.deviceName {
                DebugSocket.deviceName = deviceName
            }
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About")
                .font(.headline)
                .foregroundColor(.white.opacity(0.8))

            Text("Developer Debug streams console logs from this device to a remote server in real-time. This enables debugging of TestFlight builds without being connected to Xcode.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05))
                .cornerRadius(12)
        }
    }

    private var useCasesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Use Cases")
                .font(.headline)
                .foregroundColor(.white.opacity(0.8))

            VStack(spacing: 0) {
                benefitRow(icon: "iphone.and.arrow.forward", title: "TestFlight Debugging", description: "Debug beta builds without tethering to Mac")
                Divider().background(Color.white.opacity(0.1))
                benefitRow(icon: "terminal.fill", title: "Cursor Integration", description: "AI assistant can query device logs in real-time")
                Divider().background(Color.white.opacity(0.1))
                benefitRow(icon: "magnifyingglass", title: "Filter and Search", description: "Query logs by time range or regex patterns")
            }
            .background(Color.white.opacity(0.05))
            .cornerRadius(12)
        }
    }

    private func benefitRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var warningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(accentColor)
                Text("Development Only")
                    .font(.headline)
                    .foregroundColor(.white)
            }

            Text("This feature is for development and testing. Disable before distributing to end users. Logs may contain sensitive information.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(16)
        .background(accentColor.opacity(0.15))
        .cornerRadius(12)
    }
}

#Preview {
    NavigationStack {
        DebugSocketSettingsView()
    }
}

#Preview("Dark Theme") {
    NavigationStack {
        DebugSocketSettingsViewDark()
    }
}
