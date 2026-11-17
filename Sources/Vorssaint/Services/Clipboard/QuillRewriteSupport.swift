// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Carbon.HIToolbox
import Foundation

/// One row of `quill modes`: id, form, target model, whether it is quill's
/// default, name and description, tab-separated, in quill's order.
struct QuillRewriteMode: Equatable {
    let id: String
    let form: String
    let targetModel: String
    let isDefault: Bool
    let name: String
    let summary: String
}

/// Why a rewrite produced nothing usable. The first seven come from quill's
/// own error line; the rest are what the app itself can tell.
enum QuillRewriteFailure: Equatable {
    case noKey, timeout, upstreamError, unknownMode, badRequest, internalError, usage
    case notFound, deadline, launchFailed, noOutput, modesUnavailable
    case unknown(String)
}

enum QuillRewriteOutcome: Equatable {
    case success(String)
    case failure(QuillRewriteFailure)
}

/// What one history entry shows of a rewrite. No state means idle.
enum QuillRewriteState: Equatable {
    case running(modeName: String)
    case succeeded(original: String, rewritten: String, modeName: String)
    case failed(message: String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

enum QuillRewriteEvent: Equatable {
    case start(modeName: String)
    case succeed(original: String, rewritten: String)
    case fail(message: String)
    case discard
}

/// Everything one quill run needs, handed to the injected runner.
struct QuillRewriteInvocation: Equatable {
    let executable: String
    let arguments: [String]
    let input: Data
    let timeout: TimeInterval
    let maxOutputBytes: Int
    let maxErrorBytes: Int
    let environment: [String: String]
}

enum QuillRewriteSupport {
    static let rewriteTimeout: TimeInterval = 10
    static let rewriteMaxOutputBytes = 8 * 1_024 * 1_024
    static let rewriteMaxErrorBytes = 64 * 1_024
    static let modesTimeout: TimeInterval = 5
    static let modesMaxOutputBytes = 256 * 1_024
    static let modesMaxErrorBytes = 64 * 1_024

    // MARK: Predicates

    /// Only text entries, and only while both the rewrite and the history
    /// itself are installed.
    static func offersRewrite(kind: ClipboardHistoryEntryKind,
                              rewriteAvailable: Bool,
                              historyAvailable: Bool) -> Bool {
        kind == .text && rewriteAvailable && historyAvailable
    }

    /// Option+Return (or Option+Enter) on a selected text entry. Anything else
    /// stays with the panel's existing bindings.
    static func claimsModePicker(keyCode: UInt16,
                                 modifiers: NSEvent.ModifierFlags,
                                 selectedKind: ClipboardHistoryEntryKind?,
                                 rewriteAvailable: Bool,
                                 historyAvailable: Bool) -> Bool {
        guard keyCode == UInt16(kVK_Return) || keyCode == UInt16(kVK_ANSI_KeypadEnter),
              modifiers.intersection([.command, .option, .shift, .control]) == [.option],
              let selectedKind
        else { return false }
        return offersRewrite(kind: selectedKind, rewriteAvailable: rewriteAvailable,
                             historyAvailable: historyAvailable)
    }

    /// A finished run lands only on an entry still waiting for it, and only
    /// while the feature is still installed.
    static func acceptsResult(_ state: QuillRewriteState?, rewriteAvailable: Bool) -> Bool {
        rewriteAvailable && state?.isRunning == true
    }

    // MARK: Modes

    /// Lines without six fields, or without a yes or no default column, are
    /// skipped rather than guessed at.
    static func parseModes(_ output: String) -> [QuillRewriteMode] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 6, fields[3] == "yes" || fields[3] == "no", !fields[0].isEmpty else { return nil }
            return QuillRewriteMode(id: fields[0], form: fields[1], targetModel: fields[2],
                                    isDefault: fields[3] == "yes", name: fields[4], summary: fields[5])
        }
    }

    /// The stored mode when quill still has it, else quill's default row, else
    /// the stored mode as is when the catalog could not be read, else none.
    static func resolveMode(stored: String, catalog: [QuillRewriteMode]?) -> String? {
        if let catalog {
            if !stored.isEmpty, catalog.contains(where: { $0.id == stored }) { return stored }
            return catalog.first(where: \.isDefault)?.id
        }
        return stored.isEmpty ? nil : stored
    }

    // MARK: Results

    /// Success needs a clean exit inside the deadline and UTF-8 text on
    /// stdout. On failure quill echoes its input to stdout, so a failed run's
    /// stdout is never read.
    static func outcome(status: Int32, stdout: Data, stderr: Data, timedOut: Bool) -> QuillRewriteOutcome {
        if timedOut { return .failure(.deadline) }
        if status == 0 {
            guard !stdout.isEmpty, let text = String(data: stdout, encoding: .utf8), !text.isEmpty else {
                return .failure(.noOutput)
            }
            return .success(text)
        }
        if let code = errorCode(in: stderr) { return .failure(failure(code: code)) }
        return .failure(status == -1 ? .launchFailed : .unknown(""))
    }

    /// The code of the last stderr line shaped `quill: <code>: …`.
    static func errorCode(in stderr: Data) -> String? {
        let lines = String(decoding: stderr, as: UTF8.self).split(whereSeparator: \.isNewline)
        for line in lines.reversed() {
            guard line.hasPrefix("quill: ") else { continue }
            let rest = line.dropFirst("quill: ".count)
            guard let colon = rest.firstIndex(of: ":") else { continue }
            let code = rest[..<colon]
            let tail = rest[colon...]
            guard !code.isEmpty, tail.hasPrefix(": "),
                  code.allSatisfy({ ("a"..."z").contains($0) || $0 == "_" })
            else { continue }
            return String(code)
        }
        return nil
    }

    static func failure(code: String) -> QuillRewriteFailure {
        switch code {
        case "no_key": return .noKey
        case "timeout": return .timeout
        case "upstream_error": return .upstreamError
        case "unknown_mode": return .unknownMode
        case "bad_request": return .badRequest
        case "internal_error": return .internalError
        case "usage": return .usage
        default: return .unknown(code)
        }
    }

    /// A sentence naming the cause. It never quotes stderr or the entry.
    static func message(for failure: QuillRewriteFailure, strings: QuillRewriteStrings = .english) -> String {
        switch failure {
        case .noKey: return strings.messageNoKey
        case .timeout: return strings.messageTimeout
        case .upstreamError: return strings.messageUpstreamError
        case .unknownMode: return strings.messageUnknownMode
        case .badRequest: return strings.messageBadRequest
        case .internalError: return strings.messageInternalError
        case .usage: return strings.messageUsage
        case .notFound: return strings.messageNotFound
        case .deadline: return strings.messageDeadline
        case .launchFailed: return strings.messageLaunchFailed
        case .noOutput: return strings.messageNoOutput
        case .modesUnavailable: return strings.messageModesUnavailable
        case .unknown: return strings.messageUnknown
        }
    }

    // MARK: Invocation

    /// `~/.local/bin/quill`, used only when it resolves to a regular,
    /// executable file. No other place is searched.
    static func executable(home: String, fileManager: FileManager = .default) -> String? {
        let path = (home as NSString).appendingPathComponent(".local/bin/quill")
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let type = (try? fileManager.attributesOfItem(atPath: resolved))?[.type] as? FileAttributeType,
              type == .typeRegular,
              fileManager.isExecutableFile(atPath: resolved)
        else { return nil }
        return path
    }

    /// Built from scratch, so nothing in the app's own environment reaches
    /// quill: it finds its key on its own.
    static func environment(home: String) -> [String: String] {
        ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    }

    static func arguments(mode: String) -> [String] {
        ["rewrite", "--mode", mode, "--surface", "clipboard"]
    }

    // MARK: State

    static func transition(_ state: QuillRewriteState?, _ event: QuillRewriteEvent) -> QuillRewriteState? {
        switch (state, event) {
        case (_, .discard):
            return nil
        case (.running?, .start):
            return state
        case (_, .start(let modeName)):
            return .running(modeName: modeName)
        case (.running(let modeName)?, .succeed(let original, let rewritten)):
            return .succeeded(original: original, rewritten: rewritten, modeName: modeName)
        case (.running?, .fail(let message)):
            return .failed(message: message)
        case (_, .succeed), (_, .fail):
            return state
        }
    }
}

/// The rewrite states of the panel's entries, and the one run allowed at a
/// time. The runner, the availability reader, the cancellation and the two
/// queues are injected: the app runs quill on a background queue and lands
/// results on the main one.
final class QuillRewriteSession: @unchecked Sendable {
    typealias Runner = (QuillRewriteInvocation, BoundedProcessCancellation) -> BoundedProcessRunner.SplitResult

    enum StartResult: Equatable {
        case started
        case refused
        case unavailable
        case failed(QuillRewriteFailure)
    }

    private struct ActiveRun {
        let token: UUID
        let entryID: UUID
        let cancellation: BoundedProcessCancellation
    }

    private let home: String
    private let fileManager: FileManager
    private let runner: Runner
    private let isAvailable: () -> Bool
    private let makeCancellation: () -> BoundedProcessCancellation
    private let background: (@escaping () -> Void) -> Void
    private let deliver: (@escaping () -> Void) -> Void
    private let strings: () -> QuillRewriteStrings
    private let lock = NSLock()
    private var currentStates: [UUID: QuillRewriteState] = [:]
    private var currentCatalog: [QuillRewriteMode]?
    private var active: ActiveRun?

    /// Called on the delivering queue after any state or catalog change.
    var onChange: (() -> Void)?
    /// Called on the delivering queue when an entry's rewrite succeeds.
    var onSuccess: ((UUID) -> Void)?

    init(home: String,
         fileManager: FileManager = .default,
         runner: @escaping Runner,
         isAvailable: @escaping () -> Bool,
         makeCancellation: @escaping () -> BoundedProcessCancellation = { BoundedProcessCancellation() },
         background: @escaping (@escaping () -> Void) -> Void,
         deliver: @escaping (@escaping () -> Void) -> Void,
         strings: @escaping () -> QuillRewriteStrings = { .english }) {
        self.home = home
        self.fileManager = fileManager
        self.runner = runner
        self.isAvailable = isAvailable
        self.makeCancellation = makeCancellation
        self.background = background
        self.deliver = deliver
        self.strings = strings
    }

    var states: [UUID: QuillRewriteState] { lock.withLock { currentStates } }
    var catalog: [QuillRewriteMode]? { lock.withLock { currentCatalog } }
    var isRunning: Bool { lock.withLock { active != nil } }

    func state(for entryID: UUID) -> QuillRewriteState? {
        lock.withLock { currentStates[entryID] }
    }

    /// `modeID` nil asks for the default mode, resolved from `storedMode` and
    /// the loaded catalog.
    @discardableResult
    func start(entryID: UUID, text: String, modeID: String?, storedMode: String) -> StartResult {
        guard isAvailable() else { return .unavailable }
        let copy = strings()
        let result: StartResult
        var launch: (QuillRewriteInvocation, ActiveRun)?
        lock.lock()
        if active != nil || currentStates[entryID]?.isRunning == true {
            result = .refused
        } else if let mode = modeID ?? QuillRewriteSupport.resolveMode(stored: storedMode, catalog: currentCatalog) {
            if let executable = QuillRewriteSupport.executable(home: home, fileManager: fileManager) {
                let name = currentCatalog?.first(where: { $0.id == mode })?.name ?? mode
                currentStates[entryID] = QuillRewriteSupport.transition(currentStates[entryID], .start(modeName: name))
                let run = ActiveRun(token: UUID(), entryID: entryID, cancellation: makeCancellation())
                active = run
                launch = (QuillRewriteInvocation(executable: executable,
                                                 arguments: QuillRewriteSupport.arguments(mode: mode),
                                                 input: Data(text.utf8),
                                                 timeout: QuillRewriteSupport.rewriteTimeout,
                                                 maxOutputBytes: QuillRewriteSupport.rewriteMaxOutputBytes,
                                                 maxErrorBytes: QuillRewriteSupport.rewriteMaxErrorBytes,
                                                 environment: QuillRewriteSupport.environment(home: home)), run)
                result = .started
            } else {
                fail(entryID, .notFound, copy)
                result = .failed(.notFound)
            }
        } else {
            fail(entryID, .modesUnavailable, copy)
            result = .failed(.modesUnavailable)
        }
        lock.unlock()
        if result != .refused { onChange?() }
        if let launch {
            let (invocation, run) = launch
            background { [self] in
                let answer = runner(invocation, run.cancellation)
                deliver { [self] in finish(run, original: text, answer: answer, strings: copy) }
            }
        }
        return result
    }

    /// Takes the entry back to idle: its held result or message is dropped.
    func discard(entryID: UUID) {
        lock.withLock {
            currentStates[entryID] = QuillRewriteSupport.transition(currentStates[entryID], .discard)
        }
        onChange?()
    }

    /// With the feature gone, the run in flight is cancelled and every held
    /// state and the catalog are dropped.
    func syncAvailability() {
        guard !isAvailable() else { return }
        let cancellation: BoundedProcessCancellation? = lock.withLock {
            let running = active?.cancellation
            active = nil
            currentStates.removeAll()
            currentCatalog = nil
            return running
        }
        cancellation?.cancel()
        onChange?()
    }

    /// Reads `quill modes` on the background queue. A failed read leaves no
    /// catalog, so a default rewrite falls back to the stored mode.
    func loadModes() {
        guard isAvailable() else { return }
        guard let executable = QuillRewriteSupport.executable(home: home, fileManager: fileManager) else {
            lock.withLock { currentCatalog = nil }
            onChange?()
            return
        }
        let invocation = QuillRewriteInvocation(executable: executable, arguments: ["modes"], input: Data(),
                                                timeout: QuillRewriteSupport.modesTimeout,
                                                maxOutputBytes: QuillRewriteSupport.modesMaxOutputBytes,
                                                maxErrorBytes: QuillRewriteSupport.modesMaxErrorBytes,
                                                environment: QuillRewriteSupport.environment(home: home))
        let cancellation = makeCancellation()
        background { [self] in
            let answer = runner(invocation, cancellation)
            deliver { [self] in
                guard isAvailable() else { return }
                let modes = answer.status == 0 && !answer.timedOut
                    ? QuillRewriteSupport.parseModes(String(decoding: answer.output, as: UTF8.self)) : []
                lock.withLock { currentCatalog = modes.isEmpty ? nil : modes }
                onChange?()
            }
        }
    }

    private func finish(_ run: ActiveRun, original: String, answer: BoundedProcessRunner.SplitResult,
                        strings: QuillRewriteStrings) {
        let available = isAvailable()
        var succeeded = false
        let accepted: Bool = lock.withLock {
            guard active?.token == run.token else { return false }
            active = nil
            guard QuillRewriteSupport.acceptsResult(currentStates[run.entryID], rewriteAvailable: available) else {
                if !available { currentStates[run.entryID] = nil }
                return true
            }
            let event: QuillRewriteEvent
            switch QuillRewriteSupport.outcome(status: answer.status, stdout: answer.output,
                                               stderr: answer.errorOutput, timedOut: answer.timedOut) {
            case .success(let rewritten):
                event = .succeed(original: original, rewritten: rewritten)
                succeeded = true
            case .failure(let failure):
                event = .fail(message: QuillRewriteSupport.message(for: failure, strings: strings))
            }
            currentStates[run.entryID] = QuillRewriteSupport.transition(currentStates[run.entryID], event)
            return true
        }
        guard accepted else { return }
        onChange?()
        if succeeded { onSuccess?(run.entryID) }
    }

    /// Runs under the lock: a start that cannot launch shows its message.
    private func fail(_ entryID: UUID, _ failure: QuillRewriteFailure, _ strings: QuillRewriteStrings) {
        let started = QuillRewriteSupport.transition(currentStates[entryID], .start(modeName: ""))
        currentStates[entryID] = QuillRewriteSupport.transition(
            started, .fail(message: QuillRewriteSupport.message(for: failure, strings: strings)))
    }
}
