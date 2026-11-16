// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

@MainActor @Suite struct ExportPreferencesTests {
    @Test func defaultsAre1080pStandard() throws {
        #expect(ExportPreferences() == ExportPreferences(shortSide: 1080, highQuality: false))
        #expect(ExportPreferences.shortSides == [720, 1080, 1440, 2160])
        #expect(try JSONDecoder().decode(ExportPreferences.self, from: Data("{}".utf8)) == ExportPreferences())
        // A field missing takes its default; the other is kept.
        #expect(try JSONDecoder().decode(ExportPreferences.self, from: Data(#"{"shortSide":2160}"#.utf8))
            == ExportPreferences(shortSide: 2160, highQuality: false))
        #expect(try JSONDecoder().decode(ExportPreferences.self, from: Data(#"{"highQuality":true}"#.utf8))
            == ExportPreferences(shortSide: 1080, highQuality: true))
    }

    @Test func aValueTheSheetDoesNotOfferTakesItsDefault() throws {
        // Saved by hand, or by a version with other resolutions: the sheet would have nothing to show selected.
        for side in [0, -720, 480, 1081, 4320] {
            let json = #"{"shortSide":\#(side),"highQuality":true}"#
            #expect(try JSONDecoder().decode(ExportPreferences.self, from: Data(json.utf8))
                == ExportPreferences(shortSide: 1080, highQuality: true), "\(side)")
        }
        #expect(try JSONDecoder().decode(ExportPreferences.self, from: Data(#"{"shortSide":"4K","highQuality":"yes"}"#.utf8))
            == ExportPreferences())
    }

    @Test func preferencesRoundTripInSettings() throws {
        try withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            #expect(store.settings.export == ExportPreferences())

            var settings = store.settings
            settings.export = ExportPreferences(shortSide: 1440, highQuality: true)
            store.settings = settings
            #expect(SettingsStore(defaults: defaults).settings.export == ExportPreferences(shortSide: 1440, highQuality: true))
            #expect(SettingsStore(defaults: defaults).settings == settings)

            // Settings saved before the export sheet, without `export`: its defaults, and the rest kept.
            var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
            #expect(json.removeValue(forKey: "export") != nil)
            json["countdownSeconds"] = 10
            defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: SettingsStore.key)
            #expect(store.settings.export == ExportPreferences())
            #expect(store.settings.countdownSeconds == 10)
        }
    }

    @Test func theRecordedShortSideIsInPixels() {
        // A Retina display, recorded at 2 pixels per point: 1512 × 982 points.
        let display = Self.track(.display, frame: Rect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
        #expect(ExportPreferences.recordedShortSide(of: Self.take([display])) == 1964)
        // Recorded in points.
        let inPoints = Self.track(.display, frame: Rect(x: 0, y: 0, width: 1512, height: 982), scale: 1)
        #expect(ExportPreferences.recordedShortSide(of: Self.take([inPoints])) == 982)
        // In Area mode, only the area is shown.
        var area = display
        area.source.captureArea = Rect(x: 100, y: 100, width: 640, height: 360)
        #expect(ExportPreferences.recordedShortSide(of: Self.take([area])) == 720)
        // A window, portrait.
        let window = Self.track(.window, frame: Rect(x: 10, y: 10, width: 600, height: 900), scale: 2)
        #expect(ExportPreferences.recordedShortSide(of: Self.take([window])) == 1200)
    }

    @Test func theRecordedShortSideIsTheLargestScreens() {
        let small = Self.track(.display, id: "display-1", frame: Rect(x: 0, y: 0, width: 1920, height: 1080), scale: 1)
        let large = Self.track(.display, id: "display-2", frame: Rect(x: 1920, y: 0, width: 1512, height: 982), scale: 2)
        #expect(ExportPreferences.recordedShortSide(of: Self.take([small, large])) == 1964)
        // A screen without segments recorded nothing; without its scale or frame, its size is not known.
        var empty = large
        empty.segments = []
        #expect(ExportPreferences.recordedShortSide(of: Self.take([small, empty])) == 1080)
        var unknownScale = large
        unknownScale.source.pixelScale = nil
        #expect(ExportPreferences.recordedShortSide(of: Self.take([small, unknownScale])) == 1080)
        var unknownFrame = large
        unknownFrame.source.globalFrame = nil
        #expect(ExportPreferences.recordedShortSide(of: Self.take([small, unknownFrame])) == 1080)
        // Sizes that are not finite and positive are not sizes.
        var zero = large
        zero.source.globalFrame = Rect(x: 0, y: 0, width: 0, height: 982)
        #expect(ExportPreferences.recordedShortSide(of: Self.take([small, zero])) == 1080)
        var infinite = large
        infinite.source.pixelScale = .infinity
        #expect(ExportPreferences.recordedShortSide(of: Self.take([small, infinite])) == 1080)
    }

    @Test func aTakeWithoutAScreenHasNoRecordedShortSide() {
        let camera = Self.track(.camera, frame: Rect(x: 0, y: 0, width: 1920, height: 1080), scale: 1)
        let microphone = Self.track(.microphone, frame: nil, scale: nil)
        #expect(ExportPreferences.recordedShortSide(of: Self.take([camera, microphone])) == nil)
        #expect(ExportPreferences.recordedShortSide(of: Self.take([])) == nil)
    }

    // MARK: - Helpers

    private static func track(_ kind: TrackKind, id: String? = nil, frame: Rect?, scale: Double?) -> TrackRecord {
        let id = id ?? "\(kind.rawValue)-1"
        return TrackRecord(
            id: id, kind: kind, source: TrackSource(name: id, displayID: kind == .display ? 1 : nil, globalFrame: frame, pixelScale: scale),
            segments: [
                SegmentRecord(
                    index: 1, file: "takes/take-001/\(id)/seg-0001.mov", startHostTime: HostTime(nanoseconds: 1_000),
                    endHostTime: HostTime(nanoseconds: 2_000_000_000), endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
            ])
    }

    private static func take(_ tracks: [TrackRecord]) -> TakeRecord {
        TakeRecord(id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: tracks)
    }

    /// A defaults suite of its own, removed when `body` returns.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "ExportPreferencesTests-\(UUID().uuidString)"
        let defaults = try unwrap(UserDefaults(suiteName: suite), "a defaults suite")
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
