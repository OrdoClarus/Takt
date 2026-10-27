import CoreFoundation
import Darwin
import Foundation
import IOKit

/// Reads Apple Silicon cluster frequencies from IOReport performance-state residencies.
/// IOReport is private, so every operation is optional and fails closed.
nonisolated final class CPUFrequencyReader {
    private typealias CopyChannels = @convention(c) (
        CFString, CFString?, UInt64, UInt64, UInt64
    ) -> Unmanaged<CFDictionary>?
    private typealias CreateSubscription = @convention(c) (
        UnsafeMutableRawPointer?, CFDictionary,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?
    ) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (
        OpaquePointer, CFMutableDictionary, CFTypeRef?
    ) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta = @convention(c) (
        CFDictionary, CFDictionary, CFTypeRef?
    ) -> Unmanaged<CFDictionary>?
    private typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias StateCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateResidency = @convention(c) (CFDictionary, Int32) -> Int64

    private static let inactiveStates: Set<String> = ["IDLE", "DOWN", "OFF"]

    private let library: UnsafeMutableRawPointer
    private let subscription: OpaquePointer
    private let channels: CFMutableDictionary
    private let createSamples: CreateSamples
    private let createSamplesDelta: CreateSamplesDelta
    private let channelGroup: ChannelString
    private let channelSubgroup: ChannelString
    private let channelName: ChannelString
    private let stateCount: StateCount
    private let stateName: StateName
    private let stateResidency: StateResidency
    private let frequencyTables: [Int: [Double]]
    private var previousSample: CFDictionary?

    init?() {
        guard let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else {
            return nil
        }

        guard
            let copyChannels: CopyChannels = Self.symbol("IOReportCopyChannelsInGroup", from: library),
            let createSubscription: CreateSubscription = Self.symbol("IOReportCreateSubscription", from: library),
            let createSamples: CreateSamples = Self.symbol("IOReportCreateSamples", from: library),
            let createSamplesDelta: CreateSamplesDelta = Self.symbol("IOReportCreateSamplesDelta", from: library),
            let channelGroup: ChannelString = Self.symbol("IOReportChannelGetGroup", from: library),
            let channelSubgroup: ChannelString = Self.symbol("IOReportChannelGetSubGroup", from: library),
            let channelName: ChannelString = Self.symbol("IOReportChannelGetChannelName", from: library),
            let stateCount: StateCount = Self.symbol("IOReportStateGetCount", from: library),
            let stateName: StateName = Self.symbol("IOReportStateGetNameForIndex", from: library),
            let stateResidency: StateResidency = Self.symbol("IOReportStateGetResidency", from: library),
            let desiredChannels = copyChannels("CPU Stats" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
        else {
            dlclose(library)
            return nil
        }

        var subscribedChannels: Unmanaged<CFMutableDictionary>?
        guard
            let subscription = createSubscription(nil, desiredChannels, &subscribedChannels, 0, nil),
            let channels = subscribedChannels?.takeRetainedValue()
        else {
            dlclose(library)
            return nil
        }

        self.library = library
        self.subscription = subscription
        self.channels = channels
        self.createSamples = createSamples
        self.createSamplesDelta = createSamplesDelta
        self.channelGroup = channelGroup
        self.channelSubgroup = channelSubgroup
        self.channelName = channelName
        self.stateCount = stateCount
        self.stateName = stateName
        self.stateResidency = stateResidency
        frequencyTables = Self.loadFrequencyTables()
    }

    deinit {
        dlclose(library)
    }

    func sample() -> (performanceHz: UInt64?, efficiencyHz: UInt64?) {
        guard let current = createSamples(subscription, channels, nil)?.takeRetainedValue() else {
            return (nil, nil)
        }
        defer { previousSample = current }
        guard
            let previousSample,
            let delta = createSamplesDelta(previousSample, current, nil)?.takeRetainedValue(),
            let entries = (delta as NSDictionary)["IOReportChannels"] as? NSArray
        else {
            return (nil, nil)
        }

        var performance: [Double] = []
        var efficiency: [Double] = []

        for case let entry as NSDictionary in entries {
            let channel = unsafeBitCast(entry, to: CFDictionary.self)
            guard string(channelGroup(channel)) == "CPU Stats",
                  string(channelSubgroup(channel)) == "CPU Complex Performance States",
                  let name = string(channelName(channel)),
                  name.contains("CPU"), !name.contains("_IDLE"), !name.contains("CPM")
            else {
                continue
            }

            let activeCount = numberOfActiveStates(channel)
            guard let table = frequencyTables[activeCount],
                  let megahertz = weightedFrequency(channel, table: table)
            else {
                continue
            }

            if name.hasPrefix("E") {
                efficiency.append(megahertz)
            } else {
                performance.append(megahertz)
            }
        }

        return (
            performance.isEmpty ? nil : UInt64((performance.reduce(0, +) / Double(performance.count)) * 1_000_000),
            efficiency.isEmpty ? nil : UInt64((efficiency.reduce(0, +) / Double(efficiency.count)) * 1_000_000)
        )
    }

    private func numberOfActiveStates(_ channel: CFDictionary) -> Int {
        let count = Int(stateCount(channel))
        for index in 0..<count {
            let name = string(stateName(channel, Int32(index))) ?? ""
            if !Self.inactiveStates.contains(name) {
                return count - index
            }
        }
        return 0
    }

    private func weightedFrequency(_ channel: CFDictionary, table: [Double]) -> Double? {
        let count = Int(stateCount(channel))
        var names: [String] = []
        var residencies: [Double] = []
        for index in 0..<count {
            names.append(string(stateName(channel, Int32(index))) ?? "")
            residencies.append(Double(stateResidency(channel, Int32(index))))
        }
        guard let offset = names.firstIndex(where: { !Self.inactiveStates.contains($0) }) else {
            return table.first
        }
        let active = Array(residencies[offset...])
        let total = active.reduce(0, +)
        guard total > 0 else {
            return table.first
        }
        return zip(active, table).reduce(0) { result, pair in
            result + pair.0 / total * pair.1
        }
    }

    private func string(_ value: Unmanaged<CFString>?) -> String? {
        value?.takeUnretainedValue() as String?
    }

    private static func symbol<T>(_ name: String, from library: UnsafeMutableRawPointer) -> T? {
        guard let address = dlsym(library, name) else {
            return nil
        }
        return unsafeBitCast(address, to: T.self)
    }

    private static func loadFrequencyTables() -> [Int: [Double]] {
        var indices: [Int] = []
        if let data = registryData(key: "acc-clusters") {
            data.withUnsafeBytes { bytes in
                guard bytes.count >= 8 else { return }
                for offset in stride(from: 0, through: bytes.count - 8, by: 8) {
                    indices.append(Int(bytes[offset]))
                }
            }
        }
        if indices.isEmpty {
            indices = [1, 5]
        }

        var tables: [Int: [Double]] = [:]
        for index in indices {
            guard let data = registryData(key: "voltage-states\(index)-sram") else {
                continue
            }
            let values = parseVoltageStates(data).map(normalizeToMHz).drop(while: { $0 <= 0 })
            let table = Array(values)
            if !table.isEmpty {
                tables[table.count] = table
            }
        }
        return tables
    }

    private static func registryData(key: String) -> Data? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        return IORegistryEntrySearchCFProperty(
            root,
            kIOServicePlane,
            key as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)
        ) as? Data
    }

    private static func parseVoltageStates(_ data: Data) -> [Double] {
        data.withUnsafeBytes { bytes in
            stride(from: 0, to: data.count - 7, by: 8).map { offset in
                Double(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
        }
    }

    private static func normalizeToMHz(_ value: Double) -> Double {
        if value >= 1e8 { return value / 1e6 }
        if value >= 1e5 { return value / 1e3 }
        return value
    }
}
