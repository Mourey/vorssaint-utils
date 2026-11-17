// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

/// Every visible string of Rewrite with quill. English ships for every app
/// language until translations land; the schema is checked in each one.
struct QuillRewriteStrings {
    let rewriteAction: String
    let rewriteWithAction: String
    let rewriting: String
    let before: String
    let after: String
    let use: String
    let copy: String
    let discard: String
    let notSaved: String
    let settingsLabel: String
    let quillDefault: String
    let hubName: String
    let hubCaption: String
    let messageNoKey: String
    let messageTimeout: String
    let messageUpstreamError: String
    let messageUnknownMode: String
    let messageBadRequest: String
    let messageInternalError: String
    let messageUsage: String
    let messageNotFound: String
    let messageDeadline: String
    let messageLaunchFailed: String
    let messageNoOutput: String
    let messageModesUnavailable: String
    let messageUnknown: String

    static let english = QuillRewriteStrings(
        rewriteAction: "Rewrite with quill",
        rewriteWithAction: "Rewrite with…",
        rewriting: "Rewriting…",
        before: "Before",
        after: "After",
        use: "Use",
        copy: "Copy",
        discard: "Discard",
        notSaved: "The rewrite wasn’t saved to the history: it is empty, too long or looks sensitive.",
        settingsLabel: "Default rewrite mode",
        quillDefault: "quill’s default",
        hubName: "Rewrite with quill",
        hubCaption: "Rewrites a text item from the clipboard panel with quill, then lets you use, copy or discard the result.",
        messageNoKey: "quill has no OpenRouter key. Add one to quill and try again.",
        messageTimeout: "The model took too long to answer. Try again.",
        messageUpstreamError: "The model service returned an error. Try again later.",
        messageUnknownMode: "quill doesn’t know this mode. Choose another one.",
        messageBadRequest: "quill couldn’t use this text. Try a shorter text.",
        messageInternalError: "quill ran into an internal error.",
        messageUsage: "This quill can’t rewrite clipboard text. Please update quill to a version with the clipboard surface.",
        messageNotFound: "quill wasn’t found in ~/.local/bin.",
        messageDeadline: "quill didn’t finish within 10 seconds and was stopped.",
        messageLaunchFailed: "quill couldn’t be started.",
        messageNoOutput: "quill returned no text.",
        messageModesUnavailable: "quill’s modes couldn’t be loaded, so no mode was chosen.",
        messageUnknown: "quill failed for a reason it didn’t name."
    )

    static func localized(_ language: AppLanguage) -> QuillRewriteStrings {
        switch language {
        case .enUS, .ptBR, .tr, .ru, .es, .sk, .de, .fr, .it, .ja, .ko, .uk, .zhHans, .zhTW, .zhHK:
            return english
        }
    }
}
