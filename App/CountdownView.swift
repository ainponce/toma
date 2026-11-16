// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import SwiftUI

/// The countdown before a take (236 × 214, notch design §5.1 and §5.3): the seconds left, large, inside
/// a ring that empties linearly in each second, and "Esc to cancel". Each number appears from small and
/// blurred and leaves growing and blurring; with "Reduce motion" they fade and the ring stays still.
struct CountdownView: View {
    let remaining: Int
    /// Under the notch, the black band at the top.
    let topInset: Double

    private static let ringSize = 104.0
    private static let ringWidth = 4.0

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.14), lineWidth: Self.ringWidth)
                // A new ring for every second: full when it appears, empty when the second is over.
                EmptyingRing(lineWidth: Self.ringWidth).id(remaining)
                CountdownDigit(value: remaining)
            }
            .frame(width: Self.ringSize, height: Self.ringSize)
            .padding(.top, 14)
            Spacer(minLength: 0)
            Text("Esc to cancel")
                .font(.system(size: 11))
                .opacity(0.6)
                .padding(.bottom, 14)
        }
        .padding(.top, topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
    }
}

/// The ring of one second.
private struct EmptyingRing: View {
    let lineWidth: Double
    @State private var left = 1.0
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .trim(from: 0, to: left)
            .stroke(Color.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1)) { left = 0 }
            }
    }
}

/// The number: the one that leaves and the one that comes are drawn together while they cross.
private struct CountdownDigit: View {
    let value: Int
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Text(verbatim: value.formatted())
                .font(.system(size: 64, weight: .bold))
                .monospacedDigit()
                .tracking(-1.9)
                .id(value)
                .transition(reduceMotion ? .islandFade : .countdownDigit)
        }
        .animation(.island(Motion.islandExpand, reduceMotion: reduceMotion), value: value)
    }
}

extension AnyTransition {
    /// A number of the countdown: in from scale 0.45 and blur 12 with the opening spring, out growing to
    /// 1.35 and blurring in 280 ms (notch design §5.3, the prototype's timing).
    static var countdownDigit: AnyTransition {
        let enter = Motion.islandExpand
        return .asymmetric(
            insertion: .modifier(
                active: DigitLook(opacity: 0, blur: 12, scale: 0.45), identity: DigitLook(opacity: 1, blur: 0, scale: 1)
            )
            .animation(.spring(response: enter.response, dampingFraction: enter.damping)),
            removal: .modifier(
                active: DigitLook(opacity: 0, blur: 10, scale: 1.35), identity: DigitLook(opacity: 1, blur: 0, scale: 1)
            )
            .animation(.easeIn(duration: Motion.countdownDigitExit.timeInterval)))
    }
}

private struct DigitLook: ViewModifier {
    let opacity: Double
    let blur: Double
    let scale: Double

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .blur(radius: blur)
            .scaleEffect(scale)
    }
}
