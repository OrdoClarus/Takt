import AppKit
import SwiftUI

struct MenuBarView: View {
    static let transparentMargin: CGFloat = 28

    @Environment(MetricsStore.self) private var metrics
    let openSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: Layout.sectionSpacing) {
            VStack(spacing: Layout.sectionSpacing) {
                ProcessorCard(
                    title: "CPU",
                    symbol: "cpu",
                    accentColor: .blue,
                    usage: metrics.snapshot.cpuUsage,
                    temperature: metrics.snapshot.cpuTemperature,
                    primaryRows: [
                        MetricRow(id: "cpu-power", label: "Power", value: MetricText.power(metrics.snapshot.cpuPowerWatts))
                    ],
                    coreUsages: metrics.snapshot.cpuCoreUsages,
                    performanceCoreCount: metrics.snapshot.cpuPerformanceCoreCount,
                    performanceFrequencyHz: metrics.snapshot.cpuPerformanceFrequencyHz,
                    efficiencyFrequencyHz: metrics.snapshot.cpuEfficiencyFrequencyHz,
                    processes: metrics.snapshot.topCPUProcesses
                )

                MemoryCard(
                    usage: metrics.snapshot.memoryUsage,
                    breakdown: metrics.snapshot.memoryBreakdown,
                    swapUsedBytes: metrics.snapshot.swapUsedBytes,
                    processes: metrics.snapshot.topMemoryProcesses
                )

                ProcessorCard(
                    title: "GPU",
                    symbol: "square.stack.3d.up.fill",
                    accentColor: .green,
                    usage: metrics.snapshot.gpuUsage,
                    temperature: metrics.snapshot.gpuTemperature,
                    primaryRows: [
                        MetricRow(
                            id: "gpu-frequency",
                            label: "Frequency",
                            value: MetricText.frequency(metrics.snapshot.gpuFrequencyHz)
                        ),
                        MetricRow(
                            id: "gpu-vram",
                            label: "VRAM",
                            value: MetricText.memoryPair(
                                used: metrics.snapshot.gpuMemoryUsedBytes,
                                allocated: metrics.snapshot.gpuMemoryAllocatedBytes
                            )
                        ),
                        MetricRow(
                            id: "gpu-power",
                            label: "Power",
                            value: MetricText.power(metrics.snapshot.gpuPowerWatts)
                        )
                    ],
                    coreUsages: nil,
                    performanceCoreCount: nil,
                    performanceFrequencyHz: nil,
                    efficiencyFrequencyHz: nil,
                    processes: nil
                )

                SystemCard(
                    snapshot: metrics.snapshot,
                    networkIdentity: metrics.networkIdentity,
                    openSettings: openSettings,
                    quit: quit
                )
            }
        }
        .padding(Layout.panelPadding)
        .frame(width: Layout.panelWidth)
                .padding(Self.transparentMargin)
    }
}

private enum Layout {
    static let panelWidth: CGFloat = 460
    static let panelPadding: CGFloat = 10
    static let sectionSpacing: CGFloat = 7
    static let cardPadding: CGFloat = 12
    static let controlEdgeInset: CGFloat = 5
    static let cardCornerRadius: CGFloat = 22
    static let resourceCardGlassTint = NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
        case .darkAqua:
            return .black.withAlphaComponent(0.18)
        default:
            return .black.withAlphaComponent(0.10)
        }
    }
    static let lightCardGlassTintOpacity: CGFloat = 0.06
    static let darkCardGlassTintOpacity: CGFloat = 0.01
    static let cardGlassTint = NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [.darkAqua, .aqua]) {
        case .darkAqua:
            return .white.withAlphaComponent(darkCardGlassTintOpacity)
        default:
            return .black.withAlphaComponent(lightCardGlassTintOpacity)
        }
    }
    static let resourceCardHeight: CGFloat = 155
    static let systemCardHeight: CGFloat = 252
    static let chartColumnWidth: CGFloat = 140
    static let chartSize: CGFloat = 82
}

private struct MetricRow: Identifiable {
    let id: String
    let label: LocalizedStringKey
    let value: String
}

private struct ProcessorCard: View {
    let title: String
    let symbol: String
    let accentColor: Color
    let usage: Double?
    let temperature: Double?
    let primaryRows: [MetricRow]
    let coreUsages: [Double]?
    let performanceCoreCount: Int?
    let performanceFrequencyHz: UInt64?
    let efficiencyFrequencyHz: UInt64?
    let processes: [ProcessUsage]?

    var body: some View {
        ResourceCard {
            ResourceChartColumn(
                title: title,
                symbol: symbol,
                accentColor: accentColor,
                usage: usage,
                temperature: temperature
            )

            CardDivider()

            DiagnosticColumn(
                rows: primaryRows,
                listTitle: processes == nil ? nil : "TOP PROCESSES",
                coreUsages: coreUsages,
                performanceCoreCount: performanceCoreCount,
                performanceFrequencyHz: performanceFrequencyHz,
                efficiencyFrequencyHz: efficiencyFrequencyHz,
                processes: processes ?? []
            )
        }
    }
}

private struct MemoryCard: View {
    let usage: Double?
    let breakdown: MemoryBreakdown?
    let swapUsedBytes: UInt64?
    let processes: [ProcessUsage]

    var body: some View {
        ResourceCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("RAM")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .frame(width: Layout.chartSize, alignment: .center)
                    .offset(x: 5)
                UsageGauge(
                    symbol: "memorychip.fill",
                    accentColor: .orange,
                    usage: usage
                )
                .offset(x: 5)
            }
            .frame(width: Layout.chartColumnWidth, alignment: .leading)

            CardDivider()

            DiagnosticColumn(
                rows: MemoryRows.rows(breakdown: breakdown, swapUsedBytes: swapUsedBytes),
                listTitle: "TOP APPLICATIONS",
                coreUsages: nil,
                performanceCoreCount: nil,
                performanceFrequencyHz: nil,
                efficiencyFrequencyHz: nil,
                processes: processes
            )
        }
    }
}

private struct ResourceCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        AppKitGlassEffect(
            cornerRadius: Layout.cardCornerRadius,
            tintColor: Layout.resourceCardGlassTint,
            isInteractive: true
        ) {
            HStack(alignment: .center, spacing: 9) {
                content
            }
            .padding(Layout.cardPadding)
            .frame(maxWidth: .infinity, minHeight: Layout.resourceCardHeight, maxHeight: Layout.resourceCardHeight)
                    }
        .overlay {
            RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.20),
                            .white.opacity(0.07),
                            .black.opacity(0.18)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.24), radius: 8, y: 4)
        .frame(maxWidth: .infinity, minHeight: Layout.resourceCardHeight, maxHeight: Layout.resourceCardHeight)
    }
}

private struct ResourceChartColumn: View {
    let title: String
    let symbol: String
    let accentColor: Color
    let usage: Double?
    let temperature: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .frame(width: Layout.chartSize, alignment: .center)
                .offset(x: 5)

            HStack(alignment: .center, spacing: 13) {
                UsageGauge(
                    symbol: symbol,
                    accentColor: accentColor,
                    usage: usage
                )
                .offset(x: 5)
                TemperatureGauge(value: temperature)
            }
        }
        .frame(width: Layout.chartColumnWidth, alignment: .leading)
    }
}

private struct UsageGauge: View {
    let symbol: String
    let accentColor: Color
    let usage: Double?

    private var normalizedUsage: Double {
        usage?.clampedToUnitInterval ?? 0
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.10))

            Circle()
                .stroke(.secondary.opacity(0.22), lineWidth: 5)

            Circle()
                .trim(from: 0, to: normalizedUsage)
                .stroke(
                    accentColor,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: accentColor.opacity(0.34), radius: 3)

            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(MetricText.percentage(usage))
                    .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
            }
        }
        .frame(width: Layout.chartSize, height: Layout.chartSize)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Usage")
        .accessibilityValue(MetricText.percentage(usage))
    }
}

private struct TemperatureGauge: View {
    let value: Double?

    private var symbolName: String {
        guard let value else { return "thermometer.low" }
        if value >= 75 {
            return "thermometer.high"
        }
        if value >= 55 {
            return "thermometer.medium"
        }
        return "thermometer.low"
    }

    private var fillColor: Color {
        guard let value else { return .secondary }
        return value >= 85 ? .red : .blue
    }

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: symbolName)
                .font(.system(size: 25, weight: .regular))
                .symbolRenderingMode(.palette)
                .foregroundStyle(fillColor, .primary)
                .frame(width: 20, height: 43)

            Text(value.map { "\(Int($0.rounded()))°" } ?? "N/A")
                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                .frame(minWidth: 38)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Temperature")
        .accessibilityValue(MetricText.temperature(value))
    }
}

private struct CardDivider: View {
    var body: some View {
        Divider()
            .frame(height: 94)
    }
}

private struct DiagnosticColumn: View {
    let rows: [MetricRow]
    let listTitle: LocalizedStringKey?
    let coreUsages: [Double]?
    let performanceCoreCount: Int?
    let performanceFrequencyHz: UInt64?
    let efficiencyFrequencyHz: UInt64?
    let processes: [ProcessUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows.prefix(4)) { row in
                DataRow(title: row.label, value: row.value)
            }

            if let coreUsages {
                CoreUsageStrip(
                    usages: coreUsages,
                    performanceCoreCount: performanceCoreCount ?? coreUsages.count,
                    performanceFrequencyHz: performanceFrequencyHz,
                    efficiencyFrequencyHz: efficiencyFrequencyHz
                )
            }

            if let listTitle {
                Divider()

                Text(listTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)

                VStack(spacing: 1) {
                    ForEach(0..<3, id: \.self) { index in
                        ProcessItem(
                            index: index + 1,
                            process: index < processes.count ? processes[index] : nil
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CoreUsageStrip: View {
    let usages: [Double]
    let performanceCoreCount: Int
    let performanceFrequencyHz: UInt64?
    let efficiencyFrequencyHz: UInt64?

    var body: some View {
        let splitIndex = min(max(performanceCoreCount, 0), usages.count)
        let performanceUsages = Array(usages.prefix(splitIndex))
        let efficiencyUsages = Array(usages.dropFirst(splitIndex))

        HStack(alignment: .bottom, spacing: 6) {
            CoreBarGroup(
                title: efficiencyUsages.isEmpty ? "Cores" : "P-cores",
                frequencyHz: performanceFrequencyHz,
                usages: performanceUsages
            )

            if !efficiencyUsages.isEmpty {
                Divider()
                    .frame(height: 22)

                CoreBarGroup(
                    title: "E-cores",
                    frequencyHz: efficiencyFrequencyHz,
                    usages: efficiencyUsages
                )
            }
        }
        .frame(height: 27, alignment: .bottom)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("CPU core usage")
    }
}

private struct CoreBarGroup: View {
    let title: String
    let frequencyHz: UInt64?
    let usages: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(title)
                Text(MetricText.frequency(frequencyHz))
                    .monospacedDigit()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(usages.enumerated()), id: \.offset) { _, usage in
                    Capsule()
                        .fill(.secondary.opacity(0.16))
                        .frame(width: 12, height: 15)
                        .overlay(alignment: .bottom) {
                            Capsule()
                                .fill(.cyan)
                                .frame(height: max(2, 15 * usage.clampedToUnitInterval))
                        }
                }
            }
        }
    }
}

private enum MemoryRows {
    static func rows(breakdown: MemoryBreakdown?, swapUsedBytes: UInt64?) -> [MetricRow] {
        [
            MetricRow(id: "ram-used", label: "Used", value: MetricText.gigabytes(breakdown?.usedBytes)),
            MetricRow(id: "ram-free", label: "Free", value: MetricText.gigabytes(breakdown?.freeBytes)),
            MetricRow(id: "ram-swap", label: "Swap", value: MetricText.gigabytes(swapUsedBytes))
        ]
    }
}

private struct DataRow: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.callout)
    }
}

private struct ProcessItem: View {
    let index: Int
    let process: ProcessUsage?

    private var applicationIcon: NSImage? {
        guard let process else {
            return nil
        }
        return NSRunningApplication(processIdentifier: process.pid)?.icon
    }

    var body: some View {
        HStack(spacing: 7) {
            if let applicationIcon {
                Image(nsImage: applicationIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.tertiary)
            }

            Text("\(index)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 10, alignment: .trailing)

            Text(process?.name ?? "—")
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)

            Spacer(minLength: 6)

            if let process {
                if let memoryBytes = process.memoryBytes {
                    Text(MetricText.bytes(memoryBytes))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                } else {
                    Text(
                        process.usage,
                        format: .percent.precision(
                            .fractionLength(process.usage < 0.01 ? 2 : process.usage < 0.1 ? 1 : 0)
                        )
                    )
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
            } else {
                Text("—")
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, minHeight: 18)
        .accessibilityElement(children: .combine)
    }
}

private struct SystemCard: View {
    let snapshot: SystemSnapshot
    let networkIdentity: NetworkIdentity?
    let openSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        AppKitGlassEffect(
            cornerRadius: Layout.cardCornerRadius,
            tintColor: Layout.cardGlassTint,
            isInteractive: true
        ) {
            VStack(spacing: 9) {
                CoolingSection(fans: snapshot.fans)
                Divider()
                NetworkSection(
                    download: snapshot.networkDownloadBytesPerSecond,
                    upload: snapshot.networkUploadBytesPerSecond,
                    identity: networkIdentity
                )
                Divider()
                DiskSection(disk: snapshot.disk)
                Spacer(minLength: 48)
            }
            .padding(Layout.cardPadding)
            .frame(maxWidth: .infinity, minHeight: Layout.systemCardHeight, maxHeight: Layout.systemCardHeight)
                    }
        .frame(maxWidth: .infinity, minHeight: Layout.systemCardHeight, maxHeight: Layout.systemCardHeight)
        .overlay(alignment: .bottom) {
            ControlBar(openSettings: openSettings, quit: quit)
                .padding(.horizontal, Layout.controlEdgeInset)
                .padding(.bottom, Layout.controlEdgeInset)
        }
    }
}

private struct CoolingSection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let fans: [FanReading]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "fan")
                .font(.system(size: 30))
                .foregroundStyle(.cyan)
                .frame(width: 42, height: 42, alignment: .center)
                .symbolEffect(
                    .rotate,
                    isActive: !reduceMotion && fans.contains { $0.currentRPM > 0 }
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                FanRow(index: 0, fans: fans)
                FanRow(index: 1, fans: fans)
            }
            .frame(height: 42, alignment: .center)

            Spacer()
        }
    }
}

private struct FanRow: View {
    let index: Int
    let fans: [FanReading]

    var body: some View {
        HStack(spacing: 12) {
            Text("Fan \(index + 1)")
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            Text(index < fans.count ? "\(fans[index].currentRPM) RPM" : "N/A")
                .fontWeight(.medium)
                .monospacedDigit()
                .frame(width: 70, alignment: .leading)
        }
        .font(.callout)
    }
}

private struct NetworkSection: View {
    let download: Double?
    let upload: Double?
    let identity: NetworkIdentity?

    private var ipAddressText: String {
        "IP \(identity?.ipAddress ?? "N/A")"
    }

    private var countryFlag: String {
        identity?.countryFlag ?? "🌐"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "network")
                .foregroundStyle(.cyan)
                .frame(width: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text("INTERNET")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)

                HStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Label(MetricText.byteRate(download), systemImage: "arrow.down")
                        Label(MetricText.byteRate(upload), systemImage: "arrow.up")
                    }
                    .font(.callout.monospacedDigit())
                    .frame(width: 142, alignment: .leading)

                    Spacer(minLength: 4)

                    HStack(spacing: 4) {
                        Text(ipAddressText)
                            .font(.callout.monospacedDigit())
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(countryFlag)
                            .font(.callout)
                            .fixedSize()
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct DiskSection: View {
    let disk: DiskReading?

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Label(disk?.name ?? "DISK", systemImage: "internaldrive.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(MetricText.percentage(disk?.usage))
                    .font(.callout.weight(.medium).monospacedDigit())
            }

            ProgressView(value: disk?.usage ?? 0)
                .tint((disk?.usage ?? 0) >= 0.9 ? .red : .cyan)

            HStack(spacing: 10) {
                DiskValue(label: "Total", value: disk.map { MetricText.bytes($0.totalBytes) } ?? "N/A")
                DiskValue(label: "Used", value: disk.map { MetricText.bytes($0.usedBytes) } ?? "N/A")
                DiskValue(label: "Free", value: disk.map { MetricText.bytes($0.freeBytes) } ?? "N/A")
            }
        }
    }
}

private struct DiskValue: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .foregroundStyle(.tertiary)
            Text(value)
                .monospacedDigit()
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ControlBar: View {
    let openSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        HStack {
            RoundActionButton(
                symbol: "gearshape.fill",
                help: "Settings"
            ) {
                openSettings()
                NSApplication.shared.activate()
            }

            Spacer()

            RoundActionButton(
                symbol: "power",
                help: "Quit Takt"
            ) {
                quit()
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct RoundActionButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(help, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(width: 48, height: 48)
            .buttonStyle(.glass(.clear))
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .tint(.clear)
            .help(help)
    }
}

private enum MetricText {
    static func percentage(_ value: Double?) -> String {
        guard let value else { return "N/A" }
        return "\(Int((value.clampedToUnitInterval * 100).rounded()))%"
    }

    static func temperature(_ value: Double?) -> String {
        guard let value else { return "N/A" }
        return "\(Int(value.rounded())) °C"
    }

    static func memoryUsed(_ usage: Double?) -> String {
        guard let usage else { return "N/A" }
        let used = Double(ProcessInfo.processInfo.physicalMemory) * usage.clampedToUnitInterval
        return bytes(UInt64(used))
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    static func gigabytes(_ value: UInt64?) -> String {
        guard let value else { return "N/A" }
        let gigabytes = Double(value) / 1_073_741_824
        return gigabytes.formatted(.number.precision(.fractionLength(1))) + " GB"
    }

    static func memoryPair(used: UInt64?, allocated: UInt64?) -> String {
        guard let used, let allocated else { return "N/A" }
        return "\(bytes(used)) / \(bytes(allocated))"
    }

    static func frequency(_ value: UInt64?) -> String {
        guard let value else { return "N/A" }
        let gigahertz = Double(value) / 1_000_000_000
        return gigahertz.formatted(.number.precision(.fractionLength(1))) + " GHz"
    }

    static func power(_ value: Double?) -> String {
        guard let value else { return "N/A" }
        return value.formatted(.number.precision(.fractionLength(1))) + " W"
    }

    static func byteRate(_ value: Double?) -> String {
        guard let value else { return "N/A" }
        return ByteCountFormatter.string(
            fromByteCount: Int64(max(value, 0)),
            countStyle: .file
        ) + "/s"
    }
}

private extension Double {
    var clampedToUnitInterval: Double {
        min(max(self, 0), 1)
    }
}

#Preview {
    MenuBarView(openSettings: {}, quit: {})
        .environment(MetricsStore())
}
