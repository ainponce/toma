// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Testing
@testable import Analysis

// Follow the Cursor, `reframe-1` (phase 2 design §6.5, plan 2b decision 9), over the take of `ZoomFixtures`: the display
// is 1440×900 pt (1.6 wide), so in 9:16 without padding the room is 0.5625 × 1 and the window `window` of its width.

/// The window's width in 9:16 without padding, as a fraction of the display's.
private let window = 0.5625 / 1.6

/// The global point at fractions (`x`, `y`) of the display.
private func across(_ x: Double, _ y: Double = 0.5) -> SIMD2<Double> {
    SIMD2(1440 * x, 900 * y)
}

extension ZoomFixtures {
    /// `zoomDocument` in 9:16 unless said otherwise, the screen following the cursor.
    static func reframeDocument(
        aspect: Aspect = .portrait, padding: Double = 0, frame: WindowFrame = .none,
        sequence: [Clip] = [zoomClip(1, from: 0, to: 20)], regions: [ZoomRegion] = [], smoothing: CursorSmoothing = .off,
        layout: CameraLayout = .bubble
    ) -> EditDocument {
        var document = zoomDocument(
            aspect: aspect, padding: padding, frame: frame, sequence: sequence, regions: regions, smoothing: smoothing,
            layout: layout)
        document.style.reframe = .followCursor
        return document
    }

    /// The window of `document`'s paths.
    fileprivate static func reframePath(
        _ document: EditDocument, events: [InputEvent], take: TakeRecord = zoomTake(),
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> ReframePath {
        try #require(paths(document, events: events, take: take).reframe, sourceLocation: sourceLocation)
    }

    /// Every bit of the window's state on a step.
    static func bits(_ state: ReframePath.State) -> [UInt64] {
        [state.center, state.velocity, state.target].map(\.bitPattern) + [state.started ? 1 : 0]
    }

    /// The documents whose zoom cameras `fitPathsAreTheOnesOfBefore` pins: every kind of block, a window frame, a device
    /// frame, cuts and speeds, a split and camera layouts, over a 16:10 display or a 16:9 one, with a cursor that sweeps
    /// the screen and clicks.
    fileprivate static func fitCases() -> [(name: String, document: EditDocument, take: TakeRecord, events: [InputEvent])] {
        let display = Rect(x: 0, y: 0, width: 1440, height: 900), wide = Rect(x: 0, y: 0, width: 1920, height: 1080)
        func sweep(_ frame: Rect) -> (Double) -> SIMD2<Double> {
            { t in SIMD2(frame.width * (0.5 + 0.52 * cos(1.3 * t)), frame.height * (0.5 + 0.52 * sin(2.1 * t))) }
        }
        func events(_ frame: Rect) -> [InputEvent] {
            let along = sweep(frame)
            var events = trail(from: 0, to: 15, along)
            for t in [0.9, 2.3, 4.1, 6.7] {
                let point = along(t)
                events.append(InputEvent(t: source(t), kind: .mouseDown(.left, x: point.x, y: point.y)))
                events.append(InputEvent(t: source(t + 0.08), kind: .mouseUp(.left, x: point.x, y: point.y)))
            }
            return events.sortedByTime()
        }
        let blocks = [
            block(1, from: 0.4, to: 2.6), block(2, from: 2.8, to: 3.6, depth: 3, focus: .fixed(x: 0.2, y: 0.8)),
            block(3, from: 3.8, to: 4.6, depth: 1.7, instant: true), block(4, from: 4.7, to: 9, depth: nil),
        ]
        func layout(_ number: Int, _ kind: LayoutKind, from: Double, to: Double) -> LayoutBlock {
            LayoutBlock(
                id: "l-0000000\(number)", take: zoomTakeID, start: source(from), end: source(to), kind: kind, instant: false,
                bubble: kind == .bubble ? BubbleLayout(style: .default) : nil, split: SplitLayout())
        }
        let framed = zoomDocument(
            padding: 0.08, frame: .macWindow(appearance: .dark, title: "Fit", buttons: true), regions: blocks,
            smoothing: smoothed, bubble: .default)
        let cuts = zoomDocument(
            aspect: .portrait,
            sequence: [zoomClip(1, from: 0, to: 2), zoomClip(2, from: 2.5, to: 5, speed: 2), zoomClip(3, from: 6, to: 12)],
            regions: blocks)
        let split = zoomDocument(padding: 0.05, regions: blocks, smoothing: smoothed, layout: CameraLayout(kind: .split))
        let device = zoomDocument(
            aspect: .portrait, padding: 0.04, frame: .device(DeviceFrame(model: .iPhone, finish: .dark)), regions: blocks,
            smoothing: smoothed)
        let layouts = zoomDocument(
            aspect: .square, padding: 0.03, regions: blocks, smoothing: smoothed, bubble: .default, layout: .bubble,
            layouts: [
                layout(1, .split, from: 1, to: 2.5), layout(2, .bubble, from: 3, to: 4), layout(3, .cameraOnly, from: 4.2, to: 5),
            ])
        return [
            ("framed", framed, zoomTake(frame: display, camera: true), events(display)),
            ("cuts", cuts, zoomTake(frame: wide), events(wide)),
            ("split", split, zoomTake(frame: display, camera: true), events(display)),
            ("device", device, zoomTake(frame: wide), events(wide)),
            ("layouts", layouts, zoomTake(frame: display, camera: true), events(display)),
        ]
    }

    /// FNV-1a over the bits of the stage's camera and the card's on steps 0 to 2 999.
    fileprivate static func fitHash(_ paths: MotionPaths) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func add(_ value: UInt64) {
            for byte in 0..<8 {
                hash ^= (value >> (8 * UInt64(byte))) & 0xff
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        let end = StepGrid.outputTime(ofStep: 2_999)
        let zoom = paths.zoom.span(from: 0, through: end), card = paths.cardZoom?.span(from: 0, through: end)
        for s in 0..<3_000 {
            let τ = StepGrid.outputTime(ofStep: s)
            bits(zoom.state(atOutput: τ)).forEach(add)
            card.map { bits($0.state(atOutput: τ)).forEach(add) }
        }
        return hash
    }
}

extension ZoomFixtures {
    @Suite struct ReframePathTests {
        @Test func offeredFromOnePointThreeTimesWider() {
            let wide = 16.0 / 9
            #expect(ReframePath.isOffered(contentRatio: wide, outputRatio: Aspect.portrait.ratio))
            #expect(ReframePath.isOffered(contentRatio: wide, outputRatio: Aspect.square.ratio))
            #expect(ReframePath.isOffered(contentRatio: wide, outputRatio: Aspect.fourByFive.ratio))
            #expect(ReframePath.isOffered(contentRatio: 4.0 / 3, outputRatio: Aspect.square.ratio))
            #expect(ReframePath.isOffered(contentRatio: 1.3, outputRatio: 1))
            #expect(!ReframePath.isOffered(contentRatio: 1.29, outputRatio: 1))
            #expect(!ReframePath.isOffered(contentRatio: 16.0 / 10, outputRatio: Aspect.fourByThree.ratio))
            #expect(!ReframePath.isOffered(contentRatio: wide, outputRatio: Aspect.landscape.ratio))
            #expect(!ReframePath.isOffered(contentRatio: nil, outputRatio: Aspect.portrait.ratio))
            #expect(!ReframePath.isOffered(contentRatio: .nan, outputRatio: 1))
            #expect(!ReframePath.isOffered(contentRatio: 0, outputRatio: 1))
            // `auto` takes the content's ratio (16:9 within 1 % of it): never.
            for ratio in [wide, 16.0 / 10, 21.0 / 9, 3.2, 4.0 / 3, 1, 9.0 / 16, 1.79] {
                let output = Aspect.auto.ratio(contentRatio: ratio)
                #expect(!ReframePath.isOffered(contentRatio: ratio, outputRatio: output), "\(ratio)")
            }
        }

        @Test func followsTheCursorPastTheDeadZone() throws {
            let events = [pointer(0, across(0.5)), pointer(2, across(0.55)), pointer(4, across(0.9)), pointer(8, across(0.1))]
            let path = try reframePath(reframeDocument(), events: events)
            let zone = ReframePath.deadZone * window
            // Within the zone (0.55 is 0.05 from the target, the zone 0.088): the target and the centre stay.
            #expect((0..<step(4)).allSatisfy { path.center(atStep: $0) == 0.5 && path.state(atStep: $0).target == 0.5 })
            // Out of it: the target leaves the cursor on the zone's edge, and stays while the cursor does.
            #expect(abs(path.state(atStep: step(4)).target - (0.9 - zone)) < 1e-12)
            #expect(stride(from: step(4), to: step(8), by: 17).allSatisfy {
                abs(path.state(atStep: $0).target - (0.9 - zone)) < 1e-12
            })
            #expect(abs(path.center(atStep: step(8) - 1) - (0.9 - zone)) < 1e-4)
            // The other way.
            #expect(abs(path.state(atStep: step(8)).target - (0.1 + zone)) < 1e-12)
        }

        @Test func springIsCriticallyDampedWithResponse0_9() throws {
            let path = try reframePath(reframeDocument(), events: [pointer(0, across(0.5)), pointer(4, across(0.9))])
            let target = 0.9 - ReframePath.deadZone * window, jump = step(4)
            let centers = path.centersSimulatedFromStart(through: jump + 1_800)
            // The target jumps on `jump`: the centre never passes it.
            #expect(centers[jump...].allSatisfy { $0 > 0.5 && $0 <= target })
            func covered(_ seconds: Double) -> Double { (centers[jump - 1 + Int(seconds * 600)] - 0.5) / (target - 0.5) }
            // Critically damped with a response of 0.9 s (ω = 2π / 0.9): (1 + ωt) e^(−ωt) left, 1.4 % at 0.9 s and
            // 17.9 % at 0.45 s.
            #expect(covered(0.9) >= 0.98 && covered(0.9) < 0.99, "\(covered(0.9))")
            #expect(abs(covered(0.45) - 0.821) < 0.01, "\(covered(0.45))")
        }

        @Test func startsOnTheFirstCursor() throws {
            // No cursor for 2 s, then one near the right edge: the centre is on it (held to the window's room) from
            // output 0, at rest.
            let late = try reframePath(reframeDocument(), events: [pointer(2, across(0.95)), pointer(5, across(0.95))])
            let held = 1 - window / 2
            #expect([0, step(1), step(2), step(4), step(10)].allSatisfy { late.center(atStep: $0) == held })
            #expect(late.state(atStep: step(2)).started && !late.state(atStep: step(2) - 1).started)
            // Off the display first (on another screen), then on it at 3 s: it starts there.
            let off = try reframePath(reframeDocument(), events: [pointer(1, SIMD2(-300, 450)), pointer(3, across(0.3))])
            #expect(off.center(atStep: 0) == 0.3 && off.center(atStep: step(6)) == 0.3)
            // Without a cursor, the middle.
            let none = try reframePath(reframeDocument(), events: [])
            #expect(none.center(atStep: 0) == 0.5 && none.center(atStep: step(10)) == 0.5 && none.startStep == nil)
            // Fitted whole: no path.
            #expect(paths(zoomDocument(aspect: .portrait), events: [pointer(0, across(0.3))]).reframe == nil)
        }

        @Test func neverLeavesTheContent() throws {
            // Toward the left edge and 3 s on it, across to the right edge and 3 s on it, then all over.
            func x(_ t: Double) -> Double {
                switch t {
                case ..<2: 0.5 - t / 4
                case ..<5: 0
                case ..<7: (t - 5) / 2
                case ..<10: 1
                default: 0.5 + 0.55 * cos(1.9 * t)
                }
            }
            let events = trail(from: 0, to: 16) { across(min(max(x($0), 0), 1439.9 / 1440), 0.5 + 0.4 * sin($0)) }
            let document = reframeDocument(padding: 0.03, smoothing: smoothed)
            let motion = paths(document, events: events)
            let path = try #require(motion.reframe)
            let view = try #require(motion.stage.shownScreen(at: source(1))?.view)
            let width = try #require(motion.stage.reframedWidth(of: view))
            let centers = path.centersSimulatedFromStart(through: path.lastStep)
            let parts = centers.map { ReframePath.part(center: $0, width: width) }
            #expect(parts.allSatisfy { $0.x >= 0 && $0.x + $0.width <= 1 + 1e-12 })
            #expect(parts.allSatisfy { $0.y == 0 && $0.height == 1 && $0.width == width })
            #expect(parts[step(4.9)].x < 1e-6 && parts[step(9.9)].x + width > 1 - 1e-6)
            // The one the render reads at each instant.
            for s in stride(from: 0, through: path.lastStep, by: 13) {
                #expect(path.part(of: view, atOutput: StepGrid.outputTime(ofStep: s), stage: motion.stage) == parts[s])
            }
        }

        @Test func narrowViewsAreNotReframed() throws {
            // A window of 1440×900 that turns into one of 400×900 at 3 s: in 9:16 with a padding of 0.04, the room is
            // 0.54 wide, the second window 0.44.
            let take = zoomTake(window: true)
            let narrow = Rect(x: 100, y: 0, width: 400, height: 900)
            let events = (trail(from: 0, to: 8) { across(0.2 + 0.02 * $0) }
                + [InputEvent(t: source(3), kind: .windowGeometry(track: displayID, frame: narrow, onScreen: true))]).sortedByTime()
            let frames: [WindowFrame] = [.none, .macWindow(appearance: .dark, title: "Window", buttons: true),
                .device(DeviceFrame(model: .iPhone, finish: .light))]
            for frame in frames {
                let document = reframeDocument(padding: 0.04, frame: frame)
                let motion = paths(document, events: events, take: take)
                let (stage, path) = (motion.stage, try #require(motion.reframe))
                let wide = try #require(stage.shownScreen(at: source(1))?.view)
                let tall = try #require(stage.shownScreen(at: source(4))?.view)
                let room = stage.room
                #expect(room == StageLayout.screenRect(contentAspect: nil, padding: 0.04, outputSize: stage.stageSize))
                #expect(stage.isReframed(wide) && !stage.isReframed(tall), "\(frame)")
                // The wide one fills the room; the tall one is placed whole, without a frame either.
                #expect(stage.rects(of: wide).window == room && stage.rects(of: wide).screen == room, "\(frame)")
                let whole = StageLayout.screenRect(contentAspect: 400.0 / 900, padding: 0.04, outputSize: stage.stageSize)
                #expect(stage.rects(of: tall).window == whole && stage.rects(of: tall).screen == whole, "\(frame)")
                #expect(stage.screenRect(at: source(4)) == whole)
                #expect(path.part(of: wide, atOutput: output(1), stage: stage) != nil)
                #expect(path.part(of: tall, atOutput: output(4), stage: stage) == nil)
                // On the tall one the cursor is where it is fitted, whatever part is given.
                let point = SIMD2(300.0, 450.0)
                #expect(stage.stagePoint(global: point, at: source(4), part: Rect(x: 0.6, y: 0, width: 0.2, height: 1))
                    == stage.stagePoint(global: point, at: source(4)))
                #expect(stage.stagePoint(global: point, at: source(4)) != nil)
            }
            // Fitted whole, the same document draws its frame around the tall one.
            var fitted = reframeDocument(padding: 0.04, frame: frames[1])
            fitted.style.reframe = .fit
            let stage = StagePoints(take: take, events: events, document: fitted)
            let tall = try #require(stage.shownScreen(at: source(4))?.view)
            #expect(!stage.isReframed(tall) && stage.rects(of: tall).window != stage.rects(of: tall).screen)
        }

        @Test(arguments: [1, 1.5, 0.5, 3, 0.25, 16] as [Double])
        func readsTheViewOnTheStepItChanges(speed: Double) throws {
            // A window of 1440×900 with the cursor still at x = 1000 pt (0.69 of it); at 3.0003 s of source the window
            // moves 400 pt to the left, so the cursor is at 0.97 of it, past the dead zone; it moves back exactly at the
            // source instant a step of the output shows, 70 % of the way through it. The clip starts at 0.5 s.
            let take = zoomTake(window: true)
            let sequence = [zoomClip(1, from: 0.5, to: 10, speed: speed)]
            let timeMap = TimeMap(sequence: sequence)
            func host(_ s: Int) -> HostTime? { timeMap.source(atOutput: StepGrid.outputTime(ofStep: s))?.source }
            let back = StepGrid.firstStep(atOrAfter: timeMap.duration * 7 / 10)
            let away = source(3.000_3), home = try #require(host(back))
            func placed(at x: Double) -> InputEvent.Kind {
                .windowGeometry(track: displayID, frame: Rect(x: x, y: 0, width: 1440, height: 900), onScreen: true)
            }
            let events = [pointer(0, SIMD2(1000, 450)), InputEvent(t: away, kind: placed(at: -400)), InputEvent(t: home, kind: placed(at: 0))]
            let path = try reframePath(reframeDocument(sequence: sequence), events: events, take: take)
            // The first step whose source instant is the change's or later.
            let first = try #require((0...path.lastStep).first { s in host(s).map { $0 >= away } ?? false })
            let zone = ReframePath.deadZone * window
            #expect(path.state(atStep: first - 1).target == 1000.0 / 1440)
            #expect(path.state(atStep: first).target == 1 - window / 2)
            #expect(path.center(atStep: first - 1) == 1000.0 / 1440 && path.center(atStep: first) > 1000.0 / 1440)
            #expect(host(back - 1).map { $0 < home } == true)
            #expect(path.state(atStep: back - 1).target == 1 - window / 2)
            #expect(abs(path.state(atStep: back).target - (1000.0 / 1440 + zone)) < 1e-12)
        }

        @Test func stagePointIsInTheWindow() throws {
            let motion = paths(reframeDocument(padding: 0.05), events: [pointer(0, across(0.7))])
            let stage = motion.stage, path = try #require(motion.reframe)
            let view = try #require(stage.shownScreen(at: source(1))?.view)
            let room = stage.room
            let width = room.width / room.height / 1.6
            #expect(abs(try #require(stage.reframedWidth(of: view)) - width) < 1e-15)
            let part = Rect(x: 0.3, y: 0, width: width, height: 1)
            let inside = try #require(stage.stagePoint(global: across(0.3 + 0.25 * width, 0.4), at: source(1), part: part))
            #expect(near(inside, SIMD2(room.x + 0.25 * room.width, room.y + 0.4 * room.height), 1e-12))
            #expect(stage.stagePoint(global: across(0.29), at: source(1), part: part) == nil)
            #expect(stage.stagePoint(global: across(0.3 + width + 0.001), at: source(1), part: part) == nil)
            // Without a part, the whole region is squeezed into the room.
            let squeezed = try #require(stage.stagePoint(global: across(0.7, 0.4), at: source(1)))
            #expect(near(squeezed, SIMD2(room.x + 0.7 * room.width, room.y + 0.4 * room.height), 1e-12))
            // The path's part is the window about its centre.
            let center = path.center(atOutput: output(1))
            #expect(abs(center - 0.7) < 1e-12)
            #expect(path.part(of: view, atOutput: output(1), stage: stage) == ReframePath.part(center: center, width: width))
        }

        @Test func cutsKeepTheSpringGoing() throws {
            // Clips [0, 3) s and [6, 12) s at 2×: the cursor at 0.2 in the first, at 0.9 from the cut on (placed at the
            // second's start, so with `off` it jumps there), at 0.4 later.
            let events = [pointer(0, across(0.2)), pointer(4, across(0.9)), pointer(9, across(0.4))]
            let document = reframeDocument(sequence: [zoomClip(1, from: 0, to: 3), zoomClip(2, from: 6, to: 12, speed: 2)])
            let path = try reframePath(document, events: events)
            let centers = path.centersSimulatedFromStart(through: path.lastStep)
            // A critically damped spring moves at most ω/e of the way per second; with every target in [w/2, 1 − w/2],
            // never ω (1 − w) per second.
            let most = 2 * Double.pi / ReframePath.spring.response * (1 - window) / 600
            let moves = zip(centers, centers.dropFirst()).map { abs($1 - $0) }
            #expect(moves.max()! <= most, "\(moves.max()!) of \(most)")
            let border = step(3)
            #expect(centers[border - 1] == 0.2 && abs(centers[border] - 0.2) < 1e-3)
            #expect(centers[border + 600] > 0.6)
            // Through the border of the second clip's speed and the end it goes on as it went.
            #expect(path.center(atStep: path.lastStep + 600) == centers[path.lastStep])
        }

        @Test func checkpointsGiveTheSameBits() throws {
            var generator = ZoomRandom(seed: 0x7265_6672_616d)
            // A cursor that wanders over the whole display and off it, at 60 Hz for 20 s, smoothed, over two clips.
            var point = SIMD2(720.0, 450.0)
            let events = (0...1_200).map { i -> InputEvent in
                point += SIMD2(Double.random(in: -40...40, using: &generator), Double.random(in: -25...25, using: &generator))
                point = SIMD2(min(max(point.x, -100), 1_540), min(max(point.y, -50), 950))
                return pointer(Double(i) / 60, point)
            }
            let document = reframeDocument(
                sequence: [zoomClip(1, from: 0, to: 9), zoomClip(2, from: 10, to: 21, speed: 1.5)], smoothing: smoothed)
            let path = try reframePath(document, events: events, take: zoomTake(seconds: 30))
            let centers = path.centersSimulatedFromStart(through: path.lastStep)
            let probes = (0..<1_000).map { _ in Int.random(in: 0...path.lastStep, using: &generator) }
            #expect(probes.allSatisfy { path.center(atStep: $0).bitPattern == centers[$0].bitPattern })
            // Read step after step as the zoom cameras do, forward with jumps and now and then back.
            var reader = ReframePath.Reader(path)
            var walk = probes.prefix(300).sorted()
            walk.insert(contentsOf: [5, 4_000, 3], at: 150)
            #expect(walk.allSatisfy { reader.center(atStep: $0).bitPattern == centers[$0].bitPattern })
            // Off the grid, the two steps around mixed.
            for _ in 0..<200 {
                let τ = Int64.random(in: 0..<StepGrid.outputTime(ofStep: path.lastStep), using: &generator)
                let (s, fraction) = StepGrid.position(ofOutput: τ)
                let mixed = fraction > 0 ? centers[s] + (centers[s + 1] - centers[s]) * fraction : centers[s]
                #expect(path.center(atOutput: τ).bitPattern == mixed.bitPattern)
            }
        }

        @Test func theCursorItReadsIsTheSamples() {
            // `CursorPath.PositionReader`, what the window reads the cursor with, gives `sample(atStep:)`'s position bit for
            // bit, smoothed or not, with clicks and a press, forward step after step, with jumps, and back.
            var generator = ZoomRandom(seed: 0x706f_7369)
            var events = trail(from: 0.4, to: 9) { t in SIMD2(720 + 600 * cos(1.1 * t), 450 + 380 * sin(1.7 * t)) }
            for t in [1.2, 3.3, 6.0] {
                let point = SIMD2(720 + 600 * cos(1.1 * t), 450 + 380 * sin(1.7 * t))
                events.append(InputEvent(t: source(t), kind: .mouseDown(.left, x: point.x, y: point.y)))
                events.append(InputEvent(t: source(t + 0.4), kind: .mouseUp(.left, x: point.x, y: point.y)))
            }
            events = events.sortedByTime()
            let sequence = [zoomClip(1, from: 0, to: 5), zoomClip(2, from: 6, to: 10, speed: 1.5)]
            for smoothing in [smoothed, .off] {
                let document = zoomDocument(sequence: sequence, smoothing: smoothing)
                let cursor = paths(document, events: events).cursor
                var reader = CursorPath.PositionReader(cursor)
                var steps = Array(0...800) + (0..<400).map { _ in Int.random(in: -5...5_000, using: &generator) }.sorted()
                steps.insert(contentsOf: [3_100, 40, 2_000, 6_000], at: 1_000)
                let differ = steps.filter { s in
                    let position = reader.position(atStep: s)
                    let sample = cursor.sample(atStep: s)?.position
                    return position.map { [$0.x.bitPattern, $0.y.bitPattern] } != sample.map { [$0.x.bitPattern, $0.y.bitPattern] }
                }
                #expect(differ.isEmpty, "\(smoothing): \(differ.prefix(5))")
            }
        }

        /// Building the window of an hour (plan 2b, Task I4: ≤ 30 ms in release): a 16:9 display in 9:16, the pointer at
        /// 60 Hz that never stops, the smoothed cursor, 60 clips of 59.5 s. Run by an agent, with `TOMA_BENCH=1`, in
        /// release; the median of 5 after one to warm up, printed and recorded in docs/performance.md.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
        func reframeOfAnHourIsQuick() throws {
            let hour = 3_600.0
            let take = zoomTake(frame: Rect(x: 0, y: 0, width: 1920, height: 1080), seconds: hour + 1)
            let events = trail(from: 0, to: hour) { t in
                SIMD2(960 + 900 * cos(0.37 * t) * sin(0.11 * t), 540 + 500 * sin(0.53 * t))
            }
            let sequence = (0..<60).map { k in zoomClip(k + 1, from: 60 * Double(k), to: 60 * Double(k) + 59.5) }
            let document = reframeDocument(sequence: sequence, smoothing: smoothed)
            let timeMap = TimeMap(sequence: sequence)
            let stage = StagePoints(take: take, events: events, document: document)
            let cursor = CursorPath(take: take, events: events, style: document.cursor, timeMap: timeMap)
            let clock = ContinuousClock()
            func build() -> ReframePath? { ReframePath(document: document, timeMap: timeMap, stage: stage, cursor: cursor) }
            let path = try #require(build())
            let median = (0..<5).map { _ in clock.measure { _ = build() } }.sorted()[2]
            let ms = median / .milliseconds(1)
            // What of it is reading the cursor step after step (the floor): the same reads, alone.
            func readCursor() -> Double {
                var reader = CursorPath.PositionReader(cursor), sum = 0.0
                for s in 0...path.lastStep { sum += reader.position(atStep: s)?.x ?? 0 }
                return sum
            }
            _ = readCursor()
            let reading = (0..<5).map { _ in clock.measure { _ = readCursor() } }.sorted()[2] / .milliseconds(1)
            // And the cursor's own path, built once per revision as this one is: a measure of the Mac's load.
            let building = (0..<5).map { _ in
                clock.measure { _ = CursorPath(take: take, events: events, style: document.cursor, timeMap: timeMap) }
            }.sorted()[2] / .milliseconds(1)
            print(
                "reframeOfAnHourIsQuick: \(String(format: "%.1f", ms)) ms, \(path.simulatedSteps) steps; reading the cursor alone "
                    + String(format: "%.1f ms; building the cursor's path %.1f ms", reading, building))
            #expect(path.simulatedSteps == path.lastStep + 1)
            #expect(median <= .milliseconds(30), "\(ms) ms")
        }

        /// The zoom cameras of documents that fit the screen, recorded on `fase-2` at 052e48b, before `reframe-1`.
        @Test func fitPathsAreTheOnesOfBefore() {
            let recorded: [String: UInt64] = [
                "framed": 0x68b9_94cb_de3b_7307, "cuts": 0x5a87_2081_ae29_a3d4, "split": 0x5410_ccc9_52d3_5de1,
                "device": 0x875d_008f_6c20_a32e, "layouts": 0x5325_1530_180a_25da,
            ]
            for (name, document, take, events) in fitCases() {
                let hash = fitHash(MotionPaths(take: take, events: events, document: document))
                #expect(recorded[name] == hash, "\(name): 0x\(String(hash, radix: 16))")
            }
        }
    }
}
