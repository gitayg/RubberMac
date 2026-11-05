import Foundation

// How hard a process works and how much memory it holds, counting every process it started, and which copy of an app
// it is when several run from the same place (Electron apps told apart by --user-data-dir).
enum ProcessUsage {
    struct Sample { let cpuNanoseconds: UInt64; let memoryBytes: UInt64; let takenAt: UInt64 }  // takenAt: ns, monotonic

    // rusage counts CPU time in Mach ticks, not nanoseconds: 125/3 ns each on Apple silicon, 1 on Intel.
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    // The process plus every process it started, recursively (an Electron app's helpers do most of its work).
    static func sample(_ pid: pid_t) -> Sample? {
        guard let own = rusage(pid) else { return nil }
        var ticks = cpuTicks(own)
        var memory = own.ri_phys_footprint
        for child in descendants(of: pid) {
            // One that quit since it was listed can't be read any more.
            guard let usage = rusage(child) else { continue }
            ticks += cpuTicks(usage)
            memory += usage.ri_phys_footprint
        }
        return Sample(cpuNanoseconds: ticks * timebase.numer / timebase.denom, memoryBytes: memory,
                      takenAt: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }

    // 100 = one core fully busy, as Activity Monitor counts it.
    static func cpuPercent(from earlier: Sample, to later: Sample) -> Double {
        // A child that quit without being waited for takes its time with it, and the total can drop.
        guard later.takenAt > earlier.takenAt, later.cpuNanoseconds > earlier.cpuNanoseconds else { return 0 }
        return Double(later.cpuNanoseconds - earlier.cpuNanoseconds) / Double(later.takenAt - earlier.takenAt) * 100
    }

    // The process's argv via sysctl KERN_PROCARGS2 (works for the user's own processes without privileges).
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size >= 4 else { return nil }
        // The argument count, the executable's path, zeros up to a word's end, then the arguments one after another,
        // each ending in a zero (and the environment after them).
        let count = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var at = 4
        while at < size && buffer[at] != 0 { at += 1 }
        while at < size && buffer[at] == 0 { at += 1 }
        var arguments: [String] = []
        while arguments.count < count && at < size {
            let end = buffer[at..<size].firstIndex(of: 0) ?? size
            arguments.append(String(decoding: buffer[at..<end], as: UTF8.self))
            at = end + 1
        }
        return arguments.count == count ? arguments : nil
    }

    // From --user-data-dir=<dir> or "--user-data-dir <dir>": the dir's last path component with a leading "<appName>-"
    // removed ("Claude-Teams" -> "Teams"); without the flag, "Default". Given twice, the last one counts, as in Chromium.
    static func copyName(arguments: [String], appName: String) -> String {
        var folder: String?
        for (i, argument) in arguments.enumerated() {
            if argument.hasPrefix("--user-data-dir=") {
                folder = String(argument.dropFirst("--user-data-dir=".count))
            } else if argument == "--user-data-dir", i + 1 < arguments.count {
                folder = arguments[i + 1]
            }
        }
        guard let folder else { return "Default" }
        let name = (folder as NSString).lastPathComponent
        return name.hasPrefix(appName + "-") ? String(name.dropFirst(appName.count + 1)) : name
    }

    // e.g. "Teams · CPU 12% · 1.2 GB"; copy nil -> no copy part; cpu nil -> "CPU …" (not measured yet).
    static func text(copy: String?, cpu: Double?, memoryBytes: UInt64) -> String {
        // In binary units, as Activity Monitor shows them.
        let megabytes = (Double(memoryBytes) / 1_048_576).rounded()
        let memory = megabytes >= 1024 ? String(format: "%.1f GB", Double(memoryBytes) / 1_073_741_824) : "\(Int(megabytes)) MB"
        let busy = cpu.map { "CPU \(Int($0.rounded()))%" } ?? "CPU …"
        return [copy, busy, memory].compactMap { $0 }.joined(separator: " · ")
    }

    private static func rusage(_ pid: pid_t) -> rusage_info_v2? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return result == 0 ? info : nil
    }

    // Its own time and that of the processes it started and waited for after they quit, so the total doesn't drop
    // when a helper goes.
    private static func cpuTicks(_ info: rusage_info_v2) -> UInt64 {
        info.ri_user_time + info.ri_system_time + info.ri_child_user_time + info.ri_child_system_time
    }

    private static func descendants(of pid: pid_t) -> [pid_t] {
        // Asked with no room, it gives the count of every process, which is room enough for the children.
        var children = [pid_t](repeating: 0, count: Int(max(proc_listchildpids(pid, nil, 0), 0)))
        let count = children.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        return children.prefix(Int(max(count, 0))).flatMap { [$0] + descendants(of: $0) }
    }
}
