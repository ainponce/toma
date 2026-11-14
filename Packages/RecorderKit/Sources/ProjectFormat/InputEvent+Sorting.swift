// SPDX-License-Identifier: GPL-3.0-or-later

extension Array where Element == InputEvent {
    /// The events in `t` order, those with the same `t` in the order they have here.
    ///
    /// `events.jsonl` is in append order, not always the order of `t`, so every reader that needs time
    /// order sorts with this. Filtering keeps the order of what it keeps, so `filter(_:).sortedByTime()`
    /// orders those events as sorting them all would.
    public func sortedByTime() -> [InputEvent] {
        enumerated()
            .sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }
            .map(\.element)
    }
}
