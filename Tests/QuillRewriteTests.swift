// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Rewrite with quill: the default-mode preference, the pure support and the
/// runner entry point the clipboard panel hands its text to.
enum QuillRewriteTests {
    static func run(_ suite: TestSuite) {
        preferenceChecks(suite)
        runnerChecks(suite)
    }

    // MARK: Preference (R4.2)

    static func preferenceChecks(_ suite: TestSuite) {
        suite.expect(SettingsBackupSupport.exportKeys().contains(DefaultsKey.quillRewriteDefaultMode),
                     "settings backup carries the default rewrite mode")
        suite.expect(Defaults.registeredDefaults[DefaultsKey.quillRewriteDefaultMode] as? String == "",
                     "the default rewrite mode is registered empty, meaning quill’s default")
        let registered = Set(Defaults.registeredDefaults.keys.filter { $0.hasPrefix("quillRewrite") })
        suite.expect(registered == [DefaultsKey.quillRewriteDefaultMode],
                     "the default mode is the only registered rewrite preference, got \(registered.sorted())")
    }

    // MARK: Runner entry point (R1.4)

    static func runnerChecks(_ suite: TestSuite) {
        let path = ["PATH": "/usr/bin:/bin"]
        func run(_ executable: String, _ arguments: [String], input: Data, timeout: TimeInterval = 5,
                 maxOutputBytes: Int = 1 << 16, maxErrorBytes: Int = 1 << 16,
                 environment: [String: String]? = nil) -> BoundedProcessRunner.SplitResult {
            BoundedProcessRunner.run(executable, arguments, input: input, timeout: timeout,
                                     maxOutputBytes: maxOutputBytes, maxErrorBytes: maxErrorBytes,
                                     environment: environment ?? path, cancellation: nil)
        }

        let echoed = run("/bin/cat", [], input: Data("héllo".utf8))
        suite.expect(echoed.status == 0 && !echoed.timedOut && echoed.output == Data("héllo".utf8)
                     && echoed.errorOutput.isEmpty,
                     "the runner hands its input to the child on stdin and returns its stdout")

        let split = run("/bin/sh", ["-c", "printf out; printf err >&2; exit 3"], input: Data())
        suite.expect(split.status == 3 && split.output == Data("out".utf8)
                     && split.errorOutput == Data("err".utf8),
                     "the runner keeps stdout and stderr apart and reports the exit status")

        let capped = run("/usr/bin/head", ["-c", "1024", "/dev/zero"], input: Data(), maxOutputBytes: 16)
        suite.expect(capped.status == 0 && capped.output.count == 16,
                     "the runner keeps only the first maxOutputBytes of stdout, got \(capped.output.count)")

        let started = ProcessInfo.processInfo.systemUptime
        let slow = run("/bin/sleep", ["5"], input: Data(), timeout: 0.3)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        suite.expect(slow.timedOut && elapsed < 1.5,
                     "the runner stops a child at its timeout, after \(elapsed)s")

        let large = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let roundTrip = run("/bin/cat", [], input: large, timeout: 10, maxOutputBytes: 2 << 20)
        suite.expect(roundTrip.status == 0 && !roundTrip.timedOut && roundTrip.output == large,
                     "a 1 MiB input round-trips through the child without a deadlock")

        let unread = run("/usr/bin/true", [], input: large, timeout: 10)
        suite.expect(unread.status == 0 && !unread.timedOut,
                     "a child that exits without reading its input ends the run without SIGPIPE")

        let environment = run("/usr/bin/env", [], input: Data(), environment: ["A": "1"])
        suite.expect(environment.status == 0 && environment.output == Data("A=1\n".utf8),
                     "the child sees exactly the environment it was given, got \(String(decoding: environment.output, as: UTF8.self).debugDescription)")
    }
}
