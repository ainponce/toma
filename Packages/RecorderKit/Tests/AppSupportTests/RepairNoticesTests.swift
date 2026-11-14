// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import Testing

private let newer = RepairNotice(path: "/m/A.toma", reason: "format version 2 is newer than 1")
private let unreadable = RepairNotice(path: "/m/B.toma", reason: "manifest.json cannot be read")

@Test func eachDamagedProjectIsMentionedOnce() async {
    await withDefaults { defaults in
        let notices = RepairNotices(defaults: defaults)
        #expect(notices.unseen([newer, unreadable]) == [newer, unreadable])
        notices.markShown([newer])
        #expect(notices.unseen([newer, unreadable]) == [unreadable])
        notices.markShown([unreadable])
        #expect(notices.unseen([newer, unreadable]).isEmpty)
        // Remembered in the defaults, not in the value.
        #expect(RepairNotices(defaults: defaults).unseen([newer, unreadable]).isEmpty)
    }
}

@Test func aNewReasonIsMentionedAgain() async {
    await withDefaults { defaults in
        let notices = RepairNotices(defaults: defaults)
        notices.markShown([newer])
        let changed = RepairNotice(path: newer.path, reason: "format version 3 is newer than 1")
        #expect(notices.unseen([changed]) == [changed])
    }
}

@Test func markingTwiceKeepsOneEntry() async {
    await withDefaults { defaults in
        let notices = RepairNotices(defaults: defaults)
        notices.markShown([newer])
        notices.markShown([newer, newer])
        #expect(defaults.stringArray(forKey: "shownRepairNotices")?.count == 1)
    }
}
