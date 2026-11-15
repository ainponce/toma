// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Whether the app shows in the Dock and Cmd-Tab: only while one of its windows is open, it is not
/// recording and the island is not open or choosing what to record. At rest, choosing and while
/// recording it lives in the menu bar alone.
public enum ActivationPolicyDecision {
    public static func policy(openWindows: Int, isRecording: Bool, isSelecting: Bool) -> NSApplication.ActivationPolicy {
        openWindows > 0 && !isRecording && !isSelecting ? .regular : .accessory
    }
}
