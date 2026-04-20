import SwiftUI

// MARK: - Permission metadata

struct ScriptPermissionInfo {
    let title: String
    let description: String
    let icon: String

    static func info(for token: String) -> ScriptPermissionInfo {
        switch token {
        case "shell":
            return ScriptPermissionInfo(
                title: "Shell",
                description: "Run commands on your Mac using bash and other shell programs.",
                icon: "terminal"
            )
        case "home_directory":
            return ScriptPermissionInfo(
                title: "Home Directory",
                description: "Read files in your home folder, including configuration files and credentials.",
                icon: "house"
            )
        case "network":
            return ScriptPermissionInfo(
                title: "Network",
                description: "Make outbound network requests to external services.",
                icon: "network"
            )
        case "applescript":
            return ScriptPermissionInfo(
                title: "AppleScript",
                description: "Control apps on your Mac using AppleScript and osascript.",
                icon: "applescript"
            )
        case "full_disk_access":
            return ScriptPermissionInfo(
                title: "Full Disk Access",
                description: "Read files anywhere on your Mac, including outside your home folder.",
                icon: "externaldrive"
            )
        default:
            return ScriptPermissionInfo(
                title: token,
                description: "Custom capability declared by this script.",
                icon: "questionmark.circle"
            )
        }
    }
}

// MARK: - Consent sheet

struct PermissionConsentView: View {
    let consent: PendingConsent
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: consent.icon ?? "terminal.fill")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(consent.scriptName) wants to use:")
                        .font(.headline)
                    Text("Review what this script can do before it runs.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // Permission rows
            VStack(spacing: 8) {
                ForEach(consent.permissions, id: \.self) { token in
                    let info = ScriptPermissionInfo.info(for: token)
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: info.icon)
                            .font(.body)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 28)
                            .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.title)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(info.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            // Caveat
            Text("Scripts run as you. Ask shows what they need but cannot sandbox them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Buttons
            HStack {
                Button("Deny", action: onDeny)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Spacer()
                Button("Allow", action: onAllow)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
