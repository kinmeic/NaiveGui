import SwiftUI

struct LogViewerView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var logCapture = LogCaptureService.shared
    @State private var searchText = ""
    @State private var autoScroll = true
    @State private var showNaive = true
    @State private var showSingbox = true

    private var filteredLines: [LogCaptureService.LogLine] {
        var lines = logCapture.lines
        if !showNaive {
            lines = lines.filter { !$0.text.hasPrefix("[naive]") }
        }
        if !showSingbox {
            lines = lines.filter { !$0.text.hasPrefix("[sing-box]") }
        }
        if !searchText.isEmpty {
            lines = lines.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
        }
        return lines
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search logs...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)

                Spacer()

                Toggle("naive", isOn: $showNaive)
                    .toggleStyle(.checkbox)
                Toggle("sing-box", isOn: $showSingbox)
                    .toggleStyle(.checkbox)

                Divider()
                    .frame(height: 16)

                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)

                Button("Clear") {
                    logCapture.clear()
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

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
                .onChange(of: logCapture.lines.count) { _ in
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
