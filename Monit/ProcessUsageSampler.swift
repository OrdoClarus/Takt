import Darwin
import Foundation

struct ProcessUsage: Identifiable, Sendable, Equatable {
    let pid: pid_t
    let name: String
    let usage: Double
    let memoryBytes: UInt64?

    nonisolated var id: pid_t {
        pid
    }
}

struct ProcessUsageSnapshot: Sendable {
    let cpu: [ProcessUsage]
    let memory: [ProcessUsage]

    nonisolated static let empty = ProcessUsageSnapshot(cpu: [], memory: [])
}

nonisolated struct ProcessUsageSampler {
    private struct ProcessKey: Hashable {
        let pid: pid_t
        let startTime: UInt64
    }

    private struct Counters {
        let name: String
        let cpuTime: UInt64
        let memoryBytes: UInt64
    }

    private let updateInterval: TimeInterval = 5
    private let absoluteTimeToNanoseconds: Double
    private var previousCounters: [ProcessKey: Counters] = [:]
    private var previousSampleTime: TimeInterval?
    private var lastSnapshot = ProcessUsageSnapshot.empty

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        absoluteTimeToNanoseconds = Double(timebase.numer) / Double(timebase.denom)
    }

    mutating func sample() -> ProcessUsageSnapshot {
        let now = ProcessInfo.processInfo.systemUptime

        if let previousSampleTime, now - previousSampleTime < updateInterval {
            return lastSnapshot
        }

        let currentCounters = readCounters()
        let totalMemory = max(ProcessInfo.processInfo.physicalMemory, 1)
        let memory = currentCounters.map { key, counters in
            ProcessUsage(
                pid: key.pid,
                name: counters.name,
                usage: min(Double(counters.memoryBytes) / Double(totalMemory), 1),
                memoryBytes: counters.memoryBytes
            )
        }
        .sorted { $0.usage > $1.usage }

        var cpu: [ProcessUsage] = []
        if let previousSampleTime {
            let elapsedNanoseconds = (now - previousSampleTime) * 1_000_000_000
            if elapsedNanoseconds > 0 {
                for (key, current) in currentCounters {
                    guard let previous = previousCounters[key] else {
                        continue
                    }

                    let cpuDelta = counterDelta(previous.cpuTime, current.cpuTime)
                    guard cpuDelta > 0 else {
                        continue
                    }

                    cpu.append(
                        ProcessUsage(
                            pid: key.pid,
                            name: current.name,
                            usage: max(
                                Double(cpuDelta) * absoluteTimeToNanoseconds / elapsedNanoseconds,
                                0
                            ),
                            memoryBytes: nil
                        )
                    )
                }
                cpu.sort { $0.usage > $1.usage }
            }
        }

        previousCounters = currentCounters
        previousSampleTime = now
        lastSnapshot = ProcessUsageSnapshot(
            cpu: Array(cpu.prefix(3)),
            memory: Array(memory.prefix(3))
        )
        return lastSnapshot
    }

    private func readCounters() -> [ProcessKey: Counters] {
        let capacity = max(Int(proc_listallpids(nil, 0)), 1024)
        var pids = [pid_t](repeating: 0, count: capacity)
        let processCount = proc_listallpids(
            &pids,
            Int32(pids.count * MemoryLayout<pid_t>.stride)
        )
        guard processCount > 0 else {
            return [:]
        }

        let count = min(Int(processCount), pids.count)
        var result: [ProcessKey: Counters] = [:]
        result.reserveCapacity(count)

        for pid in pids.prefix(count) where pid > 0 {
            guard let resource = readResourceUsage(pid: pid) else {
                continue
            }

            let key = ProcessKey(pid: pid, startTime: resource.startTime)
            result[key] = Counters(
                name: readName(pid: pid),
                cpuTime: resource.cpuTime,
                memoryBytes: resource.memoryBytes
            )
        }

        return result
    }

    private func readResourceUsage(
        pid: pid_t
    ) -> (cpuTime: UInt64, memoryBytes: UInt64, startTime: UInt64)? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pid_rusage(
                pid,
                RUSAGE_INFO_V4,
                UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self)
            )
        }

        guard status == 0 else {
            return nil
        }

        return (
            cpuTime: info.ri_user_time &+ info.ri_system_time,
            memoryBytes: info.ri_phys_footprint,
            startTime: info.ri_proc_start_abstime
        )
    }

    private func readName(pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return "PID \(pid)"
        }
        return String(cString: buffer)
    }

    private func counterDelta(_ previous: UInt64, _ current: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }
}
