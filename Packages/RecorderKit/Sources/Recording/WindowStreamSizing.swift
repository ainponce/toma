// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreMedia
import Foundation
import ProjectFormat
import ScreenCaptureKit

/// The pixel size a window's (or a display's) stream should have for what its frames show.
///
/// ScreenCaptureKit never makes a frame larger than the configured size: when the content grows past it, the content
/// arrives shrunk (`contentScale` below 1) and `contentRect` with it, so the content's own size is
/// `contentRect.size / contentScale`, and `× scaleFactor` its pixels. Without `contentScale` a larger size would never
/// be asked for.
public enum WindowStreamSizing {
    /// `contentRect.size / contentScale × scaleFactor`, in whole even pixels (`(v / 2).rounded() * 2`); zero when
    /// `contentScale` is not positive.
    public static func pixelSize(contentRect: CGRect, contentScale: Double, scaleFactor: Double) -> CGSize {
        guard contentScale > 0, contentScale.isFinite, scaleFactor.isFinite else { return .zero }
        func even(_ points: CGFloat) -> CGFloat {
            CGFloat((Double(points) / contentScale * scaleFactor / 2).rounded() * 2)
        }
        return CGSize(width: even(contentRect.width), height: even(contentRect.height))
    }

    /// The size to configure the stream with when it differs from `configured` by 2 pixels or more in either
    /// dimension; `nil` otherwise, or when there is no content to size.
    public static func resize(configured: CGSize, contentRect: CGRect, contentScale: Double, scaleFactor: Double) -> CGSize? {
        let size = pixelSize(contentRect: contentRect, contentScale: contentScale, scaleFactor: scaleFactor)
        guard size.width >= 2, size.height >= 2 else { return nil }
        guard abs(size.width - configured.width) >= 2 || abs(size.height - configured.height) >= 2 else { return nil }
        return size
    }
}

/// What a frame's `SCStreamFrameInfo` says about the content it holds.
struct StreamFrameGeometry: Equatable, Sendable {
    /// Where the content is in the frame, in points (`.contentRect`).
    var contentRect: CGRect
    /// How much the content was shrunk to fit the frame (`.contentScale`; 1 when it was not).
    var contentScale: Double
    /// Pixels per point of the display the content is on (`.scaleFactor`).
    var scaleFactor: Double

    /// The content's own size in points, before it was shrunk.
    var contentPoints: CGSize {
        CGSize(width: contentRect.width / contentScale, height: contentRect.height / contentScale)
    }

    init(contentRect: CGRect, contentScale: Double, scaleFactor: Double) {
        self.contentRect = contentRect
        self.contentScale = contentScale
        self.scaleFactor = scaleFactor
    }

    /// `nil` when the sample carries no content rect, content scale or scale factor.
    init?(_ sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let info = attachments.first,
            let rectDictionary = info[.contentRect] as? NSDictionary,
            let contentRect = CGRect(dictionaryRepresentation: rectDictionary as CFDictionary),
            let contentScale = (info[.contentScale] as? NSNumber)?.doubleValue,
            let scaleFactor = (info[.scaleFactor] as? NSNumber)?.doubleValue
        else { return nil }
        self.init(contentRect: contentRect, contentScale: contentScale, scaleFactor: scaleFactor)
    }
}

/// A new size for a stream, and the frame that asked for it.
struct StreamResize: Equatable, Sendable {
    var size: CGSize
    var geometry: StreamFrameGeometry
}

/// Lets a stream be reconfigured at most every `minimumInterval`. A size asked for sooner waits, and a newer one
/// replaces it; one retry is scheduled for the end of the interval, so the last size of a resize gets configured even
/// if no later frame arrives (a still window sends none).
struct StreamResizeThrottle: Sendable {
    static let minimumInterval: Duration = .milliseconds(250)

    enum Decision: Equatable, Sendable {
        case none
        /// Configure the stream with this now, then call `applied`.
        case apply(StreamResize)
        /// Call `retryFired` after this long.
        case retry(after: Duration)
    }

    /// The size the stream is configured with.
    private(set) var configured: CGSize
    private var lastApplied: HostTime?
    private var pending: StreamResize?
    private var retryScheduled = false

    init(configured: CGSize) {
        self.configured = configured
    }

    /// A complete frame arrived; `resize` is what `WindowStreamSizing.resize` asks for it (`nil`: the size is right,
    /// and nothing waits any more).
    mutating func request(_ resize: StreamResize?, now: HostTime) -> Decision {
        guard let resize else {
            pending = nil
            return .none
        }
        return decide(resize, now: now)
    }

    /// The retry `request` or `retryFired` scheduled is due.
    mutating func retryFired(now: HostTime) -> Decision {
        retryScheduled = false
        guard let pending else { return .none }
        return decide(pending, now: now)
    }

    /// The stream was asked for `size` at `time`.
    mutating func applied(_ size: CGSize, at time: HostTime) {
        configured = size
        lastApplied = time
    }

    /// The stream refused `size`: back to `previous`, unless another size was configured since.
    mutating func refused(_ size: CGSize, previous: CGSize) {
        if configured == size { configured = previous }
    }

    private mutating func decide(_ resize: StreamResize, now: HostTime) -> Decision {
        let (seconds, attoseconds) = Self.minimumInterval.components
        let interval = seconds * 1_000_000_000 + attoseconds / 1_000_000_000
        let elapsed = lastApplied.map { Int64(now.nanoseconds) - Int64($0.nanoseconds) } ?? interval
        guard elapsed < interval else {
            pending = nil
            return .apply(resize)
        }
        pending = resize
        guard !retryScheduled else { return .none }
        retryScheduled = true
        return .retry(after: .nanoseconds(interval - elapsed))
    }
}
