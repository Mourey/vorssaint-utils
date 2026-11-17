// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Carbon.HIToolbox
import Foundation

/// Rewrite with quill: the default-mode preference, the pure support and the
/// runner entry point the clipboard panel hands its text to.
enum QuillRewriteTests {
    static func run(_ suite: TestSuite) {
        preferenceChecks(suite)
        runnerChecks(suite)
        predicateChecks(suite)
        catalogChecks(suite)
        outcomeChecks(suite)
        transitionChecks(suite)
        executableChecks(suite)
        sessionChecks(suite)
        availabilityChecks(suite)
        historyChecks(suite)
        failureLifetimeChecks(suite)
        interfaceContractChecks(suite)
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

    // MARK: Fixtures, copied from quill's src/quill/cli.py at 59ec15f

    /// `quill modes`: id, form, target model, default, name, description.
    static let modesFixture = [
        "task-claude\ttask\tclaude\tyes\tTask prompt for Claude\tRewrites a one-off request as a clear task prompt for Claude models.",
        "task-gpt\ttask\tgpt\tno\tTask prompt for GPT\tRewrites a one-off request as a clear task prompt for OpenAI GPT-6 models.",
        "task-generic\ttask\tgeneric\tno\tTask prompt for any model\tRewrites a one-off request as a clear task prompt for any model.",
        "system-claude\tsystem\tclaude\tno\tSystem prompt for Claude\tRewrites notes or an existing system prompt as standing instructions for Claude models.",
        "system-gpt\tsystem\tgpt\tno\tSystem prompt for GPT\tRewrites notes or an existing system prompt as developer instructions for OpenAI GPT-6 models.",
        "system-generic\tsystem\tgeneric\tno\tSystem prompt for any model\tRewrites notes or an existing system prompt as standing instructions for any model.",
        "skill-claude\tskill\tclaude\tno\tSkill for Claude\tRewrites rough notes as a SKILL.md with frontmatter for Claude models.",
        "skill-gpt\tskill\tgpt\tno\tSkill for GPT\tRewrites rough notes as a SKILL.md with frontmatter for OpenAI GPT-6 models.",
        "skill-generic\tskill\tgeneric\tno\tSkill for any model\tRewrites rough notes as a SKILL.md with frontmatter for any model.",
        "dictation-cleanup\tdictation\tany\tno\tDictation cleanup\tCleans up a dictated transcript, removing fillers and false starts while keeping the speaker's words and meaning.",
    ]

    /// `_report` writes `quill: <code>: <message>` with serve.MESSAGES, and a
    /// parser error writes `quill: usage: <message>`.
    static let codeLines: [(String, QuillRewriteFailure)] = [
        ("quill: no_key: no API key found", .noKey),
        ("quill: timeout: upstream timed out", .timeout),
        ("quill: upstream_error: upstream error", .upstreamError),
        ("quill: unknown_mode: unknown mode", .unknownMode),
        ("quill: bad_request: invalid request", .badRequest),
        ("quill: internal_error: internal error", .internalError),
    ]
    static let usageLine = "quill: usage: argument --surface: invalid choice: 'clipboard' (choose from 'cli')"
    static let statusLine = "quill: rewrote with Task prompt for Claude (anthropic/claude-sonnet-4.5, 812 ms) id=0193f1c2"

    static func stderr(_ lines: String...) -> Data { Data(lines.map { $0 + "\n" }.joined().utf8) }

    // MARK: Predicates (R1.1, R1.2, R2.2)

    static func predicateChecks(_ suite: TestSuite) {
        suite.expect(QuillRewriteSupport.offersRewrite(kind: .text, rewriteAvailable: true, historyAvailable: true),
                     "a text entry offers the rewrite with both features available")
        for kind in [ClipboardHistoryEntryKind.image, .files] {
            suite.expect(!QuillRewriteSupport.offersRewrite(kind: kind, rewriteAvailable: true, historyAvailable: true),
                         "a \(kind.rawValue) entry never offers the rewrite")
        }
        suite.expect(!QuillRewriteSupport.offersRewrite(kind: .text, rewriteAvailable: false, historyAvailable: true)
                     && !QuillRewriteSupport.offersRewrite(kind: .text, rewriteAvailable: true, historyAvailable: false),
                     "the rewrite is offered only while both features are available")

        let returnKey = UInt16(kVK_Return)
        let enterKey = UInt16(kVK_ANSI_KeypadEnter)
        func claims(_ key: UInt16, _ modifiers: NSEvent.ModifierFlags, kind: ClipboardHistoryEntryKind? = .text,
                    rewrite: Bool = true, history: Bool = true) -> Bool {
            QuillRewriteSupport.claimsModePicker(keyCode: key, modifiers: modifiers, selectedKind: kind,
                                                 rewriteAvailable: rewrite, historyAvailable: history)
        }
        suite.expect(claims(returnKey, [.option]) && claims(enterKey, [.option]),
                     "Option+Return and Option+Enter ask for the mode list on a text entry")
        let otherModifiers: [NSEvent.ModifierFlags] = [[], [.shift], [.command], [.option, .shift]]
        suite.expect(otherModifiers.allSatisfy { !claims(returnKey, $0) && !claims(enterKey, $0) },
                     "Return with any other modifiers is left to the existing bindings")
        suite.expect(!claims(returnKey, [.option], kind: .image) && !claims(returnKey, [.option], kind: .files)
                     && !claims(returnKey, [.option], kind: nil),
                     "Option+Return passes through without a selected text entry")
        suite.expect(!claims(returnKey, [.option], rewrite: false) && !claims(returnKey, [.option], history: false),
                     "Option+Return passes through while either feature is unavailable")
        suite.expect(!claims(UInt16(kVK_ANSI_P), [.option]), "Option+P keeps its pin binding")

        suite.expect(QuillRewriteSupport.acceptsResult(.running(modeName: "A"), rewriteAvailable: true),
                     "a running entry accepts its result while the feature is available")
        suite.expect(!QuillRewriteSupport.acceptsResult(.running(modeName: "A"), rewriteAvailable: false)
                     && !QuillRewriteSupport.acceptsResult(nil, rewriteAvailable: true)
                     && !QuillRewriteSupport.acceptsResult(.failed(message: "x"), rewriteAvailable: true)
                     && !QuillRewriteSupport.acceptsResult(.succeeded(original: "a", rewritten: "b", modeName: "A"),
                                                           rewriteAvailable: true),
                     "a result is dropped once the feature is gone or the entry is no longer running")
    }

    // MARK: Modes catalog (R1.3)

    static func catalogChecks(_ suite: TestSuite) {
        let noisy = (modesFixture[0..<3] + ["five\tfields\tonly\tyes\tName"]
                     + modesFixture[3..<6] + ["bad\tform\tmodel\tmaybe\tName\tDescription", ""]
                     + modesFixture[6...]).joined(separator: "\n") + "\n"
        let modes = QuillRewriteSupport.parseModes(noisy)
        suite.expect(modes.map(\.id) == ["task-claude", "task-gpt", "task-generic", "system-claude", "system-gpt",
                                         "system-generic", "skill-claude", "skill-gpt", "skill-generic",
                                         "dictation-cleanup"],
                     "the catalog keeps quill's order and skips malformed lines, got \(modes.map(\.id))")
        suite.expect(modes.filter(\.isDefault).map(\.id) == ["task-claude"]
                     && modes.first?.name == "Task prompt for Claude"
                     && modes.last?.form == "dictation" && modes.last?.targetModel == "any",
                     "each mode keeps its columns, and quill's default row is marked")

        let resolve = QuillRewriteSupport.resolveMode(stored:catalog:)
        suite.expect(resolve("task-gpt", modes) == "task-gpt", "(a) a stored mode in the catalog is used")
        suite.expect(resolve("", modes) == "task-claude", "(b) no stored mode falls back to quill's default")
        suite.expect(resolve("retired-mode", modes) == "task-claude",
                     "a stored mode quill no longer has falls back to quill's default")
        suite.expect(resolve("task-gpt", nil) == "task-gpt",
                     "(c) the stored mode is used as is when the catalog could not be loaded")
        suite.expect(resolve("", nil) == nil, "(d) with neither, no mode resolves")
        let noDefault = modes.filter { !$0.isDefault }
        suite.expect(resolve("", noDefault) == nil && resolve("retired-mode", noDefault) == nil,
                     "a catalog without a default row resolves only a stored mode it holds")
    }

    // MARK: Outcome and messages (R2.2, R2.3)

    static func outcomeChecks(_ suite: TestSuite) {
        let outcome = QuillRewriteSupport.outcome(status:stdout:stderr:timedOut:)
        suite.expect(outcome(0, Data("Fixed.\n".utf8), stderr(statusLine), false) == .success("Fixed.\n"),
                     "a clean exit returns stdout exactly as quill wrote it")
        let input = Data("Secret draft about the merger".utf8)
        for (line, failure) in codeLines {
            suite.expect(outcome(1, input, stderr(line), false) == .failure(failure),
                         "\(line) maps to its own failure")
        }
        suite.expect(outcome(1, input, stderr(usageLine), false) == .failure(.usage),
                     "an argument error maps to usage")
        suite.expect(outcome(1, input, stderr("quill: fake transport from /x", statusLine, codeLines[1].0), false)
                         == .failure(.timeout),
                     "a multi-line stderr maps by its last code line")
        suite.expect(outcome(1, input, stderr("quill: rate_limited: slow down"), false) == .failure(.unknown("rate_limited")),
                     "an unknown code maps to unknown")
        suite.expect(outcome(1, input, Data("Traceback\n".utf8), false) == .failure(.unknown("")),
                     "a failure without a code line maps to unknown")
        suite.expect(outcome(-1, Data(), Data(), true) == .failure(.deadline)
                     && outcome(0, Data("Fixed.\n".utf8), stderr(statusLine), true) == .failure(.deadline),
                     "a run stopped at the timeout maps to deadline, whatever it printed")
        suite.expect(outcome(-1, Data(), Data(), false) == .failure(.launchFailed),
                     "a child that never started maps to launchFailed")
        suite.expect(outcome(0, Data(), stderr(statusLine), false) == .failure(.noOutput)
                     && outcome(0, Data([0xFF, 0xFE]), stderr(statusLine), false) == .failure(.noOutput),
                     "a clean exit with empty or non-UTF-8 stdout maps to noOutput")
        if case .success = outcome(1, input, stderr(codeLines[2].0), false) {
            suite.expect(false, "the original that quill echoes on failure is never taken as a rewrite")
        } else {
            suite.expect(true, "the original that quill echoes on failure is never taken as a rewrite")
        }

        let failures: [QuillRewriteFailure] = codeLines.map(\.1) + [
            .usage, .notFound, .deadline, .launchFailed, .noOutput, .modesUnavailable, .unknown("rate_limited"),
        ]
        let messages = failures.map { QuillRewriteSupport.message(for: $0) }
        suite.expect(Set(messages).count == failures.count && messages.allSatisfy { !$0.isEmpty },
                     "every failure has a message of its own")
        suite.expect(QuillRewriteSupport.message(for: .usage).lowercased().contains("update quill"),
                     "the usage message tells to update quill")
        let text = String(decoding: input, as: UTF8.self)
        suite.expect(messages.allSatisfy { !$0.contains(text) && !$0.contains("merger") }
                     && codeLines.allSatisfy { !messages.contains($0.0) },
                     "no message repeats the input or quill's stderr")
        suite.expect(QuillRewriteSupport.message(for: .unknown("x"))
                         == QuillRewriteSupport.message(for: .unknown("y")),
                     "an unknown code never reaches the message text")
    }

    // MARK: Transitions (R2.1)

    static func transitionChecks(_ suite: TestSuite) {
        let step = QuillRewriteSupport.transition(_:_:)
        let running = QuillRewriteState.running(modeName: "Task prompt for Claude")
        suite.expect(step(nil, .start(modeName: "Task prompt for Claude")) == running, "idle starts running")
        suite.expect(step(running, .succeed(original: "a", rewritten: "b"))
                         == .succeeded(original: "a", rewritten: "b", modeName: "Task prompt for Claude"),
                     "running succeeds with the before and after text")
        suite.expect(step(running, .fail(message: "m")) == .failed(message: "m"), "running fails with a message")
        suite.expect(step(running, .start(modeName: "Other")) == running,
                     "a running entry does not restart")
        suite.expect(step(nil, .succeed(original: "a", rewritten: "b")) == nil
                         && step(.failed(message: "m"), .succeed(original: "a", rewritten: "b")) == .failed(message: "m"),
                     "a result reaches only a running entry")
        let succeeded = QuillRewriteState.succeeded(original: "a", rewritten: "b", modeName: "M")
        suite.expect(step(succeeded, .start(modeName: "M")) == .running(modeName: "M")
                         && step(.failed(message: "m"), .start(modeName: "M")) == .running(modeName: "M"),
                     "the next rewrite of an entry replaces its held result")
        suite.expect([nil, running, succeeded, .failed(message: "m")].allSatisfy { step($0, .discard) == nil },
                     "discard returns any state to idle")
    }

    // MARK: Executable and invocation (R1.4)

    static func temporaryHome() -> String {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuillRewriteTests-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: home + "/.local/bin", withIntermediateDirectories: true)
        return home
    }

    static func installQuill(in home: String, permissions: Int = 0o755) {
        let path = home + "/.local/bin/quill"
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\nexit 1\n".utf8),
                                       attributes: [.posixPermissions: permissions])
    }

    static func executableChecks(_ suite: TestSuite) {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let path = home + "/.local/bin/quill"
        suite.expect(QuillRewriteSupport.executable(home: home) == nil, "a missing quill is not found")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        suite.expect(QuillRewriteSupport.executable(home: home) == nil, "a directory named quill is not found")
        try? FileManager.default.removeItem(atPath: path)
        installQuill(in: home, permissions: 0o644)
        suite.expect(QuillRewriteSupport.executable(home: home) == nil, "a quill that is not executable is not found")
        try? FileManager.default.removeItem(atPath: path)
        installQuill(in: home)
        suite.expect(QuillRewriteSupport.executable(home: home) == path, "an executable quill is found at its path")

        let linked = temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: linked) }
        try? FileManager.default.createSymbolicLink(atPath: linked + "/.local/bin/quill", withDestinationPath: path)
        suite.expect(QuillRewriteSupport.executable(home: linked) == linked + "/.local/bin/quill",
                     "a link to an executable quill, as a tool installer leaves it, is found")

        suite.expect(QuillRewriteSupport.environment(home: home)
                         == ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
                     "the environment is built from scratch with HOME and PATH only")
        suite.expect(QuillRewriteSupport.arguments(mode: "task-claude")
                         == ["rewrite", "--mode", "task-claude", "--surface", "clipboard"],
                     "a rewrite passes exactly the mode and the clipboard surface")
    }

    // MARK: Session (R1.3, R1.4, R2.1, R2.2, R4.1)

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [QuillRewriteInvocation] = []
        var answer: (QuillRewriteInvocation) -> BoundedProcessRunner.SplitResult

        init(answer: @escaping (QuillRewriteInvocation) -> BoundedProcessRunner.SplitResult) {
            self.answer = answer
        }

        var invocations: [QuillRewriteInvocation] { lock.withLock { recorded } }

        func run(_ invocation: QuillRewriteInvocation, _ cancellation: BoundedProcessCancellation)
            -> BoundedProcessRunner.SplitResult {
            lock.withLock { recorded.append(invocation) }
            return answer(invocation)
        }
    }

    static func result(_ status: Int32, _ output: String, _ errors: Data = Data(),
                       timedOut: Bool = false) -> BoundedProcessRunner.SplitResult {
        BoundedProcessRunner.SplitResult(status: status, output: Data(output.utf8), errorOutput: errors,
                                         timedOut: timedOut)
    }

    static func sessionChecks(_ suite: TestSuite) {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        installQuill(in: home)
        let recorder = Recorder { invocation in
            invocation.arguments == ["modes"]
                ? result(0, modesFixture.joined(separator: "\n") + "\n")
                : result(0, "Fixed.\n", stderr(statusLine))
        }
        let session = QuillRewriteSession(home: home, runner: recorder.run, isAvailable: { true },
                                          background: { $0() }, deliver: { $0() })

        session.loadModes()
        let modesCall = recorder.invocations.last
        suite.expect(modesCall?.executable == home + "/.local/bin/quill" && modesCall?.arguments == ["modes"]
                     && modesCall?.environment == QuillRewriteSupport.environment(home: home)
                     && modesCall?.timeout == 5 && modesCall?.maxOutputBytes == 256 * 1_024
                     && modesCall?.maxErrorBytes == 64 * 1_024 && modesCall?.input.isEmpty == true,
                     "the catalog loads with quill modes, the scratch environment, 5 s and its two caps")
        suite.expect(session.catalog?.count == 10 && session.catalog?.first?.isDefault == true,
                     "the loaded catalog is held by the session")

        let a = ClipboardHistoryEntry(text: "fix this sentance")
        let b = ClipboardHistoryEntry(text: "another entry")
        let history = [a, b]
        let before = history
        let started = session.start(entryID: a.id, text: a.text, modeID: "task-claude", storedMode: "")
        let rewrite = recorder.invocations.last
        suite.expect(started == .started, "a rewrite starts")
        suite.expect(rewrite?.executable == home + "/.local/bin/quill" && rewrite?.executable != "/bin/sh",
                     "the rewrite runs quill itself, never a shell")
        suite.expect(rewrite?.arguments == ["rewrite", "--mode", "task-claude", "--surface", "clipboard"]
                     && rewrite.map { Set($0.environment.keys) } == ["HOME", "PATH"]
                     && rewrite?.timeout == 10 && rewrite?.maxOutputBytes == 8 * 1_024 * 1_024
                     && rewrite?.maxErrorBytes == 64 * 1_024 && rewrite?.input == Data(a.text.utf8),
                     "the rewrite passes its arguments, environment, timeout, caps and the entry's UTF-8")
        suite.expect(session.state(for: a.id)
                         == .succeeded(original: a.text, rewritten: "Fixed.\n", modeName: "Task prompt for Claude"),
                     "the entry holds the before and after text, got \(String(describing: session.state(for: a.id)))")
        suite.expect(session.state(for: b.id) == nil && history == before,
                     "the other entry has no state, and the history is untouched")

        _ = session.start(entryID: b.id, text: b.text, modeID: nil, storedMode: "")
        suite.expect(recorder.invocations.last?.arguments.dropFirst(2).first == "task-claude",
                     "a default rewrite resolves quill's default row from the catalog")
        _ = session.start(entryID: b.id, text: b.text, modeID: nil, storedMode: "task-gpt")
        suite.expect(recorder.invocations.last?.arguments.dropFirst(2).first == "task-gpt",
                     "a default rewrite uses the stored mode when the catalog has it")

        session.discard(entryID: a.id)
        suite.expect(session.state(for: a.id) == nil, "discard clears the held result")

        recorder.answer = { _ in result(1, "fix this sentance", stderr(codeLines[0].0)) }
        _ = session.start(entryID: a.id, text: a.text, modeID: "task-claude", storedMode: "")
        suite.expect(session.state(for: a.id) == .failed(message: QuillRewriteSupport.message(for: .noKey)),
                     "a failed run holds its message, never the echoed original")

        let calls = recorder.invocations.count
        let missing = temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: missing) }
        let lost = QuillRewriteSession(home: missing, runner: recorder.run, isAvailable: { true },
                                       background: { $0() }, deliver: { $0() })
        suite.expect(lost.start(entryID: a.id, text: a.text, modeID: "task-claude", storedMode: "")
                         == .failed(.notFound)
                     && lost.state(for: a.id) == .failed(message: QuillRewriteSupport.message(for: .notFound))
                     && recorder.invocations.count == calls,
                     "a missing quill fails as not found without running anything")
        let unresolved = QuillRewriteSession(home: home, runner: recorder.run, isAvailable: { true },
                                             background: { $0() }, deliver: { $0() })
        suite.expect(unresolved.start(entryID: a.id, text: a.text, modeID: nil, storedMode: "")
                         == .failed(.modesUnavailable)
                     && recorder.invocations.count == calls,
                     "a default rewrite with no catalog and no stored mode fails as modesUnavailable")
    }

    // MARK: Availability and one at a time (R2.1, R4.1)

    static func availabilityChecks(_ suite: TestSuite) {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        installQuill(in: home)
        let recorder = Recorder { _ in result(0, "Fixed.\n") }
        let off = QuillRewriteSession(home: home, runner: recorder.run, isAvailable: { false },
                                      background: { $0() }, deliver: { $0() })
        let entry = ClipboardHistoryEntry(text: "draft")
        suite.expect(off.start(entryID: entry.id, text: entry.text, modeID: "task-claude", storedMode: "")
                         == .unavailable,
                     "start refuses while the feature is unavailable")
        off.loadModes()
        suite.expect(recorder.invocations.isEmpty, "nothing runs while the feature is unavailable")

        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = true
            var isOn: Bool {
                get { lock.withLock { value } }
                set { lock.withLock { value = newValue } }
            }
        }
        let available = Flag()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let deliveries = DispatchQueue(label: "QuillRewriteTests.deliver")
        let blocking = Recorder { _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            return result(0, "Fixed.\n")
        }
        let cancellation = BoundedProcessCancellation()
        let session = QuillRewriteSession(home: home, runner: blocking.run, isAvailable: { available.isOn },
                                          makeCancellation: { cancellation },
                                          background: { work in
                                              DispatchQueue.global().async { work(); finished.signal() }
                                          },
                                          deliver: { deliveries.async(execute: $0) })
        let other = ClipboardHistoryEntry(text: "other")
        suite.expect(session.start(entryID: entry.id, text: entry.text, modeID: "task-claude", storedMode: "")
                         == .started,
                     "the first rewrite starts")
        let ran = entered.wait(timeout: .now() + 5) == .success
        suite.expect(ran && session.state(for: entry.id) == .running(modeName: "task-claude"),
                     "the entry shows running while quill works")
        suite.expect(session.start(entryID: other.id, text: other.text, modeID: "task-claude", storedMode: "")
                         == .refused
                     && session.start(entryID: entry.id, text: entry.text, modeID: "task-claude", storedMode: "")
                         == .refused,
                     "no second rewrite starts while one runs anywhere in the panel")
        suite.expect(blocking.invocations.count == 1, "the runner was called once")

        available.isOn = false
        session.syncAvailability()
        suite.expect(cancellation.isCancelled, "turning the feature off cancels the run in flight")
        suite.expect(session.state(for: entry.id) == nil, "turning the feature off leaves no state for the entry")
        release.signal()
        _ = finished.wait(timeout: .now() + 5)
        deliveries.sync {}
        suite.expect(session.state(for: entry.id) == nil && session.state(for: other.id) == nil,
                     "the cancelled run's result is dropped when it arrives")
        suite.expect(!session.isRunning, "nothing is left running")
    }

    // MARK: History insert (R3.1)

    static func historyChecks(_ suite: TestSuite) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var pinned = ClipboardHistoryEntry(text: "pinned", copiedAt: now.addingTimeInterval(-300),
                                           pinnedAt: now.addingTimeInterval(-200))
        pinned.sourceBundleID = "com.example.pinned"
        var first = ClipboardHistoryEntry(text: "first recent", copiedAt: now.addingTimeInterval(-60))
        first.sourceBundleID = "com.example.first"
        let second = ClipboardHistoryEntry(text: "second recent", copiedAt: now.addingTimeInterval(-120))
        let history = [pinned, first, second]
        let add = ClipboardHistoryEditing.entriesAddingText(_:to:now:rejectsSensitive:)

        let added = add("new", history, now, true)
        suite.expect(added?.entries.count == 4
                     && added?.entries.first == pinned
                     && added?.entries.dropFirst(2).map(\.id) == [first.id, second.id]
                     && added?.entries.dropFirst(2).map(\.text) == [first.text, second.text],
                     "adding a text keeps every entry with its id and text")
        suite.expect(added?.entries[1].text == "new" && added?.entries[1].sourceBundleID == nil
                     && added?.entries[1].isPinned == false && added?.entries[1].copiedAt == now
                     && added?.entry == added?.entries[1],
                     "the new text lands first among the recent entries with no source app")

        let moved = add("  second recent\n", history, now, true)
        suite.expect(moved?.entries.map(\.id) == [pinned.id, second.id, first.id]
                     && moved?.entries.filter { $0.text == second.text }.count == 1
                     && moved?.entry.id == second.id && moved?.entry.copiedAt == now,
                     "a text already in the history moves that entry and keeps its id, without a duplicate")

        let sensitive = "STRIPE_SECRET_KEY=exampleCredential"
        for refused in ["", "  \n\t ", String(repeating: "a", count: ClipboardHistoryEditing.maxCharacters + 1)] {
            suite.expect(add(refused, history, now, false) == nil,
                         "an empty, blank or oversized text is refused (\(refused.count) characters)")
        }
        suite.expect(add(sensitive, history, now, true) == nil,
                     "a sensitive-looking text is refused while the sensitive filter is on")
        suite.expect(add(sensitive, history, now, false)?.entries[1].text == sensitive,
                     "a sensitive-looking text is kept while the sensitive filter is off")

        let service = (try? String(contentsOfFile: "Sources/Vorssaint/Services/Clipboard/ClipboardHistoryService.swift",
                                   encoding: .utf8)) ?? ""
        let body = service.components(separatedBy: "    func addRewrittenText(").dropFirst().first?
            .components(separatedBy: "\n    }\n").first ?? ""
        let calls = ["ClipboardHistoryEditing.entriesAddingText(", "trimToLimit()", "save()"]
            .map { body.range(of: $0)?.lowerBound }
        suite.expect(calls.allSatisfy { $0 != nil }
                     && zip(calls, calls.dropFirst()).allSatisfy { $0! < $1! },
                     "addRewrittenText adds through entriesAddingText, then trims and saves")
    }

    // MARK: Failure lifetime (R2.3, C5)

    static func failureLifetimeChecks(_ suite: TestSuite) {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        installQuill(in: home)
        let failing = ClipboardHistoryEntry(text: "fails")
        let passing = ClipboardHistoryEntry(text: "passes")
        let recorder = Recorder { invocation in
            invocation.input == Data(failing.text.utf8)
                ? result(1, failing.text, stderr(codeLines[0].0)) : result(0, "Passed.\n")
        }
        let session = QuillRewriteSession(home: home, runner: recorder.run, isAvailable: { true },
                                          background: { $0() }, deliver: { $0() })
        session.start(entryID: failing.id, text: failing.text, modeID: "task-claude", storedMode: "")
        session.start(entryID: passing.id, text: passing.text, modeID: "task-claude", storedMode: "")
        session.clearFailures()
        suite.expect(session.state(for: failing.id) == nil
                     && session.state(for: passing.id)
                         == .succeeded(original: passing.text, rewritten: "Passed.\n", modeName: "task-claude"),
                     "reopening the panel drops failure messages and keeps held results")
    }

    // MARK: Interface source contracts (R1.1, R1.2, R1.3, R2.1, R2.2, R3.1, R3.2, R4.1)

    static func source(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// The text after `marker` up to the end of that member, at the usual
    /// four-space indent.
    static func body(_ source: String, after marker: String, end: String = "\n    }\n") -> String {
        source.components(separatedBy: marker).dropFirst().first?.components(separatedBy: end).first ?? ""
    }

    static func ordered(_ text: String, _ calls: [String]) -> Bool {
        var cursor = text.startIndex
        for call in calls {
            guard let range = text.range(of: call, range: cursor..<text.endIndex) else { return false }
            cursor = range.upperBound
        }
        return true
    }

    static func count(_ text: String, _ needle: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    static func interfaceContractChecks(_ suite: TestSuite) {
        let panel = source("Sources/Vorssaint/UI/MenuPanel/ClipboardQuickPanelView.swift")
        let sidebar = source("Sources/Vorssaint/UI/MenuPanel/ClipboardEntryPreviewSidebar.swift")
        let history = source("Sources/Vorssaint/Services/Clipboard/ClipboardHistoryService.swift")
        let service = source("Sources/Vorssaint/Services/Clipboard/QuillRewriteService.swift")
        let support = source("Sources/Vorssaint/Services/Clipboard/QuillRewriteSupport.swift")
        let settings = source("Sources/Vorssaint/UI/Settings/ClipboardSettings.swift")
        let runtime = source("Sources/Vorssaint/App/FeatureRuntime.swift")
        suite.expect(![panel, sidebar, history, service, support, settings, runtime].contains(where: \.isEmpty),
                     "every interface source reads back for its contract")

        // R1.1: the six actions keep their order, and the rewrite items follow.
        let actions = body(panel, after: "    private func entryActions(")
        suite.expect(ordered(actions, ["history.copyQuickEntry(entry)", "history.copyOnlyQuickEntry(entry)",
                                       "history.togglePin(entry)", "history.move(entry, .up)",
                                       "history.move(entry, .down)", "history.remove(entry)",
                                       "QuillRewriteSupport.offersRewrite(",
                                       "QuillRewriteService.shared.start(entry: entry, modeID: nil)",
                                       "QuillRewriteService.shared.start(entry: entry, modeID: mode.id)"]),
                     "the entry actions keep their six in order, then offer the rewrite and its mode submenu")
        let picker = body(panel, after: "    private var modePicker: some View {")
        let starts = "QuillRewriteService.shared.start("
        suite.expect(count(actions, starts) == 2 && count(picker, starts) == 1
                     && count(panel, starts) == count(actions, starts) + count(picker, starts)
                     && [sidebar, history, settings, runtime].allSatisfy { !$0.contains(starts) },
                     "only the entry actions and the Option+Return popover start a rewrite")

        // R1.2: Option+Return claims the key before the Return block lets it pass.
        let monitor = body(history, after: "    private func installKeyMonitor(for panel: NSPanel) {")
        let afterPlainReturn = monitor.components(separatedBy: "self.copySelectedQuickEntry()").dropFirst().first ?? ""
        let beforeClaim = afterPlainReturn.components(separatedBy: "QuillRewriteSupport.claimsModePicker(").first ?? ""
        suite.expect(afterPlainReturn.contains("QuillRewriteSupport.claimsModePicker(")
                     && !beforeClaim.contains("return event")
                     && ordered(afterPlainReturn, ["QuillRewriteSupport.claimsModePicker(",
                                                   "QuillRewriteService.shared.showModePicker(", "return nil",
                                                   "return event"]),
                     "Option+Return asks for the mode list before the Return block returns the event")
        let bindings = ["toggleSelectedQuickEntryBatchSelection", "copySelectedQuickEntryOnly", "copySelectedQuickEntry",
                        "selectAllQuickEntries", "togglePinSelectedQuickEntry", "removeSelectedQuickEntries",
                        "moveQuickSelection", "copyQuickEntry(at:", "toggleQuickPreview"]
        suite.expect(bindings.allSatisfy { monitor.contains($0) },
                     "every existing binding of the key monitor stays in place")

        // R1.2, R2.1: the row redraws for its rewrite state and its popover.
        let equality = body(panel, after: "    static func == (lhs: QuickEntryView, rhs: QuickEntryView) -> Bool {")
        suite.expect(equality.contains("lhs.rewriteState == rhs.rewriteState")
                     && equality.contains("lhs.showsModePicker == rhs.showsModePicker"),
                     "QuickEntryView compares its rewrite state and whether it shows the mode list")
        suite.expect(panel.contains(".accessibilityLabel(rewriteText.rewriting)"),
                     "the row's progress reads as Rewriting… to VoiceOver")

        // R3.1, R3.2: Use and Copy add the entry first, and copy nothing when it is refused.
        for (handler, copy) in [("    private func useRewrite(", "ClipboardHistoryService.shared.copyQuickEntry("),
                                ("    private func copyRewrite(", "ClipboardHistoryService.shared.copyOnlyQuickEntry(")] {
            let code = body(sidebar, after: handler)
            let refused = code.components(separatedBy: "addRewrittenText(").dropFirst().first?
                .components(separatedBy: "else {").dropFirst().first?
                .components(separatedBy: "}").first ?? "copy"
            suite.expect(code.contains("guard let added = ClipboardHistoryService.shared.addRewrittenText(")
                         && ordered(code, ["addRewrittenText(", copy + "added)"])
                         && refused.contains("return") && !refused.contains("copy"),
                         "\(handler.trimmingCharacters(in: .whitespaces)) adds the rewrite, then copies it, and copies nothing when it is refused")
        }
        let footer = body(sidebar, after: "    private func rewriteFooter(")
        suite.expect(ordered(footer, ["rewriteText.discard", "rewriteText.copy", "rewriteText.use"])
                     && !footer.contains("beginEditing"),
                     "a held result offers Discard, Copy and Use, and no Edit")
        suite.expect(sidebar.contains(".accessibilityLabel(rewriteText.before)")
                     && sidebar.contains(".accessibilityLabel(rewriteText.after)"),
                     "Before and After are labelled for VoiceOver")

        // R4.1: the settings picker shows only with the feature installed.
        let gated = settings.components(separatedBy: "if AppFeature.quillRewrite.isAvailable {").dropFirst().first ?? ""
        suite.expect(gated.prefix(120).contains("QuillRewriteModeSection(")
                     && count(settings, "QuillRewriteModeSection(") == 1,
                     "the default-mode picker is shown only under AppFeature.quillRewrite.isAvailable")

        // R1.3, R2: quill runs only on a background queue, results land on main.
        suite.expect(count(service, "BoundedProcessRunner.run(") == 1
                     && service.contains("background: { work in DispatchQueue.global(qos: .userInitiated).async(execute: work) }")
                     && service.contains("deliver: { work in DispatchQueue.main.async(execute: work) }"),
                     "the service hands the runner a global queue and delivers on the main queue")
        let runs = support.components(separatedBy: "runner(invocation")
        suite.expect(runs.count == 3 && runs.dropLast().allSatisfy { $0.suffix(80).contains("background { [self] in") },
                     "the session calls the runner only inside its background block")
        suite.expect(service.contains("strings: { QuillRewriteStrings.localized(L10n.shared.language) }"),
                     "messages follow the app's language")

        // R2.2: success selects the entry and presents the preview.
        let reveal = body(service, after: "    private func reveal(")
        suite.expect(service.contains("session.onSuccess = { [weak self] id in self?.reveal(id) }")
                     && ordered(reveal, ["AppFeature.quillRewrite.isAvailable", "selectRewrittenEntry(",
                                         "setQuickPreviewPresented(true)"]),
                     "a finished rewrite selects its entry and opens the preview")

        // R1.3: the catalog refreshes each time the panel opens.
        let show = body(history, after: "    func showHistoryWindow(preferNotch: Bool = true) {")
        suite.expect(ordered(show, ["routesClipboardWindow()", "QuillRewriteService.refreshForPanel()"]),
                     "opening the panel refreshes the modes catalog")

        // R4.1: turning the feature off cancels the run in flight.
        let cancel = body(service, after: "    static func cancelIfUnavailable() {")
        suite.expect(runtime.contains(".quillRewrite: { QuillRewriteService.cancelIfUnavailable() }")
                     && cancel.contains("syncAvailability()"),
                     "the feature's binding cancels a run once the feature is unavailable")
    }
}
