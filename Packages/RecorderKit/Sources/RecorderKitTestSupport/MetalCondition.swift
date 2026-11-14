// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Metal

/// When the tests that draw with Metal run: `.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired)`.
/// They run on a machine with a Metal device, and always in CI, where a runner without one must fail them
/// loudly instead of skipping them and staying green.
public enum MetalCondition {
    /// This machine has a Metal device.
    public static var isAvailable: Bool { hasDevice }

    /// The tests that draw must run even without a device: CI sets `TOMA_CI=1`.
    public static var isRequired: Bool { ProcessInfo.processInfo.environment["TOMA_CI"] == "1" }

    private static let hasDevice = MTLCreateSystemDefaultDevice() != nil
}
