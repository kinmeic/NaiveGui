import SwiftUI

struct LogViewerView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var autoScroll = true

    private var filteredLines: [LogCaptureService.LogLine] {
        if searchText.isEmpty {
            return appState.logCapture.lines
        }
        return appState.logCapture.lines.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                TextField("Search logs...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)

                Spacer()

                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)

                Button("Clear") {
                    appState.logCapture.clear()
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // Log content
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filteredLines) { line in
                            HStack(spacing: 4) {
                                Text(timeFormatter.string(from: line.timestamp))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 70, alignment: .trailing)

                                Text(line.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(colorForLevel(line.level))
                                    .textSelection(.enabled)
                            }
                            .id(line.id)
                            .padding(.horizontal, 4)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: filteredLines.count) { _ in
                    if autoScroll, let last = filteredLines.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func colorForLevel(_ level: LogCaptureService.LogLevel) -> Color {
        switch level {
        case .error: return .red
        case .warning: return .orange
        case .info: return .primary
        }
    }

    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }
}
