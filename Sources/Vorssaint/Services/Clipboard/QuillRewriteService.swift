// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Rewrite with quill for the clipboard panel, on the main actor. It
/// publishes the session's states, the loaded modes and the entry whose mode
/// list is open, runs quill on a background queue and lands every result on
/// the main queue. Nothing about a rewrite is stored; a held result lives
/// until Use, Copy, Discard, the entry's next rewrite or quit.
@MainActor
final class QuillRewriteService: ObservableObject {
    private static var instance: QuillRewriteService?

    static var shared: QuillRewriteService {
        if let instance { return instance }
        let created = QuillRewriteService()
        instance = created
        return created
    }

    /// The feature binding's hook. It touches only a service that already
    /// exists, so an uninstalled feature never creates one.
    static func cancelIfUnavailable() {
        instance?.session.syncAvailability()
    }

    /// Called as the panel opens: failure messages from the last opening go,
    /// and the modes are read again.
    static func refreshForPanel() {
        guard AppFeature.quillRewrite.isAvailable, AppFeature.clipboardHistory.isAvailable else { return }
        shared.session.clearFailures()
        shared.loadModes()
    }

    @Published private(set) var states: [UUID: QuillRewriteState] = [:]
    @Published private(set) var modes: [QuillRewriteMode]?
    @Published private(set) var isRunning = false
    @Published var modePickerEntryID: UUID?

    private let session: QuillRewriteSession

    private init() {
        session = QuillRewriteSession(
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            // Nonisolated: the session calls it on the background queue.
            runner: { @Sendable invocation, cancellation in
                BoundedProcessRunner.run(invocation.executable, invocation.arguments,
                                         input: invocation.input,
                                         timeout: invocation.timeout,
                                         maxOutputBytes: invocation.maxOutputBytes,
                                         maxErrorBytes: invocation.maxErrorBytes,
                                         environment: invocation.environment,
                                         cancellation: cancellation)
            },
            isAvailable: { AppFeature.quillRewrite.isAvailable },
            background: { work in DispatchQueue.global(qos: .userInitiated).async(execute: work) },
            deliver: { work in DispatchQueue.main.async(execute: work) },
            strings: { QuillRewriteStrings.localized(L10n.shared.language) })
        // The session calls back on the main queue it was given.
        session.onChange = { [weak self] in MainActor.assumeIsolated { self?.publish() } }
        session.onSuccess = { [weak self] id in MainActor.assumeIsolated { self?.reveal(id) } }
    }

    /// `modeID` nil rewrites with the default mode from Clipboard settings.
    func start(entry: ClipboardHistoryEntry, modeID: String?) {
        modePickerEntryID = nil
        guard QuillRewriteSupport.offersRewrite(kind: entry.kind,
                                                rewriteAvailable: AppFeature.quillRewrite.isAvailable,
                                                historyAvailable: AppFeature.clipboardHistory.isAvailable)
        else { return }
        let stored = UserDefaults.standard.string(forKey: DefaultsKey.quillRewriteDefaultMode) ?? ""
        session.start(entryID: entry.id, text: entry.text, modeID: modeID, storedMode: stored)
    }

    /// Option+Return: the selected row opens its list of modes.
    func showModePicker(for entry: ClipboardHistoryEntry) {
        guard QuillRewriteSupport.offersRewrite(kind: entry.kind,
                                                rewriteAvailable: AppFeature.quillRewrite.isAvailable,
                                                historyAvailable: AppFeature.clipboardHistory.isAvailable)
        else { return }
        if modes == nil { loadModes() }
        modePickerEntryID = entry.id
    }

    func loadModes() {
        guard AppFeature.quillRewrite.isAvailable else { return }
        session.loadModes()
    }

    func discard(entryID: UUID) {
        session.discard(entryID: entryID)
    }

    private func publish() {
        let current = session.states
        if states != current { states = current }
        let catalog = session.catalog
        if modes != catalog { modes = catalog }
        let running = session.isRunning
        if isRunning != running { isRunning = running }
        if !AppFeature.quillRewrite.isAvailable { modePickerEntryID = nil }
    }

    /// The finished entry is selected and the preview opens on its before
    /// and after text, even if the panel was closed meanwhile.
    private func reveal(_ id: UUID) {
        guard AppFeature.quillRewrite.isAvailable else { return }
        let history = ClipboardHistoryService.shared
        history.selectRewrittenEntry(id)
        history.setQuickPreviewPresented(true)
    }
}
