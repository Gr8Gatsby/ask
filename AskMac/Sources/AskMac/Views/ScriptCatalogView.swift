#if canImport(AskMacCore)
import AskMacCore
#endif
import AppKit
import SwiftUI

// MARK: - Script catalog browser

struct ScriptCatalogView: View {
    @Bindable var installer: ScriptInstaller
    @Environment(ScriptCatalogService.self) private var catalog
    @Environment(ScriptManager.self) private var scriptManager
    @Environment(AppSettings.self) private var settings

    @State private var searchText = ""
    @State private var downloadingID: String?
    @State private var downloadErrors: [String: String] = [:]
    @State private var showInstalled = false

    private var filteredEntries: [CatalogEntry] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return catalog.allEntries }
        return catalog.allEntries.filter {
            $0.name.lowercased().contains(q) ||
            $0.description.lowercased().contains(q) ||
            $0.id.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.body)
                TextField("Search scripts…", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            if catalog.isFetching && catalog.allEntries.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading catalog…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if catalog.allEntries.isEmpty {
                ContentUnavailableView(
                    "Catalog Unavailable",
                    systemImage: "wifi.slash",
                    description: Text("Could not load the script catalog.\nCheck your internet connection and try again.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredEntries.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: []) {
                        // Available: scripts with updates or not yet installed
                        let available = filteredEntries.filter { entry in
                            catalog.availableUpdates[entry.id] != nil ||
                            !scriptManager.scripts.contains(where: { $0.id == entry.id })
                        }
                        let installed = filteredEntries.filter { entry in
                            catalog.availableUpdates[entry.id] == nil &&
                            scriptManager.scripts.contains(where: { $0.id == entry.id })
                        }

                        ForEach(available) { entry in
                            let installedScript = scriptManager.scripts.first(where: { $0.id == entry.id })
                            CatalogEntryRow(
                                entry: entry,
                                installer: installer,
                                isInstalled: installedScript != nil,
                                hasUpdate: catalog.availableUpdates[entry.id] != nil,
                                isDownloading: downloadingID == entry.id,
                                downloadError: downloadErrors[entry.id],
                                installedScript: installedScript
                            ) {
                                startInstall(entry: entry)
                            }
                            Divider().padding(.leading, 52)
                        }

                        // Local scripts: in vault but not in the catalog at all
                        let localScripts = scriptManager.scripts.filter { s in
                            !catalog.allEntries.contains(where: { $0.id == s.id })
                        }

                        let totalInstalled = installed.count + localScripts.count
                        if totalInstalled > 0 {
                            DisclosureGroup(isExpanded: $showInstalled) {
                                ForEach(installed) { entry in
                                    let installedScript = scriptManager.scripts.first(where: { $0.id == entry.id })
                                    CatalogEntryRow(
                                        entry: entry,
                                        installer: installer,
                                        isInstalled: true,
                                        hasUpdate: false,
                                        isDownloading: false,
                                        downloadError: nil,
                                        installedScript: installedScript,
                                        isLocal: false
                                    ) {
                                        startInstall(entry: entry)
                                    }
                                    Divider().padding(.leading, 52)
                                }
                                ForEach(localScripts) { script in
                                    LocalScriptRow(script: script)
                                    Divider().padding(.leading, 52)
                                }
                            } label: {
                                HStack {
                                    Text("Installed")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.secondary)
                                    Text("(\(totalInstalled))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                            }
                            .padding(.leading, 16)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Browse Scripts")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    catalog.fetch(installedScripts: scriptManager.scripts, force: true)
                } label: {
                    if catalog.isFetching {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(catalog.isFetching)
                .help("Refresh catalog")
            }
        }
        .sheet(isPresented: $installer.showSheet) {
            ScriptInstallSheet(
                installer: installer,
                scriptManager: scriptManager,
                vaultURL: settings.vaultPath ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".ask/scripts")
            )
        }
    }

    private func startInstall(entry: CatalogEntry) {
        downloadingID = entry.id
        downloadErrors.removeValue(forKey: entry.id)
        Task {
            do {
                let zipURL = try await catalog.downloadZip(for: entry)
                await MainActor.run {
                    downloadingID = nil
                    installer.load(zipURL: zipURL, existingScripts: scriptManager.scripts)
                }
            } catch {
                await MainActor.run {
                    downloadingID = nil
                    downloadErrors[entry.id] = error.localizedDescription
                }
            }
        }
    }
}

struct LocalScriptRow: View {
    let script: ManagedScript

    @Environment(ScriptManager.self) private var scriptManager
    @State private var showUninstallConfirm = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let img = script.iconImage {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .grayscale(0.6)
                        .opacity(0.5)
                } else {
                    Image(systemName: script.icon ?? "shippingbox")
                        .font(.title2)
                        .foregroundStyle(Color.secondary.opacity(0.4))
                }
            }
            .frame(width: 36, height: 36)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(script.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .opacity(0.4)
                    localTypeBadge
                }
                if let desc = script.description {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .opacity(0.4)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                Text("Local")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
                Button {
                    showUninstallConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Uninstall script")
                .confirmationDialog("Uninstall \(script.name)?", isPresented: $showUninstallConfirm, titleVisibility: .visible) {
                    Button("Uninstall", role: .destructive) {
                        scriptManager.uninstallScript(id: script.id)
                    }
                } message: {
                    Text("The script folder will be moved to the Trash.")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var localTypeBadge: some View {
        let (label, color): (String, Color) = {
            switch script.scriptType {
            case "feed":   return ("Feed",   .purple)
            case "system": return ("System", .gray)
            default:       return ("Tile",   .blue)
            }
        }()
        return Text(label)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(color.opacity(0.5))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.08))
            .clipShape(Capsule())
    }
}

struct CatalogEntryRow: View {
    let entry: CatalogEntry
    let installer: ScriptInstaller
    let isInstalled: Bool
    let hasUpdate: Bool
    let isDownloading: Bool
    let downloadError: String?
    let installedScript: ManagedScript?
    var isLocal: Bool = false
    let onInstall: () -> Void

    @Environment(ScriptManager.self) private var scriptManager
    @State private var showUninstallConfirm = false

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Group {
                if let img = installedScript?.iconImage {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .grayscale(isInstalled && !hasUpdate ? 0.6 : 0)
                        .opacity(isInstalled && !hasUpdate ? 0.5 : 1)
                } else {
                    Image(systemName: "shippingbox")
                        .font(.title2)
                        .foregroundStyle(isInstalled && !hasUpdate ? Color.secondary.opacity(0.4) : .secondary)
                }
            }
            .frame(width: 36, height: 36)
            .background(Color.secondary.opacity(isInstalled && !hasUpdate ? 0.06 : 0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .opacity(isInstalled && !hasUpdate ? 0.4 : 1)
                    typeBadge
                }
                Text(entry.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .opacity(isInstalled && !hasUpdate ? 0.4 : 1)
                if let err = downloadError {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Action button
            Group {
                if isDownloading {
                    ProgressView().controlSize(.small)
                        .frame(width: 64)
                } else if hasUpdate {
                    Button("Update", action: onInstall)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else if isInstalled {
                    HStack(spacing: 6) {
                        Text("Installed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(Capsule())
                        Button {
                            showUninstallConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Uninstall script")
                        .confirmationDialog("Uninstall \(entry.name)?", isPresented: $showUninstallConfirm, titleVisibility: .visible) {
                            Button("Uninstall", role: .destructive) {
                                scriptManager.uninstallScript(id: entry.id)
                            }
                        } message: {
                            Text("The script folder will be moved to the Trash.")
                        }
                    }
                } else {
                    Button("Install", action: onInstall)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(installer.phase != .idle)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var typeBadge: some View {
        let (label, color): (String, Color) = {
            switch entry.type {
            case "feed":   return ("Feed",   .purple)
            case "system": return ("System", .gray)
            default:       return ("Tile",   .blue)
            }
        }()
        return Text(label)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}
