import SwiftUI

/// 连接表视图。展示当前活跃 + 最近结束的代理连接，含目标、出口动作、字节统计、全局流量汇总。
/// 数据来自 ConnectionTracker（后台采集，主线程 @Published）。
struct ConnectionsTabView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var tracker = ConnectionTracker.shared
    @State private var showActiveOnly = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolbar
            Divider()
            list
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 顶部：全局流量统计 + 活跃连接数。
    private var header: some View {
        HStack(spacing: 24) {
            statItem(
                label: "Total Upload",
                value: ByteFormatter.string(from: tracker.totalBytesSent),
                systemImage: "arrow.up.circle.fill",
                color: .blue
            )
            statItem(
                label: "Total Download",
                value: ByteFormatter.string(from: tracker.totalBytesReceived),
                systemImage: "arrow.down.circle.fill",
                color: .green
            )
            statItem(
                label: "Active",
                value: "\(activeCount)",
                systemImage: "bolt.circle.fill",
                color: activeCount > 0 ? .orange : .secondary
            )
            Spacer()
        }
        .padding()
    }

    /// 工具栏：过滤开关 + 手动清理按钮。
    private var toolbar: some View {
        HStack {
            Toggle("Active only", isOn: $showActiveOnly)
                .toggleStyle(.checkbox)
                .font(.caption)
            Spacer()
            Text("\(filteredRecords.count) of \(tracker.records.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                ConnectionTracker.shared.removeClosed()
            } label: {
                Label("Clear closed", systemImage: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(!tracker.records.contains { !$0.isActive })
            .help("Remove all closed connections")
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    /// 连接列表。
    private var list: some View {
        Group {
            if filteredRecords.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text(appState.isRunning ? "No connections yet" : "Proxy is not running")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(filteredRecords) {
                    TableColumn("Host") { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.host)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(record.port)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 120, ideal: 200)

                    TableColumn("Outbound") { record in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(color(for: record.action))
                                .frame(width: 8, height: 8)
                            Text(record.action.label)
                                .font(.caption)
                        }
                    }
                    .width(80)

                    TableColumn("Reason") { record in
                        Text(record.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .width(min: 80, ideal: 140)

                    TableColumn("↑ Sent") { record in
                        Text(ByteFormatter.string(from: record.bytesSent))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.blue)
                    }
                    .width(70)

                    TableColumn("↓ Received") { record in
                        Text(ByteFormatter.string(from: record.bytesReceived))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.green)
                    }
                    .width(70)

                    TableColumn("Status") { record in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(record.isActive ? Color.green : Color.secondary)
                                .frame(width: 6, height: 6)
                            Text(record.isActive ? "active" : "closed")
                                .font(.caption2)
                                .foregroundStyle(record.isActive ? .green : .secondary)
                        }
                    }
                    .width(60)
                }
            }
        }
    }

    private var filteredRecords: [ConnectionRecord] {
        showActiveOnly ? tracker.records.filter { $0.isActive } : tracker.records
    }

    private var activeCount: Int {
        tracker.records.filter { $0.isActive }.count
    }

    private func color(for action: RuleAction) -> Color {
        switch action {
        case .proxy: return .blue
        case .direct: return .green
        case .block: return .red
        }
    }

    private func statItem(label: String, value: String, systemImage: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(color)
                    .font(.caption)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.title3, design: .monospaced).weight(.medium))
        }
    }
}

/// 字节数格式化工具。1024 进制，保留 1 位小数。
enum ByteFormatter {
    static func string(from bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let units: [(Double, String)] = [
            (1024 * 1024 * 1024 * 1024, "TB"),
            (1024 * 1024 * 1024, "GB"),
            (1024 * 1024, "MB"),
            (1024, "KB")
        ]
        let value = Double(bytes)
        for (threshold, suffix) in units where value >= threshold {
            return String(format: "%.1f %@", value / threshold, suffix)
        }
        return "\(bytes) B"
    }
}
