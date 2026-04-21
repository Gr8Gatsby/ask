#if canImport(AskMacCore)
import AskMacCore
#endif
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - OnboardingView

struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ScriptManager.self) private var scriptManager
    @Environment(ScriptCatalogService.self) private var scriptCatalog
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    @Environment(HeartbeatService.self) private var heartbeat

    @State private var step: Step = .permissions
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var loginItemEnabled = false
    @State private var machineName: String = ""
    @State private var isInstalling = false
    @State private var installError: String?
    @State private var installer = ScriptInstaller()

    enum Step { case permissions, machineName, connectiPhone, welcome }

    var body: some View {
        Group {
            switch step {
            case .permissions:
                PermissionsStep(
                    notificationStatus: notificationStatus,
                    loginItemEnabled: loginItemEnabled,
                    onRequestNotifications: requestNotifications,
                    onToggleLoginItem: toggleLoginItem,
                    onContinue: { withAnimation { step = .machineName } }
                )
            case .machineName:
                MachineNameStep(
                    machineName: $machineName,
                    onContinue: {
                        let trimmed = machineName.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { settings.machineName = trimmed }
                        withAnimation { step = .connectiPhone }
                    }
                )
            case .connectiPhone:
                ConnectIPhoneStep(
                    connectedDevices: heartbeat.connectedDevices,
                    onContinue: { withAnimation { step = .welcome } }
                )
            case .welcome:
                WelcomeStep(
                    isInstalling: isInstalling,
                    installError: installError,
                    onInstall: installHelloWorld
                )
            }
        }
        .frame(width: 480)
        .task {
            await refreshPermissionsStatus()
            machineName = settings.machineName
        }
    }

    // MARK: - Permissions

    private func refreshPermissionsStatus() async {
        let ns = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = ns.authorizationStatus
        loginItemEnabled = SMAppService.mainApp.status == .enabled
    }

    private func requestNotifications() {
        if notificationStatus == .denied {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications?id=com.kevinhill.askmac")!)
            return
        }
        Task {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            await refreshPermissionsStatus()
        }
    }

    private func toggleLoginItem() {
        let service = SMAppService.mainApp
        if service.status == .enabled {
            try? service.unregister()
        } else {
            try? service.register()
        }
        loginItemEnabled = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Install

    private func installHelloWorld() {
        if scriptManager.scripts.contains(where: { $0.id == "hello-world" }) {
            completeOnboarding()
            return
        }

        isInstalling = true
        installError = nil

        Task {
            do {
                try await performInstall()
                isInstalling = false
                completeOnboarding()
            } catch {
                isInstalling = false
                installError = error.localizedDescription
            }
        }
    }

    @MainActor
    private func performInstall() async throws {
        if scriptCatalog.allEntries.isEmpty {
            scriptCatalog.fetch(installedScripts: scriptManager.scripts, force: true)
        }

        var fetchWaits = 0
        while scriptCatalog.isFetching, fetchWaits < 150 {
            try await Task.sleep(for: .milliseconds(200))
            fetchWaits += 1
        }

        guard let entry = scriptCatalog.allEntries.first(where: { $0.id == "hello-world" }) else {
            throw InstallError.notFound
        }

        let zipURL = try await scriptCatalog.downloadZip(for: entry)

        installer.load(zipURL: zipURL, existingScripts: scriptManager.scripts)

        var parseWaits = 0
        while installer.phase == .parsing, parseWaits < 300 {
            try await Task.sleep(for: .milliseconds(100))
            parseWaits += 1
        }

        guard installer.phase == .ready, let vault = settings.vaultPath else {
            throw InstallError.failed
        }

        installer.showSheet = false
        installer.install(to: vault, scriptManager: scriptManager)

        var installWaits = 0
        while installer.phase != .idle, installWaits < 600 {
            try await Task.sleep(for: .milliseconds(100))
            installWaits += 1
        }
    }

    private func completeOnboarding() {
        settings.hasSeenOnboarding = true
        openWindow(id: "scripts")
        dismiss()
    }

    private enum InstallError: LocalizedError {
        case notFound, failed
        var errorDescription: String? {
            switch self {
            case .notFound: return "Hello World not found in catalog. Check your internet connection and try again."
            case .failed:   return "Installation failed. Please try again."
            }
        }
    }
}

// MARK: - Permissions Step

private struct PermissionsStep: View {
    let notificationStatus: UNAuthorizationStatus
    let loginItemEnabled: Bool
    let onRequestNotifications: () -> Void
    let onToggleLoginItem: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            Text("Before we start")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(spacing: 20) {
                PermissionRow(
                    icon: "bell.fill",
                    iconColor: .orange,
                    title: "Notifications",
                    subtitle: "Get alerted when scripts complete or need your attention.",
                    hint: nil,
                    actionLabel: notificationStatus == .authorized ? "Allowed ✓" : notificationStatus == .denied ? "Open Settings" : "Allow",
                    isGranted: notificationStatus == .authorized,
                    action: onRequestNotifications
                )

                Divider()

                PermissionRow(
                    icon: "arrow.up.circle.fill",
                    iconColor: .blue,
                    title: "Launch at Login",
                    subtitle: "Start automatically when you log in so your Mac is always ready.",
                    actionLabel: loginItemEnabled ? "Enabled ✓" : "Enable",
                    isGranted: loginItemEnabled,
                    action: onToggleLoginItem
                )
            }

            HStack {
                Spacer()
                Button("Continue", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(32)
    }
}

private struct PermissionRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let hint: String?
    let actionLabel: String
    let isGranted: Bool
    let action: () -> Void

    init(icon: String, iconColor: Color, title: String, subtitle: String,
         hint: String? = nil, actionLabel: String, isGranted: Bool, action: @escaping () -> Void) {
        self.icon = icon; self.iconColor = iconColor; self.title = title
        self.subtitle = subtitle; self.hint = hint; self.actionLabel = actionLabel
        self.isGranted = isGranted; self.action = action
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 28)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).fontWeight(.medium)
                    Spacer()
                    Button(actionLabel, action: action)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isGranted)
                }
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
    }
}

// MARK: - Machine Name Step

private struct MachineNameStep: View {
    @Binding var machineName: String
    let onContinue: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Name this Mac")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("This is how your Mac appears in the Ask iPhone app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("e.g. Kevin's MacBook Pro", text: $machineName)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .focused($focused)
                    .onSubmit { if !machineName.trimmingCharacters(in: .whitespaces).isEmpty { onContinue() } }
                Text("You can change this later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Spacer()
                Button("Continue", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(machineName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(32)
        .onAppear { focused = true }
    }
}

// MARK: - Connect iPhone Step

private struct ConnectIPhoneStep: View {
    let connectedDevices: [DeviceRecord]
    let onContinue: () -> Void

    @State private var didAutoAdvance = false

    var isConnected: Bool { !connectedDevices.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect your iPhone")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Open the Ask app on your iPhone. It will find this Mac automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isConnected {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(connectedDevices, id: \.deviceID) { device in
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.deviceName)
                                    .fontWeight(.medium)
                                Text("Connected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            } else {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for iPhone…")
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button("Skip") { onContinue() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(isConnected ? "Continue" : "Skip for now", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(32)
        .onChange(of: connectedDevices.count) { _, newCount in
            guard newCount > 0, !didAutoAdvance else { return }
            didAutoAdvance = true
            // Brief pause so the user sees the "Connected" state before advancing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { onContinue() }
        }
    }
}

// MARK: - Welcome Step

private struct WelcomeStep: View {
    let isInstalling: Bool
    let installError: String?
    let onInstall: () -> Void

    var body: some View {
        VStack(spacing: 40) {
            VStack(spacing: 12) {
                Image(systemName: "icloud.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.blue)

                Text("Remote control your Mac\nwith your iPhone")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)

                Text("Create custom scripts with AI to do almost anything.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 8) {
                Button(action: onInstall) {
                    if isInstalling {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Installing…")
                        }
                        .frame(minWidth: 180)
                    } else {
                        Text("Install Hello World!")
                            .frame(minWidth: 180)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isInstalling)

                if let error = installError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
            }
        }
        .padding(40)
        .frame(minHeight: 280)
    }
}
