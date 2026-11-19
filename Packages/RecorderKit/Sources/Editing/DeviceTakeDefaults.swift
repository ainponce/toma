// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// How a take of an iPhone or iPad connected by cable (a `device` track, phase 2 design §7.6) starts in the editor (plan
/// 2c decision 19, set by `NewDocument.make`): with its device around the screen (design §6.7: an iPhone for content
/// upright with an aspect of 0.6 or less, an iPad for any other, dark) and without the cursor, which such a take never
/// records (the Cursor tab says so). The automatic zoom is left as it is: without clicks it plans nothing, and zooms added
/// by hand work as on any take.
public enum DeviceTakeDefaults {
    /// The widest content, width over height, that the iPhone's frame is for.
    public static let iPhoneMaximumAspect = 0.6

    /// The dark iPhone for content `contentAspect` (width over height) of `iPhoneMaximumAspect` or less, the dark iPad for
    /// any other.
    public static func frame(contentAspect: Double) -> DeviceFrame {
        DeviceFrame(model: contentAspect <= iPhoneMaximumAspect ? .iPhone : .iPad, finish: .dark)
    }

    /// The device `take` recorded, as its frame draws it: by the aspect of its first `device` track's `globalFrame` (the
    /// size of its first segment). `nil` for a take without a device, or of a device that never told its size.
    public static func model(of take: TakeRecord) -> DeviceModel? {
        guard let device = take.tracks.first(where: { $0.kind == .device }), let size = device.source.globalFrame,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0
        else { return nil }
        return frame(contentAspect: size.width / size.height).model
    }

    /// `document` as a take of a device starts: its device's frame (`frame(contentAspect:)`, `.dark`) and the cursor off.
    /// A device that never told its size keeps the style's frame. A take without a `device` track gets `document` as it is.
    public static func applied(to document: EditDocument, take: TakeRecord) -> EditDocument {
        guard take.tracks.contains(where: { $0.kind == .device }) else { return document }
        var document = document
        document.cursor.show = false
        if let model = model(of: take) { document.style.frame = .device(DeviceFrame(model: model, finish: .dark)) }
        return document
    }
}
