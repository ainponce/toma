// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// Several input recorders as one: each call goes to every recorder, in the order given, one after the other.
public final class CompositeInputRecorder: InputRecorder {
    /// In the order they are called.
    public let recorders: [any InputRecorder]

    public init(_ recorders: [any InputRecorder]) {
        self.recorders = recorders
    }

    public func start(log: EventLogWriter) async {
        for recorder in recorders { await recorder.start(log: log) }
    }

    public func pause() async {
        for recorder in recorders { await recorder.pause() }
    }

    public func resume() async {
        for recorder in recorders { await recorder.resume() }
    }

    public func stop() async {
        for recorder in recorders { await recorder.stop() }
    }
}

/// Hands the raise on to each of its recorders that needs it (`KeyPressRecorder`).
extension CompositeInputRecorder: FormatRaising {
    public func setFormatRaiser(_ raise: @escaping @Sendable () throws -> Void) {
        for case let recorder as any FormatRaising in recorders { recorder.setFormatRaiser(raise) }
    }
}
