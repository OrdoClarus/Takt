import Darwin
import Foundation
import Observation

struct MemoryBreakdown: Sendable {
    let wiredBytes: UInt64
    let activeBytes: UInt64
    let compressedBytes: UInt64
    let freeBytes: UInt64

    nonisolated var usedBytes: UInt64 {
        activeBytes &+ wiredBytes &+ compressedBytes
    }
}

struct DiskReading: Sendable {
    let name: String
    let totalBytes: UInt64
    let usedBytes: UInt64
    let freeBytes: UInt64

    nonisolated var usage: Double {
        guard totalBytes > 0 else { return 0 }
        return min(Double(usedBytes) / Double(totalBytes), 1)
    }
}

struct SystemSnapshot: Sendable {
    let cpuUsage: Double?
    let cpuCoreUsages: [Double]
    let cpuPerformanceCoreCount: Int
    let cpuPerformanceFrequencyHz: UInt64?
    let cpuEfficiencyFrequencyHz: UInt64?
    let cpuPowerWatts: Double?
    let gpuUsage: Double?
    let gpuFrequencyHz: UInt64?
    let gpuMemoryUsedBytes: UInt64?
    let gpuMemoryAllocatedBytes: UInt64?
    let gpuPowerWatts: Double?
    let memoryUsage: Double?
    let memoryBreakdown: MemoryBreakdown?
    let swapUsedBytes: UInt64?
    let diskUsage: Double?
    let disk: DiskReading?
    let cpuTemperature: Double?
    let gpuTemperature: Double?
    let fans: [FanReading]
    let networkDownloadBytesPerSecond: Double?
    let networkUploadBytesPerSecond: Double?
    let topCPUProcesses: [ProcessUsage]
    let topMemoryProcesses: [ProcessUsage]

    static let unavailable = SystemSnapshot(
        cpuUsage: nil,
        cpuCoreUsages: [],
        cpuPerformanceCoreCount: 0,
        cpuPerformanceFrequencyHz: nil,
        cpuEfficiencyFrequencyHz: nil,
        cpuPowerWatts: nil,
        gpuUsage: nil,
        gpuFrequencyHz: nil,
        gpuMemoryUsedBytes: nil,
        gpuMemoryAllocatedBytes: nil,
        gpuPowerWatts: nil,
        memoryUsage: nil,
        memoryBreakdown: nil,
        swapUsedBytes: nil,
        diskUsage: nil,
        disk: nil,
        cpuTemperature: nil,
        gpuTemperature: nil,
        fans: [],
        networkDownloadBytesPerSecond: nil,
        networkUploadBytesPerSecond: nil,
        topCPUProcesses: [],
        topMemoryProcesses: []
    )
}

@MainActor
@Observable
final class MetricsStore {
    private(set) var snapshot = SystemSnapshot.unavailable
    private(set) var networkIdentity: NetworkIdentity?
    private let sampler = SystemMetricsSampler()
    private var monitoringTask: Task<Void, Never>?
    private var networkIdentityTask: Task<Void, Never>?

    func startMonitoring() {
        guard networkIdentityTask == nil, networkIdentity == nil else { return }
        networkIdentityTask = Task { [weak self] in
            let identity = await NetworkIdentityService.fetch()
            guard !Task.isCancelled else {
                return
            }
            self?.networkIdentity = identity
            self?.networkIdentityTask = nil
        }
    }

    func resumeMonitoring() {
        guard monitoringTask == nil else { return }
        monitoringTask = Task { [weak self] in
            var isFirstSample = true
            while !Task.isCancelled {
                guard let self else {
                    return
                }

                snapshot = await sampler.sample(forceSlowMetrics: isFirstSample)
                isFirstSample = false

                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    func pauseMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }
}

private actor SystemMetricsSampler {
    private enum Interval {
        static let hardware: TimeInterval = 3
        static let frequency: TimeInterval = 3
        static let swap: TimeInterval = 30
        static let disk: TimeInterval = 60
    }

    private var previousCoreTicks: [CPUTicks]?
    private var previousNetworkCounters: [String: NetworkCounters] = [:]
    private var previousNetworkTime: TimeInterval?
    private let hardwareMonitor = HardwareMonitor()
    private let cpuFrequencyReader = CPUFrequencyReader()
    private var processUsageSampler = ProcessUsageSampler()
    private var cachedHardware = HardwareReadings.unavailable
    private var cachedCPUFrequencies: (performanceHz: UInt64?, efficiencyHz: UInt64?)?
    private var cachedSwapUsedBytes: UInt64?
    private var cachedDisk: DiskReading?
    private var lastHardwareSampleTime: TimeInterval?
    private var lastFrequencySampleTime: TimeInterval?
    private var lastSwapSampleTime: TimeInterval?
    private var lastDiskSampleTime: TimeInterval?

    func sample(forceSlowMetrics: Bool = false) -> SystemSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        let currentCoreTicks = Self.readCoreTicks()
        let coreUsages = Self.calculateCoreUsages(
            previous: previousCoreTicks,
            current: currentCoreTicks
        )
        previousCoreTicks = currentCoreTicks

        if forceSlowMetrics || shouldRefresh(lastHardwareSampleTime, now: now, interval: Interval.hardware) {
            cachedHardware = hardwareMonitor.sample()
            lastHardwareSampleTime = now
        }
        if forceSlowMetrics || shouldRefresh(lastFrequencySampleTime, now: now, interval: Interval.frequency) {
            cachedCPUFrequencies = cpuFrequencyReader?.sample()
            lastFrequencySampleTime = now
        }
        if forceSlowMetrics || shouldRefresh(lastSwapSampleTime, now: now, interval: Interval.swap) {
            cachedSwapUsedBytes = Self.readSwapUsedBytes()
            lastSwapSampleTime = now
        }
        if forceSlowMetrics || shouldRefresh(lastDiskSampleTime, now: now, interval: Interval.disk) {
            cachedDisk = Self.readDisk()
            lastDiskSampleTime = now
        }

        let hardware = cachedHardware
        let cpuFrequencies = cachedCPUFrequencies
        let network = readNetworkRates()
        let memory = Self.readMemory()
        let processes = processUsageSampler.sample()

        return SystemSnapshot(
            cpuUsage: coreUsages.isEmpty
                ? nil
                : coreUsages.reduce(0, +) / Double(coreUsages.count),
            cpuCoreUsages: coreUsages,
            cpuPerformanceCoreCount: Self.readPerformanceCoreCount(totalCount: coreUsages.count),
            cpuPerformanceFrequencyHz: cpuFrequencies?.performanceHz
                ?? Self.readCPUFrequency(performanceLevel: 0),
            cpuEfficiencyFrequencyHz: cpuFrequencies?.efficiencyHz
                ?? Self.readCPUFrequency(performanceLevel: 1),
            cpuPowerWatts: hardware.cpuPowerWatts,
            gpuUsage: hardware.gpuUsage,
            gpuFrequencyHz: hardware.gpuFrequencyHz,
            gpuMemoryUsedBytes: hardware.gpuMemoryUsedBytes,
            gpuMemoryAllocatedBytes: hardware.gpuMemoryAllocatedBytes,
            gpuPowerWatts: hardware.gpuPowerWatts,
            memoryUsage: memory?.usage,
            memoryBreakdown: memory?.breakdown,
            swapUsedBytes: cachedSwapUsedBytes,
            diskUsage: cachedDisk?.usage,
            disk: cachedDisk,
            cpuTemperature: hardware.cpuTemperature,
            gpuTemperature: hardware.gpuTemperature,
            fans: hardware.fans,
            networkDownloadBytesPerSecond: network?.download,
            networkUploadBytesPerSecond: network?.upload,
            topCPUProcesses: processes.cpu,
            topMemoryProcesses: processes.memory
        )
    }

    private func shouldRefresh(
        _ previousTime: TimeInterval?,
        now: TimeInterval,
        interval: TimeInterval
    ) -> Bool {
        guard let previousTime else { return true }
        return now - previousTime >= interval
    }

    private static func readCPUFrequency(performanceLevel: Int) -> UInt64? {
        let levelKeys = [
            "hw.perflevel\(performanceLevel).cpufrequency",
            "hw.perflevel\(performanceLevel).cpufrequency_max"
        ]
        let fallbackKeys = performanceLevel == 0
            ? ["hw.cpufrequency", "hw.cpufrequency_max"]
            : []

        for key in levelKeys + fallbackKeys {
            var value: UInt64 = 0
            var size = MemoryLayout<UInt64>.size
            if sysctlbyname(key, &value, &size, nil, 0) == 0, value > 0 {
                return value
            }
        }
        return nil
    }

    private static func readPerformanceCoreCount(totalCount: Int) -> Int {
        guard totalCount > 0 else {
            return 0
        }

        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.perflevel0.logicalcpu", &count, &size, nil, 0)

        guard result == 0, count > 0, count < totalCount else {
            return totalCount
        }

        return Int(count)
    }

    private static func readCoreTicks() -> [CPUTicks]? {
        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &processorInfoCount
        )

        guard result == KERN_SUCCESS, let processorInfo else {
            return nil
        }

        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: processorInfo)),
                vm_size_t(processorInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        let stateCount = Int(CPU_STATE_MAX)
        return (0..<Int(processorCount)).map { processorIndex in
            let offset = processorIndex * stateCount
            return CPUTicks(
                user: UInt64(processorInfo[offset + Int(CPU_STATE_USER)]),
                system: UInt64(processorInfo[offset + Int(CPU_STATE_SYSTEM)]),
                idle: UInt64(processorInfo[offset + Int(CPU_STATE_IDLE)]),
                nice: UInt64(processorInfo[offset + Int(CPU_STATE_NICE)])
            )
        }
    }

    private static func calculateCoreUsages(
        previous: [CPUTicks]?,
        current: [CPUTicks]?
    ) -> [Double] {
        guard let previous, let current, previous.count == current.count else {
            return []
        }

        return zip(previous, current).map { old, new in
            let user = new.user &- old.user
            let system = new.system &- old.system
            let idle = new.idle &- old.idle
            let nice = new.nice &- old.nice
            let total = user + system + idle + nice

            guard total > 0 else {
                return 0
            }

            return min(max(Double(user + system + nice) / Double(total), 0), 1)
        }
    }

    private static func readMemory() -> (
        usage: Double,
        breakdown: MemoryBreakdown
    )? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return nil
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let activeBytes = UInt64(statistics.active_count) * pageSize
        let wiredBytes = UInt64(statistics.wire_count) * pageSize
        let compressedBytes = UInt64(statistics.compressor_page_count) * pageSize
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let usedBytes = activeBytes + wiredBytes + compressedBytes

        guard totalBytes > 0 else {
            return nil
        }

        let boundedUsedBytes = min(usedBytes, totalBytes)
        let freeBytes = totalBytes - boundedUsedBytes

        return (
            Double(boundedUsedBytes) / Double(totalBytes),
            MemoryBreakdown(
                wiredBytes: wiredBytes,
                activeBytes: activeBytes,
                compressedBytes: compressedBytes,
                freeBytes: freeBytes
            )
        )
    }

    private static func readSwapUsedBytes() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size

        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            return nil
        }

        return usage.xsu_used
    }

    private func readNetworkRates() -> (download: Double, upload: Double)? {
        let now = ProcessInfo.processInfo.systemUptime
        let current = Self.readNetworkCounters()

        defer {
            previousNetworkCounters = current
            previousNetworkTime = now
        }

        guard let previousNetworkTime else {
            return nil
        }

        let elapsed = now - previousNetworkTime
        guard elapsed > 0 else {
            return nil
        }

        var received: UInt64 = 0
        var sent: UInt64 = 0

        for (name, counters) in current {
            guard let previous = previousNetworkCounters[name] else {
                continue
            }

            received += Self.counterDelta(previous.received, counters.received)
            sent += Self.counterDelta(previous.sent, counters.sent)
        }

        return (
            download: Double(received) / elapsed,
            upload: Double(sent) / elapsed
        )
    }

    private static func readNetworkCounters() -> [String: NetworkCounters] {
        var addressPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressPointer) == 0, let first = addressPointer else {
            return [:]
        }

        defer {
            freeifaddrs(addressPointer)
        }

        var result: [String: NetworkCounters] = [:]

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let address = pointer.pointee
            guard let rawAddress = address.ifa_addr,
                  rawAddress.pointee.sa_family == UInt8(AF_LINK),
                  let data = address.ifa_data else {
                continue
            }

            let name = String(cString: address.ifa_name)
            let isRelevant = ["en", "awdl", "llw", "pdp_ip"].contains {
                name.hasPrefix($0)
            }
            let flags = Int32(address.ifa_flags)
            let isActive = flags & (IFF_UP | IFF_RUNNING) == (IFF_UP | IFF_RUNNING)

            guard isRelevant, isActive else {
                continue
            }

            let statistics = data.assumingMemoryBound(to: if_data.self).pointee
            result[name] = NetworkCounters(
                received: statistics.ifi_ibytes,
                sent: statistics.ifi_obytes
            )
        }

        return result
    }

    private static func counterDelta(_ previous: UInt32, _ current: UInt32) -> UInt64 {
        current >= previous
            ? UInt64(current - previous)
            : UInt64(current &- previous)
    }

    private static func readDisk() -> DiskReading? {
        let rootURL = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]

        guard let values = try? rootURL.resourceValues(forKeys: keys),
              let totalValue = values.volumeTotalCapacity,
              let availableValue = values.volumeAvailableCapacityForImportantUsage,
              totalValue > 0 else {
            return nil
        }

        let total = UInt64(totalValue)
        let free = UInt64(max(availableValue, 0))
        let used = total > free ? total - free : 0

        return DiskReading(
            name: values.volumeName ?? "Macintosh HD",
            totalBytes: total,
            usedBytes: used,
            freeBytes: free
        )
    }
}

private struct NetworkCounters {
    let received: UInt32
    let sent: UInt32
}

private struct CPUTicks {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64
}
