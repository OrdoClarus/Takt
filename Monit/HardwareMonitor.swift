import Darwin
import Foundation
import IOKit

struct FanReading: Sendable, Equatable, Identifiable {
    let index: Int
    let currentRPM: Int
    let minimumRPM: Int?
    let maximumRPM: Int?

    var id: Int {
        index
    }
}

struct HardwareReadings: Sendable {
    var gpuUsage: Double?
    var gpuFrequencyHz: UInt64?
    var gpuMemoryUsedBytes: UInt64?
    var gpuMemoryAllocatedBytes: UInt64?
    var gpuPowerWatts: Double?
    var cpuTemperature: Double?
    var gpuTemperature: Double?
    var cpuPowerWatts: Double?
    var fans: [FanReading]

    nonisolated static let unavailable = HardwareReadings(
        gpuUsage: nil,
        gpuFrequencyHz: nil,
        gpuMemoryUsedBytes: nil,
        gpuMemoryAllocatedBytes: nil,
        gpuPowerWatts: nil,
        cpuTemperature: nil,
        gpuTemperature: nil,
        cpuPowerWatts: nil,
        fans: []
    )
}

nonisolated final class HardwareMonitor {
    private let smc: SMCReader?
    private let gpu: GPUUsageReader?
    private let cpuPower: CPUPowerReader?
    private let cpuTemperatureKeys: [String]
    private let gpuTemperatureKeys: [String]
    private let cpuPowerKeys: [String]
    private let gpuPowerKeys: [String]
    private let fanIndices: [Int]

    init() {
        let smc = SMCReader()
        self.smc = smc
        gpu = GPUUsageReader()
        cpuPower = CPUPowerReader()

        guard let smc else {
            cpuTemperatureKeys = []
            gpuTemperatureKeys = []
            cpuPowerKeys = []
            gpuPowerKeys = []
            fanIndices = []
            return
        }

        let keys = smc.allKeys()
        // Apple silicon exposes performance-core sensors as Tp*, efficiency-core
        // sensors as Te*, and GPU cluster sensors as Tg*. Averaging only Tp*
        // overstates the whole-CPU temperature on asymmetric SoCs.
        cpuTemperatureKeys = keys.filter {
            $0.hasPrefix("Tp") || $0.hasPrefix("Te")
        }
        gpuTemperatureKeys = keys.filter { $0.hasPrefix("Tg") }
        // PP0C is the CPU package power sensor exposed by SMC on newer Apple silicon.
        // Keep the older aliases as fallbacks for other Mac generations.
        let preferredPowerKeys = ["PP0C", "PCPC", "PCTR", "PACC", "PC0C"]
        cpuPowerKeys = preferredPowerKeys.filter(keys.contains)
        gpuPowerKeys = ["PG0C", "PGTR", "PGPU"].filter(keys.contains)

        if let count = smc.readFloat("FNum"), count > 0 {
            fanIndices = Array(0..<min(Int(count), 8))
        } else {
            fanIndices = (0..<8).filter { smc.readFloat("F\($0)Ac") != nil }
        }
    }

    func sample() -> HardwareReadings {
        let gpuPerformance = gpu?.sample()
        let gpuMemory = readGPUMemory()

        return HardwareReadings(
            gpuUsage: gpuPerformance?.usage,
            gpuFrequencyHz: gpuPerformance?.frequencyHz,
            gpuMemoryUsedBytes: gpuMemory?.used,
            gpuMemoryAllocatedBytes: gpuMemory?.allocated,
            gpuPowerWatts: readSMCGPUPower(),
            cpuTemperature: averageTemperature(keys: cpuTemperatureKeys),
            gpuTemperature: averageTemperature(keys: gpuTemperatureKeys),
            cpuPowerWatts: cpuPower?.sample() ?? readSMCPUPower(),
            fans: readFans()
        )
    }

    private func averageTemperature(keys: [String]) -> Double? {
        guard let smc else {
            return nil
        }

        let values = keys.compactMap { key -> Double? in
            guard let value = smc.readFloat(key) else {
                return nil
            }

            let temperature = Double(value)
            return (1...130).contains(temperature) ? temperature : nil
        }

        guard !values.isEmpty else {
            return nil
        }

        return values.reduce(0, +) / Double(values.count)
    }

    private func readSMCPUPower() -> Double? {
        guard let smc else {
            return nil
        }

        return cpuPowerKeys.lazy
            .compactMap { smc.readFloat($0).map(Double.init) }
            .first { (0.01...500).contains($0) }
    }

    private func readSMCGPUPower() -> Double? {
        guard let smc else {
            return nil
        }

        return gpuPowerKeys.lazy
            .compactMap { smc.readFloat($0).map(Double.init) }
            .first { (0.001...500).contains($0) }
    }

    private func readGPUMemory() -> (used: UInt64, allocated: UInt64)? {
        guard let matching = IOServiceMatching("IOAccelerator") else {
            return nil
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            return nil
        }
        defer { IOObjectRelease(service) }

        guard let property = IORegistryEntryCreateCFProperty(
            service,
            "PerformanceStatistics" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        let used = (property["In use system memory"] as? NSNumber)?.uint64Value
        let allocated = (property["Alloc system memory"] as? NSNumber)?.uint64Value
        guard let used, let allocated, allocated > 0 else {
            return nil
        }

        return (used, allocated)
    }

    private func readFans() -> [FanReading] {
        guard let smc else {
            return []
        }

        return fanIndices.compactMap { index in
            guard let current = smc.readFloat("F\(index)Ac"), current >= 0 else {
                return nil
            }

            return FanReading(
                index: index,
                currentRPM: Int(current.rounded()),
                minimumRPM: smc.readFloat("F\(index)Mn").map { Int($0.rounded()) },
                maximumRPM: smc.readFloat("F\(index)Mx").map { Int($0.rounded()) }
            )
        }
    }
}

private nonisolated final class SMCReader {
    private struct KeyInfo {
        let size: UInt32
        let type: UInt32
        let attributes: UInt8
    }

    private struct Value {
        let type: String
        let data: [UInt8]
    }

    private static let keyDataSize = 80
    private var connection: io_connect_t = 0
    private var keyInfoCache: [UInt32: KeyInfo] = [:]

    init?() {
        guard let iterator = IOServiceIterator(serviceName: "AppleSMC") else {
            return nil
        }

        while let entry = iterator.next() {
            defer {
                IOObjectRelease(entry.object)
            }

            guard entry.name == "AppleSMCKeysEndpoint" else {
                continue
            }

            guard IOServiceOpen(entry.object, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
                return nil
            }
        }

        guard connection != 0 else {
            return nil
        }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func allKeys() -> [String] {
        guard let value = read("#KEY"), value.data.count >= 4 else {
            return []
        }

        let count = UInt32(value.data[0]) << 24
            | UInt32(value.data[1]) << 16
            | UInt32(value.data[2]) << 8
            | UInt32(value.data[3])

        return (0..<min(count, 8_000)).compactMap(keyByIndex)
    }

    func readFloat(_ key: String) -> Float? {
        guard let value = read(key) else {
            return nil
        }

        return Self.numeric(value)
    }

    private func read(_ key: String) -> Value? {
        let encodedKey = Self.fourCharacterCode(key)

        guard let info = keyInfo(for: encodedKey),
              info.size <= 32,
              let output = call(key: encodedKey, command: 5, info: info) else {
            return nil
        }

        let start = 48
        let end = start + Int(info.size)
        guard end <= output.count else {
            return nil
        }

        return Value(
            type: Self.fourCharacterString(info.type),
            data: Array(output[start..<end])
        )
    }

    private func keyInfo(for key: UInt32) -> KeyInfo? {
        if let cached = keyInfoCache[key] {
            return cached
        }

        guard let output = call(key: key, command: 9),
              let size = Self.readUInt32(output, at: 28),
              let type = Self.readUInt32(output, at: 32),
              output.indices.contains(36) else {
            return nil
        }

        let info = KeyInfo(size: size, type: type, attributes: output[36])
        keyInfoCache[key] = info
        return info
    }

    private func keyByIndex(_ index: UInt32) -> String? {
        guard let output = call(key: 0, command: 8, data32: index),
              let key = Self.readUInt32(output, at: 0) else {
            return nil
        }

        return Self.fourCharacterString(key)
    }

    private func call(
        key: UInt32,
        command: UInt8,
        data32: UInt32 = 0,
        info: KeyInfo? = nil
    ) -> [UInt8]? {
        var input = [UInt8](repeating: 0, count: Self.keyDataSize)
        Self.writeUInt32(key, to: &input, at: 0)

        if let info {
            Self.writeUInt32(info.size, to: &input, at: 28)
            Self.writeUInt32(info.type, to: &input, at: 32)
            input[36] = info.attributes
        }

        input[42] = command
        Self.writeUInt32(data32, to: &input, at: 44)

        var output = [UInt8](repeating: 0, count: Self.keyDataSize)
        var outputSize = Self.keyDataSize

        let result = input.withUnsafeBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                IOConnectCallStructMethod(
                    connection,
                    2,
                    inputBytes.baseAddress,
                    Self.keyDataSize,
                    outputBytes.baseAddress,
                    &outputSize
                )
            }
        }

        guard result == KERN_SUCCESS,
              outputSize >= 48,
              output.indices.contains(40),
              output[40] == 0 else {
            return nil
        }

        return output
    }

    private static func numeric(_ value: Value) -> Float? {
        let data = value.data

        switch value.type {
        case "flt ":
            guard data.count == 4 else {
                return nil
            }
            let bits = UInt32(data[0])
                | UInt32(data[1]) << 8
                | UInt32(data[2]) << 16
                | UInt32(data[3]) << 24
            return Float(bitPattern: bits)
        case "fpe2":
            guard data.count >= 2 else {
                return nil
            }
            return Float((UInt16(data[0]) << 6) | (UInt16(data[1]) >> 2))
        case "ui8 ":
            return data.first.map(Float.init)
        case "ui16":
            guard data.count >= 2 else {
                return nil
            }
            return Float(UInt16(data[0]) << 8 | UInt16(data[1]))
        case "ui32":
            guard data.count >= 4 else {
                return nil
            }
            return Float(
                UInt32(data[0]) << 24
                    | UInt32(data[1]) << 16
                    | UInt32(data[2]) << 8
                    | UInt32(data[3])
            )
        case "sp78":
            guard data.count >= 2 else {
                return nil
            }
            let raw = Int16(bitPattern: UInt16(data[0]) << 8 | UInt16(data[1]))
            return Float(raw) / 256
        default:
            return nil
        }
    }

    private static func fourCharacterCode(_ string: String) -> UInt32 {
        string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func fourCharacterString(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private static func writeUInt32(_ value: UInt32, to bytes: inout [UInt8], at offset: Int) {
        guard offset >= 0, offset + 4 <= bytes.count else {
            return
        }

        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else {
            return nil
        }

        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}

private nonisolated final class CPUPowerReader {
    private typealias CopyAllChannels = @convention(c) (UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias CreateSubscription = @convention(c) (
        UnsafeRawPointer?,
        CFMutableDictionary,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
        UInt64,
        CFTypeRef?
    ) -> UnsafeRawPointer?
    private typealias CreateSamples = @convention(c) (
        UnsafeRawPointer,
        CFMutableDictionary,
        CFTypeRef?
    ) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta = @convention(c) (
        CFDictionary,
        CFDictionary,
        CFTypeRef?
    ) -> Unmanaged<CFDictionary>?
    private typealias GetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias SimpleIntegerValue = @convention(c) (CFDictionary, Int32) -> Int64

    private let createSamples: CreateSamples
    private let createDelta: CreateSamplesDelta
    private let getGroup: GetString
    private let getName: GetString
    private let getSimpleValue: SimpleIntegerValue
    private let channels: CFMutableDictionary
    private let subscription: UnsafeRawPointer
    private var previousSample: CFDictionary?
    private var previousTimestamp: UInt64?

    init?() {
        guard let library = DynamicLibrary(path: "/usr/lib/libIOReport.dylib")
                ?? DynamicLibrary(path: "libIOReport.dylib"),
              let copyAll = library.symbol("IOReportCopyAllChannels", as: CopyAllChannels.self),
              let createSubscription = library.symbol(
                "IOReportCreateSubscription",
                as: CreateSubscription.self
              ),
              let createSamples = library.symbol("IOReportCreateSamples", as: CreateSamples.self),
              let createDelta = library.symbol(
                "IOReportCreateSamplesDelta",
                as: CreateSamplesDelta.self
              ),
              let getGroup = library.symbol("IOReportChannelGetGroup", as: GetString.self),
              let getName = library.symbol("IOReportChannelGetChannelName", as: GetString.self),
              let getSimpleValue = library.symbol(
                "IOReportSimpleGetIntegerValue",
                as: SimpleIntegerValue.self
              ),
              let allChannels = copyAll(0, 0)?.takeRetainedValue() as NSDictionary?,
              let channelList = allChannels["IOReportChannels"] as? [NSDictionary] else {
            return nil
        }

        let selectedChannels = NSMutableArray()
        for channel in channelList {
            let dictionary = channel as CFDictionary
            let group = Self.string(getGroup(dictionary))
            let name = Self.string(getName(dictionary))

            if group == "Energy Model",
               name == "CPU Energy" || Self.isCPUClusterEnergyChannel(name) {
                selectedChannels.add(channel)
            }
        }

        guard selectedChannels.count > 0 else {
            return nil
        }

        let mutableChannels = NSMutableDictionary(dictionary: allChannels)
        mutableChannels["IOReportChannels"] = selectedChannels

        var subscribedChannels: Unmanaged<CFMutableDictionary>?
        guard let subscription = createSubscription(
            nil,
            mutableChannels as CFMutableDictionary,
            &subscribedChannels,
            0,
            nil
        ) else {
            return nil
        }

        self.createSamples = createSamples
        self.createDelta = createDelta
        self.getGroup = getGroup
        self.getName = getName
        self.getSimpleValue = getSimpleValue
        channels = mutableChannels as CFMutableDictionary
        self.subscription = subscription
    }

    func sample() -> Double? {
        guard let current = createSamples(subscription, channels, nil)?.takeRetainedValue() else {
            return nil
        }

        let timestamp = DispatchTime.now().uptimeNanoseconds
        defer {
            previousSample = current
            previousTimestamp = timestamp
        }

        guard let previousSample,
              let previousTimestamp,
              timestamp > previousTimestamp,
              let delta = createDelta(
                previousSample,
                current,
                nil
              )?.takeRetainedValue() as NSDictionary?,
              let channelList = delta["IOReportChannels"] as? [NSDictionary] else {
            return nil
        }

        let elapsedSeconds = Double(timestamp - previousTimestamp) / 1_000_000_000
        guard elapsedSeconds > 0 else {
            return nil
        }

        var aggregateMillijoules: Double?
        var clusterMillijoules = 0.0
        var hasClusterReading = false

        for channel in channelList {
            let dictionary = channel as CFDictionary
            guard Self.string(getGroup(dictionary)) == "Energy Model" else {
                continue
            }

            let name = Self.string(getName(dictionary))
            let rawValue = getSimpleValue(dictionary, 0)
            guard rawValue != Int64.min, rawValue >= 0 else {
                continue
            }

            let millijoules = Double(rawValue)
            if name == "CPU Energy" {
                aggregateMillijoules = millijoules
            } else if Self.isCPUClusterEnergyChannel(name) {
                clusterMillijoules += millijoules
                hasClusterReading = true
            }
        }

        let millijoules: Double
        if let aggregateMillijoules, aggregateMillijoules > 0 {
            millijoules = aggregateMillijoules
        } else if hasClusterReading, clusterMillijoules > 0 {
            millijoules = clusterMillijoules
        } else {
            return nil
        }

        let watts = millijoules / elapsedSeconds / 1_000
        return (0...500).contains(watts) ? watts : nil
    }

    private static func isCPUClusterEnergyChannel(_ name: String) -> Bool {
        if name.hasSuffix("_CPU") {
            return ["EACC", "PACC", "MACC", "SACC"].contains { name.hasPrefix($0) }
        }

        return ["ECPU", "PCPU", "MCPU", "SCPU"].contains { prefix in
            guard name.hasPrefix(prefix) else {
                return false
            }

            let suffix = name.dropFirst(prefix.count)
            return suffix.isEmpty || suffix.allSatisfy { $0.isNumber }
        }
    }

    private static func string(_ value: Unmanaged<CFString>?) -> String {
        guard let value else {
            return ""
        }

        return (value.takeUnretainedValue() as String)
            .trimmingCharacters(in: .whitespaces)
    }
}

private struct GPUPerformanceReading {
    let usage: Double
    let frequencyHz: UInt64?
}

private nonisolated final class GPUUsageReader {
    private typealias CopyAllChannels = @convention(c) (UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias CreateSubscription = @convention(c) (
        UnsafeRawPointer?,
        CFMutableDictionary,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
        UInt64,
        CFTypeRef?
    ) -> UnsafeRawPointer?
    private typealias CreateSamples = @convention(c) (
        UnsafeRawPointer,
        CFMutableDictionary,
        CFTypeRef?
    ) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta = @convention(c) (
        CFDictionary,
        CFDictionary,
        CFTypeRef?
    ) -> Unmanaged<CFDictionary>?
    private typealias GetString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias StateCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateResidency = @convention(c) (CFDictionary, Int32) -> Int64

    private let createSamples: CreateSamples
    private let createDelta: CreateSamplesDelta
    private let getGroup: GetString
    private let getSubgroup: GetString
    private let getName: GetString
    private let getStateCount: StateCount
    private let getStateName: StateName
    private let getStateResidency: StateResidency
    private let channels: CFMutableDictionary
    private let subscription: UnsafeRawPointer
    private let frequenciesHz: [UInt64]
    private var previousSample: CFDictionary?

    init?() {
        guard let library = DynamicLibrary(path: "/usr/lib/libIOReport.dylib")
                ?? DynamicLibrary(path: "libIOReport.dylib"),
              let copyAll = library.symbol("IOReportCopyAllChannels", as: CopyAllChannels.self),
              let createSubscription = library.symbol(
                "IOReportCreateSubscription",
                as: CreateSubscription.self
              ),
              let createSamples = library.symbol("IOReportCreateSamples", as: CreateSamples.self),
              let createDelta = library.symbol(
                "IOReportCreateSamplesDelta",
                as: CreateSamplesDelta.self
              ),
              let getGroup = library.symbol("IOReportChannelGetGroup", as: GetString.self),
              let getSubgroup = library.symbol(
                "IOReportChannelGetSubGroup",
                as: GetString.self
              ),
              let getName = library.symbol(
                "IOReportChannelGetChannelName",
                as: GetString.self
              ),
              let getStateCount = library.symbol(
                "IOReportStateGetCount",
                as: StateCount.self
              ),
              let getStateName = library.symbol(
                "IOReportStateGetNameForIndex",
                as: StateName.self
              ),
              let getStateResidency = library.symbol(
                "IOReportStateGetResidency",
                as: StateResidency.self
              ),
              let allChannels = copyAll(0, 0)?.takeRetainedValue() as NSDictionary?,
              let channelList = allChannels["IOReportChannels"] as? [NSDictionary] else {
            return nil
        }

        let selectedChannels = NSMutableArray()

        for channel in channelList {
            let dictionary = channel as CFDictionary
            let group = Self.string(getGroup(dictionary))
            let subgroup = Self.string(getSubgroup(dictionary))
            let name = Self.string(getName(dictionary))

            if group == "GPU Stats",
               subgroup == "GPU Performance States",
               name == "GPUPH" {
                selectedChannels.add(channel)
            }
        }

        guard selectedChannels.count > 0 else {
            return nil
        }

        let mutableChannels = NSMutableDictionary(dictionary: allChannels)
        mutableChannels["IOReportChannels"] = selectedChannels

        var subscribedChannels: Unmanaged<CFMutableDictionary>?
        guard let subscription = createSubscription(
            nil,
            mutableChannels as CFMutableDictionary,
            &subscribedChannels,
            0,
            nil
        ) else {
            return nil
        }

        self.createSamples = createSamples
        self.createDelta = createDelta
        self.getGroup = getGroup
        self.getSubgroup = getSubgroup
        self.getName = getName
        self.getStateCount = getStateCount
        self.getStateName = getStateName
        self.getStateResidency = getStateResidency
        channels = mutableChannels as CFMutableDictionary
        self.subscription = subscription
        frequenciesHz = Self.readGPUFrequencies()
    }

    func sample() -> GPUPerformanceReading? {
        guard let current = createSamples(subscription, channels, nil)?.takeRetainedValue() else {
            return nil
        }

        defer {
            previousSample = current
        }

        guard let previousSample,
              let delta = createDelta(
                previousSample,
                current,
                nil
              )?.takeRetainedValue() as NSDictionary?,
              let channelList = delta["IOReportChannels"] as? [NSDictionary] else {
            return nil
        }

        for channel in channelList {
            let dictionary = channel as CFDictionary

            guard Self.string(getGroup(dictionary)) == "GPU Stats",
                  Self.string(getSubgroup(dictionary)) == "GPU Performance States",
                  Self.string(getName(dictionary)) == "GPUPH" else {
                continue
            }

            let states = stateResidencies(dictionary)
            let total = states.reduce(0.0) { $0 + Double($1.residency) }
            let active = states
                .filter { !["IDLE", "DOWN", "OFF"].contains($0.name) }
                .reduce(0.0) { $0 + Double($1.residency) }

            guard total > 0 else {
                return GPUPerformanceReading(usage: 0, frequencyHz: nil)
            }

            let frequency = weightedFrequency(states: states)
            return GPUPerformanceReading(
                usage: min(max(active / total, 0), 1),
                frequencyHz: frequency
            )
        }

        return nil
    }

    private func stateResidencies(_ channel: CFDictionary) -> [(name: String, residency: Int64)] {
        let count = max(getStateCount(channel), 0)

        return (0..<count).map { index in
            let name = getStateName(channel, index)
                .map { $0.takeUnretainedValue() as String } ?? "S\(index)"
            return (name, getStateResidency(channel, index))
        }
    }

    private func weightedFrequency(states: [(name: String, residency: Int64)]) -> UInt64? {
        var weightedFrequency = 0.0
        var activeResidency = 0.0

        for state in states {
            guard state.residency > 0,
                  let index = Self.performanceStateIndex(state.name),
                  frequenciesHz.indices.contains(index),
                  frequenciesHz[index] > 0 else {
                continue
            }

            let residency = Double(state.residency)
            weightedFrequency += Double(frequenciesHz[index]) * residency
            activeResidency += residency
        }

        guard activeResidency > 0 else {
            return nil
        }

        return UInt64((weightedFrequency / activeResidency).rounded())
    }

    private static func performanceStateIndex(_ name: String) -> Int? {
        guard name.first == "P" else {
            return nil
        }

        return Int(name.dropFirst())
    }

    private static func readGPUFrequencies() -> [UInt64] {
        guard let matching = IOServiceNameMatching("pmgr") else {
            return []
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            return []
        }
        defer { IOObjectRelease(service) }

        for key in ["voltage-states9-sram", "voltage-states9"] {
            guard let data = IORegistryEntryCreateCFProperty(
                service,
                key as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? Data,
                  data.count >= 8 else {
                continue
            }

            let frequencies = stride(from: 0, to: data.count - 7, by: 8).map { offset in
                data.withUnsafeBytes { bytes in
                    UInt64(UInt32(littleEndian: bytes.loadUnaligned(
                        fromByteOffset: offset,
                        as: UInt32.self
                    )))
                }
            }

            if frequencies.contains(where: { $0 > 0 }) {
                return frequencies
            }
        }

        return []
    }

    private static func string(_ value: Unmanaged<CFString>?) -> String {
        guard let value else {
            return ""
        }

        return (value.takeUnretainedValue() as String)
            .trimmingCharacters(in: .whitespaces)
    }
}

private nonisolated final class DynamicLibrary {
    private let handle: UnsafeMutableRawPointer

    init?(path: String) {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            return nil
        }

        self.handle = handle
    }

    func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let symbol = dlsym(handle, name) else {
            return nil
        }

        return unsafeBitCast(symbol, to: type)
    }
}

private nonisolated final class IOServiceIterator {
    struct Entry {
        let object: io_registry_entry_t
        let name: String
    }

    private var iterator: io_iterator_t = 0

    init?(serviceName: String) {
        guard let matching = IOServiceMatching(serviceName),
              IOServiceGetMatchingServices(
                kIOMainPortDefault,
                matching,
                &iterator
              ) == KERN_SUCCESS else {
            return nil
        }
    }

    deinit {
        if iterator != 0 {
            IOObjectRelease(iterator)
        }
    }

    func next() -> Entry? {
        guard iterator != 0 else {
            return nil
        }

        let entry = IOIteratorNext(iterator)

        guard entry != 0 else {
            IOObjectRelease(iterator)
            iterator = 0
            return nil
        }

        var name = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(entry, &name)

        return Entry(object: entry, name: String(cString: name))
    }
}
