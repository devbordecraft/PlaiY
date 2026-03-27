#if os(tvOS)
import SwiftUI
import UIKit

/// Captures Siri Remote touch-surface gestures (pan/tap) and exposes them to SwiftUI.
/// SwiftUI's built-in gesture system does not receive indirect touch events from the
/// Siri Remote touch surface, so we drop to UIKit gesture recognizers.
struct TVRemoteGestureView: UIViewRepresentable {
    let onSwipeSeek: (Double) -> Void   // seconds to seek (negative = backward)
    let onTap: () -> Void               // click-center on touch surface

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = true

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        view.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        tap.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        view.addGestureRecognizer(tap)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onSwipeSeek = onSwipeSeek
        context.coordinator.onTap = onTap
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSwipeSeek: onSwipeSeek, onTap: onTap)
    }

    final class Coordinator: NSObject {
        var onSwipeSeek: (Double) -> Void
        var onTap: () -> Void

        /// Accumulated horizontal translation since gesture began.
        private var accumulatedSeek: Double = 0
        /// Threshold before the next seek fires (starts at 10s, ramps up).
        private let seekStepBase: Double = 10

        init(onSwipeSeek: @escaping (Double) -> Void, onTap: @escaping () -> Void) {
            self.onSwipeSeek = onSwipeSeek
            self.onTap = onTap
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began:
                accumulatedSeek = 0

            case .changed:
                let velocity = gesture.velocity(in: gesture.view).x
                // Map velocity to seek speed:
                //   gentle (< 200 pt/s) → 10s per trigger
                //   medium (200-800 pt/s) → 30s per trigger
                //   fast (> 800 pt/s) → proportional scrub
                let seekAmount: Double
                let absVelocity = abs(velocity)
                if absVelocity < 200 {
                    seekAmount = seekStepBase
                } else if absVelocity < 800 {
                    seekAmount = 30
                } else {
                    seekAmount = 60
                }

                let translation = gesture.translation(in: gesture.view).x
                // Fire a seek every 80 points of translation
                let threshold: CGFloat = 80
                if abs(translation) > threshold {
                    let direction = translation > 0 ? 1.0 : -1.0
                    onSwipeSeek(direction * seekAmount)
                    gesture.setTranslation(.zero, in: gesture.view)
                }

            case .ended, .cancelled:
                accumulatedSeek = 0

            default:
                break
            }
        }

        @objc func handleTap() {
            onTap()
        }
    }
}
#endif
