import AppKit

// --selftest usage: which copy of an app a command line names, this process's own command line, its CPU with a busy
// thread and with a busy child, its memory, the text the Dock menu shows, and that every regular app can be read.
// Prints counts and made-up names only, never another process's arguments or paths.
extension ProcessUsage {
    static func selfTestReport() -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            lines.append("\(ok ? "ok  " : "FAIL") \(what)")
        }
        func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
        func spin(_ seconds: Double) {
            let end = now() + UInt64(seconds * 1e9)
            while now() < end {}
        }

        let exe = "/Applications/Made Up.app/Contents/MacOS/Made Up"
        let support = "/Users/someone/Library/Application Support/"
        let named: [([String], String, String)] = [
            ([exe], "Made Up", "Default"),
            ([exe, "--user-data-dir=\(support)Made Up-Teams"], "Made Up", "Teams"),
            ([exe, "--user-data-dir", "\(support)Made Up-Big Office"], "Made Up", "Big Office"),
            ([exe, "--user-data-dir=/Users/someone/Profiles/Work"], "Made Up", "Work"),
            ([exe, "--user-data-dir", "/Users/someone/Profiles/Work/"], "Made Up", "Work"),
            ([exe, "--user-data-dir=\(support)Other-Teams"], "Made Up", "Other-Teams"),
            ([exe, "--user-data-dir=/a/Made Up-One", "--user-data-dir", "/a/Made Up-Two"], "Made Up", "Two"),
            ([exe, "--user-data-dir"], "Made Up", "Default"),
            ([exe, "--user-data-dirs=/a/Made Up-Teams", "--other=/a/Made Up-Teams"], "Made Up", "Default"),
        ]
        let misnamed = named.compactMap { arguments, app, expected -> String? in
            let got = copyName(arguments: arguments, appName: app)
            return got == expected ? nil : "\(arguments.dropFirst()) gave \"\(got)\", not \"\(expected)\""
        }
        check(misnamed.isEmpty, "copy names from --user-data-dir=<dir> and --user-data-dir <dir>, with and without the app's "
              + "prefix, a trailing slash, another app's prefix kept, the last of two, and none or no value giving Default "
              + "(\(named.count) cases" + (misnamed.isEmpty ? ")" : "; wrong: " + misnamed.prefix(3).joined(separator: "; ") + ")"))

        let me = getpid()
        let own = arguments(of: me)
        check(own == CommandLine.arguments,
              "this process's command line read back the same (\(own?.count ?? 0) arguments, \(CommandLine.arguments.count) expected)")

        // Memory against the kernel's own count for this task, taken right after.
        let memory = sample(me)?.memoryBytes ?? 0
        var vm = task_vm_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size) }
        }
        let mb = { (bytes: UInt64) in String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        let apart = memory > vm.phys_footprint ? memory - vm.phys_footprint : vm.phys_footprint - memory
        check(memory > 4 * 1_048_576 && apart < 1_048_576,
              "this process's memory is \(mb(memory)), the task's own footprint \(mb(vm.phys_footprint)) (over 4 MB, within 1 MB)")

        // A thread busy for half a second while the main thread waits: one core's worth. Measured 93 to 100 here with the
        // machine in use; it can't pass 100 by more than the sampling itself, and it falls as other work takes the core.
        let done = DispatchSemaphore(value: 0)
        let first = sample(me)
        Thread.detachNewThread {
            spin(0.5)
            done.signal()
        }
        done.wait()
        let second = sample(me)
        let threadBusy = first.flatMap { a in second.map { cpuPercent(from: a, to: $0) } } ?? -1
        // One core busy reads near 100, less when other work takes the core (79% seen on a busy Mac). Time counted in
        // the wrong unit reads 2%, so the floor is far below the one and far above the other.
        check(threadBusy > 50 && threadBusy < 105,
              String(format: "a thread busy for 0.5 s reads as %.1f%% CPU (50 to 105)", threadBusy))

        // A child busy for half a second while this process only sleeps: counted as this process's.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "while :; do :; done"]
        var childBusy = -1.0
        var kept = false
        var keptText = "no child"
        if (try? child.run()) != nil {
            let start = sample(me)
            Thread.sleep(forTimeInterval: 0.5)
            let running = sample(me)
            child.terminate()
            child.waitUntilExit()
            let after = sample(me)
            if let start, let running, let after {
                childBusy = cpuPercent(from: start, to: running)
                // Once it has quit and been waited for, its time stays in the total.
                kept = after.cpuNanoseconds >= running.cpuNanoseconds
                keptText = String(format: "%.3f s while running, %.3f s after it quit", Double(running.cpuNanoseconds) / 1e9,
                                  Double(after.cpuNanoseconds) / 1e9)
            }
        }
        check(childBusy > 50 && childBusy < 105,
              String(format: "a child busy for 0.5 s while this process sleeps reads as %.1f%% CPU (50 to 105)", childBusy))
        check(kept, "the child's time stays counted after it quits (this process's total: \(keptText))")

        let gb = UInt64(1_073_741_824)
        let texts: [(String?, Double?, UInt64, String)] = [
            ("Teams", 12.3, gb * 12 / 10, "Teams · CPU 12% · 1.2 GB"),
            (nil, 0.4, 350 * 1_048_576, "CPU 0% · 350 MB"),
            ("Default", nil, 12 * 1_048_576, "Default · CPU … · 12 MB"),
            (nil, 250.6, 3 * gb, "CPU 251% · 3.0 GB"),
            ("Work", 99.5, 1_073_427_251, "Work · CPU 100% · 1.0 GB"),
            (nil, nil, 0, "CPU … · 0 MB"),
        ]
        let mistyped = texts.compactMap { copy, cpu, bytes, expected -> String? in
            let got = text(copy: copy, cpu: cpu, memoryBytes: bytes)
            return got == expected ? nil : "\"\(got)\", not \"\(expected)\""
        }
        check(mistyped.isEmpty, "usage text: copy, CPU and memory; no copy; CPU not measured yet; over 100%; MB rounding up "
              + "to GB; nothing (\(texts.count) cases" + (mistyped.isEmpty ? ")" : "; wrong: " + mistyped.joined(separator: "; ") + ")"))

        // Every regular app: counts and times only.
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var sampled = 0
        var readable = 0
        var slowest: UInt64 = 0
        let started = now()
        for app in apps {
            let before = now()
            if sample(app.processIdentifier) != nil { sampled += 1 }
            slowest = max(slowest, now() - before)
            if arguments(of: app.processIdentifier) != nil { readable += 1 }
        }
        let all = now() - started
        check(sampled == apps.count && !apps.isEmpty,
              String(format: "sampled %d of %d regular apps (slowest %.2f ms; all of them and their command lines %.2f ms)",
                     sampled, apps.count, Double(slowest) / 1e6, Double(all) / 1e6))
        check(readable == apps.count, "read the command lines of \(readable) of \(apps.count) regular apps")

        return (lines + [failures == 0 ? "PASS" : "FAIL: \(failures) failed"]).joined(separator: "\n")
    }
}
