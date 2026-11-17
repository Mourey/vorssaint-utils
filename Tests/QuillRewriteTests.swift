// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Rewrite with quill: the default-mode preference, the pure support and the
/// runner entry point the clipboard panel hands its text to.
enum QuillRewriteTests {
    static func run(_ suite: TestSuite) {
        preferenceChecks(suite)
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
}
