// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import RecorderKitTestSupport
import Recording
import Testing

@Suite struct EncoderLoadTests {
    @Test func overloadSuggestsThirtyFPSForSecondaryDisplays() {
        let items = [VideoLoadItem(source: .display(1), width: 5120, height: 2880, framesPerSecond: 60),
                     VideoLoadItem(source: .display(2), width: 5120, height: 2880, framesPerSecond: 60),
                     VideoLoadItem(source: .camera, width: 3840, height: 2160, framesPerSecond: 30)]
        #expect(EncoderLoad.evaluate(items, mainDisplayID: 1) == .over(ratio: 2_018_304_000.0 / 800_000_000, suggestions: [.lowerDisplayRate(displayID: 2, to: 30), .lowerCameraPreset(to: .p1080)]))
    }

    @Test func typicalSetupIsNotOverloaded() {
        let items = [VideoLoadItem(source: .display(1), width: 3840, height: 2160, framesPerSecond: 60),
                     VideoLoadItem(source: .camera, width: 1920, height: 1080, framesPerSecond: 30)]
        #expect(EncoderLoad.evaluate(items, mainDisplayID: 1) == .ok(ratio: 559_872_000.0 / 800_000_000))
    }

    @Test func aLoadNearTheBudgetIsHighWithItsSuggestionsInOrder() {
        // The window, a display at 30 and the main display are never asked to go lower.
        let items = [VideoLoadItem(source: .window, width: 3000, height: 2000, framesPerSecond: 30),
                     VideoLoadItem(source: .display(1), width: 1920, height: 1080, framesPerSecond: 60),
                     VideoLoadItem(source: .display(3), width: 1920, height: 1080, framesPerSecond: 30),
                     VideoLoadItem(source: .display(2), width: 1920, height: 1080, framesPerSecond: 120),
                     VideoLoadItem(source: .camera, width: 1920, height: 1080, framesPerSecond: 60)]
        let pixels = 3000 * 2000 * 30 + 1920 * 1080 * (60 + 30 + 120 + 60)
        #expect(EncoderLoad.evaluate(items, mainDisplayID: 1) == .high(
            ratio: Double(pixels) / 800_000_000, suggestions: [.lowerDisplayRate(displayID: 2, to: 30), .lowerCameraRate(to: 30)]))

        // At the warning ratio it is high; past the budget, over; below the warning, ok.
        let camera = [VideoLoadItem(source: .camera, width: 1000, height: 1000, framesPerSecond: 60)]
        #expect(EncoderLoad.evaluate(camera, mainDisplayID: nil, budget: 75_000_000) == .high(ratio: 0.8, suggestions: [.lowerCameraRate(to: 30)]))
        #expect(EncoderLoad.evaluate(camera, mainDisplayID: nil, budget: 60_000_000) == .high(ratio: 1, suggestions: [.lowerCameraRate(to: 30)]))
        #expect(EncoderLoad.evaluate(camera, mainDisplayID: nil, budget: 50_000_000) == .over(ratio: 1.2, suggestions: [.lowerCameraRate(to: 30)]))
        #expect(EncoderLoad.evaluate(camera, mainDisplayID: nil, budget: 100_000_000) == .ok(ratio: 0.6))
        #expect(EncoderLoad.evaluate([], mainDisplayID: 1) == .ok(ratio: 0))
    }

    @Test func theBudgetCanBeChangedInTheDefaults() throws {
        let suite = "EncoderLoadTests-\(UUID().uuidString)"
        let defaults = try unwrap(UserDefaults(suiteName: suite), "a defaults suite")
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(EncoderLoad.budget(defaults: defaults) == 800_000_000)
        #expect(EncoderLoad.defaultBudgetPixelsPerSecond == 800_000_000 && EncoderLoad.warnRatio == 0.8)
        defaults.set(600_000_000, forKey: "encoderBudgetPixelsPerSecond")
        #expect(EncoderLoad.budget(defaults: defaults) == 600_000_000)
        // A budget that is not positive is not a budget.
        defaults.set(0, forKey: "encoderBudgetPixelsPerSecond")
        #expect(EncoderLoad.budget(defaults: defaults) == 800_000_000)
        defaults.set(-5, forKey: "encoderBudgetPixelsPerSecond")
        #expect(EncoderLoad.budget(defaults: defaults) == 800_000_000)
    }
}
