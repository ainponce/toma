// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import QuartzCore

/// The timeline's ruler (design §5.5): the output's time, the take's markers (⚑, its `marker` events) and the in and out
/// marks. A label every step that leaves 80 pt between them, from a tenth of a second to two hours, and a tick between
/// labels where they are 6 pt apart or more; one layer for the ticks, and one per label, marker and mark in sight.
@MainActor
final class TimelineRuler {
    /// The ruler, as wide as the tracks' area.
    let layer = CALayer()
    private let ticks = CAShapeLayer()
    private let labels: LayerPool<CATextLayer>
    private let markers: LayerPool<CAShapeLayer>
    private let band = CALayer()
    private let inMark = CAShapeLayer()
    private let outMark = CAShapeLayer()
    private let separator = CALayer()

    /// The steps between labels, in milliseconds, and how many ticks each can be divided into, in order of preference.
    private static let steps: [(milliseconds: Int64, divisions: [Int64])] = [
        (100, [10, 5, 2]), (200, [4, 2]), (500, [5]), (1_000, [10, 4, 2]), (2_000, [4, 2]), (5_000, [5]), (10_000, [10, 2]),
        (15_000, [3]), (30_000, [6, 3]), (60_000, [6, 4, 2]), (120_000, [4, 2]), (300_000, [5]), (600_000, [10, 2]),
        (900_000, [3]), (1_800_000, [6, 3]), (3_600_000, [6, 4, 2]), (7_200_000, [4, 2]),
    ]
    /// The least space between two labels, and between two ticks.
    private static let labelSpacing = 80.0
    private static let tickSpacing = 6.0

    init() {
        labels = LayerPool(parent: layer) {
            let label = CATextLayer()
            TimelineText.setUp(label, size: 10, weight: .regular, monospacedDigits: true)
            return label
        }
        markers = LayerPool(parent: layer) { CAShapeLayer() }
        for part in [band, ticks, inMark, outMark, separator] { layer.addSublayer(part) }
        ticks.lineWidth = 1
        ticks.fillColor = nil
        for mark in [inMark, outMark] {
            mark.lineWidth = 2
            mark.fillColor = nil
        }
    }

    /// Lays out the ruler of `content` at `geometry`, with the marks `marks` (either may be missing); inside a
    /// transaction without actions.
    func update(_ content: TimelineContent, _ geometry: TimelineGeometry, _ palette: TimelinePalette, marks: TimelineMarks) {
        let width = geometry.areaWidth, height = TimelineLayout.rulerHeight
        layer.backgroundColor = palette.rulerBackground
        separator.backgroundColor = palette.separator
        separator.frame = CGRect(x: 0, y: height - 1, width: width, height: 1)
        ticks.frame = layer.bounds
        ticks.strokeColor = palette.tick
        labels.begin()
        markers.begin()
        defer {
            labels.end()
            markers.end()
        }
        // The ticks and labels in sight, up to the end of the output.
        let step = Self.steps.first { Double($0.milliseconds) / 1000 * geometry.scale >= Self.labelSpacing } ?? Self.steps[Self.steps.count - 1]
        let division = step.divisions.first { Double(step.milliseconds / $0) / 1000 * geometry.scale >= Self.tickSpacing } ?? 1
        let tick = step.milliseconds / division
        let (lower, upper) = geometry.visibleOutput
        let end = min(upper, content.map.duration)
        let path = CGMutablePath()
        var n = max(lower, 0) / 1_000_000 / tick
        while n * tick * 1_000_000 <= end {
            let milliseconds = n * tick
            let x = geometry.snapped(geometry.x(milliseconds * 1_000_000)) + 0.5
            let major = milliseconds % step.milliseconds == 0
            path.move(to: CGPoint(x: x, y: major ? height - 10 : height - 5))
            path.addLine(to: CGPoint(x: x, y: height - 1))
            if major {
                // By its step too: the same instant reads `0:12` or `0:12,0` depending on it.
                let (label, isNew) = labels.layer("\(step.milliseconds) \(milliseconds)")
                if isNew {
                    label.foregroundColor = palette.label
                    label.contentsScale = geometry.backingScale
                    label.string = Self.text(milliseconds: milliseconds, step: step.milliseconds)
                }
                label.frame = CGRect(x: x + 3, y: 2, width: Self.labelSpacing - 6, height: 13)
            }
            n += 1
        }
        ticks.path = path

        // Markers: a flag in the bottom half of the ruler, under the labels.
        let flag = 8.0
        for (i, marker) in content.markers.enumerated() {
            let x = geometry.snapped(geometry.x(marker))
            guard x > -flag, x < width + flag else { continue }
            let (shape, isNew) = markers.layer(String(i))
            if isNew {
                shape.fillColor = palette.marker
                let flagPath = CGMutablePath()
                flagPath.addRect(CGRect(x: 0, y: 12, width: 1.5, height: height - 13))
                flagPath.move(to: CGPoint(x: 1.5, y: 12))
                flagPath.addLine(to: CGPoint(x: flag, y: 15))
                flagPath.addLine(to: CGPoint(x: 1.5, y: 18))
                flagPath.closeSubpath()
                shape.path = flagPath
            }
            shape.frame = CGRect(x: x, y: 0, width: flag, height: height)
        }

        // The marks: a band between them and a bracket at each.
        let xIn = marks.in.map { geometry.snapped(geometry.x($0)) }, xOut = marks.out.map { geometry.snapped(geometry.x($0)) }
        band.backgroundColor = palette.marksFill
        if let xIn, let xOut, xOut > xIn {
            band.isHidden = false
            band.frame = CGRect(x: xIn, y: 0, width: xOut - xIn, height: height - 1)
        } else {
            band.isHidden = true
        }
        for (mark, x, opening) in [(inMark, xIn, true), (outMark, xOut, false)] {
            guard let x else {
                mark.isHidden = true
                continue
            }
            mark.isHidden = false
            mark.strokeColor = palette.marksEdge
            let arm = opening ? 4.0 : -4.0
            let bracket = CGMutablePath()
            bracket.move(to: CGPoint(x: x + arm, y: 2))
            bracket.addLine(to: CGPoint(x: x, y: 2))
            bracket.addLine(to: CGPoint(x: x, y: height - 2))
            bracket.addLine(to: CGPoint(x: x + arm, y: height - 2))
            mark.frame = layer.bounds
            mark.path = bracket
        }
    }

    /// Nothing to show (the project is opening, or cannot be shown): the ruler's background alone.
    func clear(_ palette: TimelinePalette) {
        layer.backgroundColor = palette.rulerBackground
        separator.backgroundColor = palette.separator
        separator.frame = CGRect(x: 0, y: TimelineLayout.rulerHeight - 1, width: layer.bounds.width, height: 1)
        ticks.path = nil
        for part in [band, inMark, outMark] { part.isHidden = true }
        labels.begin()
        labels.end()
        markers.begin()
        markers.end()
    }

    /// Forgets the labels and markers, so the next update makes them again with new colors.
    func reset() {
        labels.removeAll()
        markers.removeAll()
    }

    /// A label: `0:10`, `1:02:00` from an hour on, and with tenths when labels are less than a second apart (`0:12,5`,
    /// with the user's decimal separator).
    static func text(milliseconds: Int64, step: Int64) -> String {
        let whole = Timecode.duration(Double(milliseconds / 1000))
        guard step < 1_000 else { return whole }
        return whole + (Locale.current.decimalSeparator ?? ".") + String(milliseconds % 1000 / 100)
    }
}
