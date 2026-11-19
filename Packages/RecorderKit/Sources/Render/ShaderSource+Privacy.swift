// SPDX-License-Identifier: GPL-3.0-or-later

extension ShaderSource {
    /// The part of the library (`metal`) of the screen with its privacy regions (phase 2 design §7.1), blurred,
    /// pixelated or filled in its shader (§11, step 2). Milestone 2c writes it.
    /// Empty in the base of phase 2.
    static let privacyMetal = ""
}
