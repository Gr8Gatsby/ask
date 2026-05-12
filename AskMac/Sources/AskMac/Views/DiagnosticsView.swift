import SwiftUI

struct DiagnosticsView: View {
    @Environment(DiagnosticsService.self) private var diagnostics
    @State private var copyToast: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            content
        }
        .frame(minWidth: 720, minHeight: 480)
        .task { if diagnostics.report == nil { await diagnostics.runAll() } }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "stethoscope")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("AskMac Diagnostics").font(.headline)
                if let report = diagnostics.report {
                    Text("Last run \(report.runAt, format: .dateTime.hour().minute().second()) · \(summaryCounts)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Not yet run").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let toast = copyToast {
                Text(toast).font(.caption).foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Button {
                Task { await diagnostics.runAll() }
            } label: {
                if diagnostics.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Re-run", systemImage: "arrow.clockwise")
                }
            }
            .disabled(diagnostics.isRunning)

            Button {
                diagnostics.copyMarkdownToClipboard()
                withAnimation(.easeOut(duration: 0.2)) {
                    copyToast = "Copied as markdown"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation(.easeIn(duration: 0.3)) { copyToast = nil }
                }
            } label: {
                Label("Copy report", systemImage: "doc.on.doc")
            }
            .disabled(diagnostics.report == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var summaryCounts: String {
        guard let report = diagnostics.report else { return "" }
        var fail = 0, warn = 0, ok = 0
        for sec in report.sections {
            for d in sec.diagnostics {
                switch d.status {
                case .fail:    fail += 1
                case .warning: warn += 1
                case .ok:      ok += 1
                case .info:    break
                }
            }
        }
        return "\(ok) ok · \(warn) warn · \(fail) fail"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if diagnostics.isRunning && diagnostics.report == nil {
            VStack(spacing: 12) {
                ProgressView()
                Text("Running checks…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let report = diagnostics.report {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(report.sections) { section in
                        sectionView(section)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        } else {
            VStack(spacing: 8) {
                Text("Tap Re-run to begin").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: DiagnosticSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(section.diagnostics) { d in
                    DiagnosticRow(diagnostic: d)
                }
            }
            .padding(10)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct DiagnosticRow: View {
    let diagnostic: Diagnostic
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(diagnostic.status.symbol)
                    .font(.body)
                    .frame(width: 18, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(diagnostic.label).font(.callout).fontWeight(.medium)
                    if !diagnostic.detail.isEmpty {
                        Text(displayDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(expanded ? nil : 3)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                if isExpandable {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let fix = diagnostic.fixHint, expanded || !isExpandable {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Fix:").font(.caption2).fontWeight(.semibold).foregroundStyle(.orange)
                    Text(fix).font(.caption2).foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
                .padding(.leading, 26)
            }
        }
    }

    private var isExpandable: Bool {
        let multiline = diagnostic.detail.contains("\n")
        return multiline || diagnostic.detail.count > 200
    }

    private var displayDetail: String {
        diagnostic.detail
    }
}
