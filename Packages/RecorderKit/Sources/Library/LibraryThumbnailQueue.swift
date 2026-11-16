// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Where the thumbnail of a card comes from (design §6.5, §6.8).
public enum ThumbnailDecision: Equatable, Sendable {
    /// Drawn, or read from the cache if the project did not change, by the library itself (`LibraryThumbnails.render`).
    case draw(URL)
    /// Only from the cache, by this key (`LibraryThumbnails.cached(_:)`): a project the library does not look at by
    /// itself.
    case cached(String)
    /// The package being recorded: none until the take ends.
    case afterTheTake
    /// On the network or in a synced location: none, and the card says so ("Sin miniatura en esta ubicación").
    case notHere
    /// None: the project cannot be opened, or nothing of it is in the cache.
    case none
}

/// Which cards' thumbnails are looked for, and when (design §6.8): only the cards on the screen, in the order they
/// appeared, at most `concurrent` at a time — one cancelled still counts until it returns, since its draw may run on
/// until its next checkpoint —; a card that leaves the screen is cancelled; a card whose project changed is looked for
/// again (its old image shows meanwhile); what a take kept from being drawn, its own package included, is looked for
/// again once it ends; and at most `keptOffScreen` cards off the screen keep their image, the ones that left it longest
/// ago going first. Nothing is looked for before `ready()`.
///
/// A value the window's model feeds with what happens and whose `Action`s it carries out: it starts a look with
/// `decide(_:projectsVolume:recordingPath:)` and reports how it went with `returned(_:_:)`, also when it was cancelled.
public struct LibraryThumbnailQueue: Sendable {
    /// How many thumbnails are looked for at a time.
    public static let concurrent = 2
    /// How many cards off the screen keep their image (about 600 KB each).
    public static let keptOffScreen = 120

    /// What the model does.
    public enum Action: Equatable, Sendable {
        /// Look for the thumbnail of this card, as `decide` says, and say how it went with `returned`.
        case start(PackageIdentity)
        /// Stop looking for it: its card left the screen, or its project changed. It still reports with `returned`.
        case cancel(PackageIdentity)
        /// Put the image that came back on the card.
        case show(PackageIdentity)
        /// Let the image of this card, off the screen, go.
        case release(PackageIdentity)
    }

    /// How a look went.
    public enum Outcome: Equatable, Sendable {
        /// An image came back.
        case image
        /// None came back: it could not be drawn or read. While a take records, it is looked for again after it.
        case noImage
        /// `decide` said there is none (`.none` or `.notHere`): not looked for again until the project changes.
        case nothing
        /// `decide` said `.afterTheTake`.
        case afterTheTake
    }

    private var isReady = false
    private var isRecording = false
    /// How many views show each card now.
    private var onScreen: [PackageIdentity: Int] = [:]
    /// The cards to look for, in the order they appeared.
    private var wanted: [PackageIdentity] = []
    private var running: Set<PackageIdentity> = []
    /// Cancelled, and not returned yet: they still count against `concurrent`.
    private var cancelling: Set<PackageIdentity> = []
    /// Their thumbnail is as current as it can be.
    private var current: Set<PackageIdentity> = []
    /// Looked for again once the take ends.
    private var afterTheTake: Set<PackageIdentity> = []
    /// Their card has an image.
    private var withImage: Set<PackageIdentity> = []
    /// The cards off the screen with an image, the one that left it longest ago first.
    private var offScreen: [PackageIdentity] = []

    public init() {}

    /// Nothing is looked for or running: the cards on the screen have what they can have.
    public var isIdle: Bool { wanted.isEmpty && running.isEmpty && cancelling.isEmpty }
    /// How many cards are on the screen.
    public var cardsOnScreen: Int { onScreen.count }

    /// What is needed to decide is known (the context, the projects folder's volume): looks start.
    public mutating func ready() -> [Action] {
        isReady = true
        return pump()
    }

    /// A view of the card `id` came on the screen.
    public mutating func appeared(_ id: PackageIdentity) -> [Action] {
        onScreen[id, default: 0] += 1
        guard onScreen[id] == 1 else { return [] }
        offScreen.removeAll { $0 == id }
        if !current.contains(id), !afterTheTake.contains(id) || !isRecording { want(id) }
        return pump()
    }

    /// A view of the card `id` left the screen: once none is left, it is no longer looked for, and its image may go.
    public mutating func disappeared(_ id: PackageIdentity) -> [Action] {
        guard let count = onScreen[id] else { return [] }
        guard count <= 1 else {
            onScreen[id] = count - 1
            return []
        }
        onScreen[id] = nil
        wanted.removeAll { $0 == id }
        var actions: [Action] = []
        if running.remove(id) != nil {
            cancelling.insert(id)
            actions.append(.cancel(id))
        }
        if withImage.contains(id) { offScreen.append(id) }
        return actions + evict() + pump()
    }

    /// The project of `id` changed (its files, state, place or key): it is looked for again if its card is on the
    /// screen, a look under way being cancelled; its image shows until the new one comes.
    public mutating func changed(_ id: PackageIdentity) -> [Action] {
        current.remove(id)
        var actions: [Action] = []
        if running.remove(id) != nil {
            cancelling.insert(id)
            actions.append(.cancel(id))
        }
        if onScreen[id, default: 0] > 0 { want(id) }
        return actions + pump()
    }

    /// The look `start` asked for ended with `outcome`, or was cancelled (whatever it says then is dropped).
    public mutating func returned(_ id: PackageIdentity, _ outcome: Outcome) -> [Action] {
        if cancelling.remove(id) != nil { return pump() }
        guard running.remove(id) != nil else { return pump() }
        return settle(id, outcome) + pump()
    }

    /// A thumbnail looked for on an action of the user (a project opened from the library that the library does not look
    /// at by itself), outside the queue's limit: kept as `returned` would keep it.
    public mutating func lookedForByTheUser(_ id: PackageIdentity, _ outcome: Outcome) -> [Action] {
        guard !running.contains(id), !cancelling.contains(id) else { return [] }
        wanted.removeAll { $0 == id }
        return settle(id, outcome) + pump()
    }

    /// A take started (`true`) or ended: once it ends, what it kept from being drawn is looked for again, its own
    /// package's card included, whatever came first, its last look or its end.
    public mutating func takeChanged(isRecording: Bool) -> [Action] {
        guard isRecording != self.isRecording else { return [] }
        self.isRecording = isRecording
        guard !isRecording else { return [] }
        for id in afterTheTake {
            current.remove(id)
            if onScreen[id, default: 0] > 0 { want(id) }
        }
        afterTheTake = []
        return pump()
    }

    /// Every card on the screen without an image is looked for again (where its thumbnail may come from changed: the
    /// projects folder appeared).
    public mutating func lookAgainWithoutImage() -> [Action] {
        for id in onScreen.keys.sorted(by: { $0.string < $1.string }) where !withImage.contains(id) {
            current.remove(id)
            want(id)
        }
        return pump()
    }

    // MARK: - Deciding

    /// Where the thumbnail of `summary` comes from (design §6.5, §6.8): none for the package being recorded until the
    /// take ends (`recordingPath`), nor for a project that cannot be opened; none, and said, in a synced location (by its
    /// path: nothing is asked of the disk) or for the projects folder on the network or synced; drawn by the library
    /// for a project of the projects folder or its trash on a local disk inside the Mac (`LibraryThumbnails.mayDraw`);
    /// otherwise (Other places, a removable disk, the volume not known yet) only from the cache, by the key its summary
    /// keeps.
    public static func decide(
        _ summary: ProjectSummary, projectsVolume: VolumeInfo?, recordingPath: String?,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> ThumbnailDecision {
        if summary.path == recordingPath { return .afterTheTake }
        switch summary.state {
        case .normal, .readOnlyVolume, .inTrash: break
        case .unfinished, .needsRepair, .newerVersion, .unavailable: return .none
        }
        let cached = summary.thumbnailKey.map(ThumbnailDecision.cached) ?? ThumbnailDecision.none
        if summary.place == .elsewhere { return isSynced(summary.path, home: home) ? .notHere : cached }
        guard let projectsVolume else { return cached }
        if projectsVolume.isNetwork || projectsVolume.isSynced { return .notHere }
        let url = URL(filePath: summary.path, directoryHint: .isDirectory)
        return LibraryThumbnails.mayDraw(place: summary.place, volume: projectsVolume) ? .draw(url) : cached
    }

    /// Whether `path` is in a location the system syncs, by its path alone: iCloud Drive (`~/Library/Mobile Documents`)
    /// or a file provider's folder (`~/Library/CloudStorage`).
    static func isSynced(_ path: String, home: String) -> Bool {
        let library = (home.hasSuffix("/") ? home : home + "/") + "Library/"
        return ["Mobile Documents/", "CloudStorage/"].contains { path.hasPrefix(library + $0) }
    }

    // MARK: -

    private mutating func want(_ id: PackageIdentity) {
        guard !wanted.contains(id), !running.contains(id) else { return }
        wanted.append(id)
    }

    /// Keeps what a look that was not cancelled found.
    private mutating func settle(_ id: PackageIdentity, _ outcome: Outcome) -> [Action] {
        switch outcome {
        case .image:
            current.insert(id)
            withImage.insert(id)
            guard onScreen[id] == nil else { return [.show(id)] }
            offScreen.removeAll { $0 == id }
            offScreen.append(id)
            return [.show(id)] + evict()
        case .noImage:
            if isRecording { afterTheTake.insert(id) } else { current.insert(id) }
        case .nothing:
            current.insert(id)
        case .afterTheTake:
            afterTheTake.insert(id)
        }
        return []
    }

    /// Starts what is wanted, while fewer than `concurrent` run or are being cancelled; a card still being cancelled
    /// waits for its look to return.
    private mutating func pump() -> [Action] {
        guard isReady else { return [] }
        var actions: [Action] = []
        var index = 0
        while running.count + cancelling.count < Self.concurrent, index < wanted.count {
            let id = wanted[index]
            if cancelling.contains(id) {
                index += 1
                continue
            }
            wanted.remove(at: index)
            running.insert(id)
            actions.append(.start(id))
        }
        return actions
    }

    /// Lets the images of the cards that left the screen longest ago go, past `keptOffScreen`.
    private mutating func evict() -> [Action] {
        var actions: [Action] = []
        while offScreen.count > Self.keptOffScreen {
            let id = offScreen.removeFirst()
            withImage.remove(id)
            current.remove(id)
            actions.append(.release(id))
        }
        return actions
    }
}
