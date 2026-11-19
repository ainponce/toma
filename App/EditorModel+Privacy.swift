// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppSupport
import Editing
import ProjectFormat

/// What the editor does with the privacy blocks by hand (phase 2 design §7.1): "Add Blur" from the timeline's bar and Edit,
/// the Privacy track's menu, and the selection the preview's rect follows. Each is one step of `PrivacyCommands`.
extension EditorModel {
    /// "Add Blur": a block of 3 s from the playhead with a rect of 40 % × 20 % of the screen, centred, the one selected;
    /// the Privacy track shows with it. Nothing where less than 0.3 s of the take is left after the playhead.
    func addBlur() {
        guard canEdit, let document,
            let step = PrivacyCommands.add(document, atOutput: playheadNanoseconds, makeID: Self.newID),
            perform(step) != .refused
        else { return }
        selection = .privacyBlocks([step.target])
    }

    /// The effect of block `id` (the track's menu): blur, pixelate or a plain color.
    func setPrivacyEffect(_ effect: PrivacyEffect, id: String) {
        guard canEdit, let document, let step = PrivacyCommands.change(document, id: id, effect: effect) else { return }
        perform(step)
    }

    /// Block `id` is the one selected; with `showingIt`, the playhead goes to its first frame (a double click on the
    /// track), so the preview shows its rect.
    func selectPrivacyBlock(_ id: String, showingIt: Bool) {
        selection = .privacyBlocks([id])
        guard showingIt, let document, let block = document.privacy.blocks.first(where: { $0.id == id }),
            let output = PrivacyCommands.outputRange(of: block, in: document)
        else { return }
        // The first frame of the grid at or after its start, inside it.
        let rate = document.frameRate
        var frame = Int((Double(output.lowerBound) * Double(rate) / 1e9).rounded(.up))
        while Int64(TimeMap.frameTime(frame, frameRate: rate)) < output.lowerBound { frame += 1 }
        seek(frame: frame)
    }

    #if DEBUG
    /// `TOMA_SHOWCASE_SELECT=privacy`: a pixelated block at the top left from 0.5 s, and a blur from 2 s, overlapping it,
    /// selected with the playhead on it, so the track and the preview's rect can be looked at.
    /// With `fill`, the selected one is a black fill, which shows on any screen where the rect is drawn over it.
    func showcasePrivacy(fill: Bool = false) {
        guard let rate = document?.frameRate else { return }
        seek(frame: rate / 2)
        addBlur()
        if case let .privacyBlocks(ids)? = selection, let id = ids.first {
            setPrivacyEffect(.pixelate, id: id)
            if let document, let block = document.privacy.blocks.first(where: { $0.id == id }),
                let step = PrivacyCommands.setRect(
                    document, id: id, NormalizedRect(x: 0.04, y: 0.06, width: 0.3, height: 0.14), atSource: block.start)
            {
                perform(step)
            }
        }
        seek(frame: 2 * rate)
        addBlur()
        if fill, case let .privacyBlocks(ids)? = selection, let id = ids.first { setPrivacyEffect(.fill, id: id) }
    }
    #endif
}
