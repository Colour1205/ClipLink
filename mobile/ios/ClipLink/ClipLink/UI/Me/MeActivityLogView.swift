import SwiftUI

/// Me › Activity Log: the engine's recent events, newest first.
struct MeActivityLogView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    /// The engine already keeps the log newest first.
    private var lines: [LogLine] { model.snapshot.log }

    var body: some View {
        content
            .navigationTitle("Activity Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            model.clipboard.copyText(exportText)
                            model.showToast("Activity log copied.")
                            Haptics.tap(settings.haptics)
                        } label: {
                            Label("Copy All", systemImage: "doc.on.doc")
                        }
                        Button {
                            // From UIKit, like every other Share in the app: a
                            // SwiftUI sheet stretches it full height on iOS 15.
                            SyncedShareSheet.share([exportText])
                        } label: {
                            Label("Share…", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .accessibilityLabel("More")
                    }
                    .disabled(lines.isEmpty)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if lines.isEmpty {
            ScrollView {
                EmptyStateView(
                    systemImage: "list.bullet.rectangle",
                    title: "Nothing logged yet.",
                    message: "Connections, pairing and sync events will appear here."
                )
                .padding(.top, 40)
            }
            .background(PageBackground(glow: settings.bottomGlow, accent: settings.accentTheme.color).ignoresSafeArea())
        } else {
            List {
                Section {
                    ForEach(lines) { line in
                        MeLogRow(line: line, accent: settings.accentTheme.color)
                            .meRow(transparency: settings.cardTransparency)
                    }
                } footer: {
                    Text("Kept on this iPhone only. Older events drop off as new ones arrive.")
                }
            }
            .mePage(glow: settings.bottomGlow, accent: settings.accentTheme.color)
            .tint(settings.accentTheme.color)
        }
    }

    private var exportText: String {
        lines.map { "\(MeFormat.logTime.string(from: $0.date))  \($0.message)" }.joined(separator: "\n")
    }
}

private struct MeLogRow: View {
    let line: LogLine
    let accent: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(MeFormat.logTime.string(from: line.date))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(accent)
            Text(line.message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(TimeLabel.full(line.date)), \(line.message)")
    }
}
