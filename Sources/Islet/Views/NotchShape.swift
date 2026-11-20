import SwiftUI

/// The silhouette of the island: it hangs from the top edge of the screen with
/// two small concave "ears" (like the real notch) and two rounded bottom
/// corners. Both radii animate, so the shape morphs smoothly between states.
///
/// The ears are drawn inside the frame: the black body is `topRadius` narrower
/// than the frame on each side.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }

        // Springs overshoot: keep the radii valid for whatever size we are given.
        let top = max(0, min(topRadius, rect.height / 2, rect.width / 4))
        let bottom = max(0, min(bottomRadius, rect.height - top, (rect.width - 2 * top) / 2))
        let left = rect.minX + top
        let right = rect.maxX - top

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: left, y: rect.minY),
                    tangent2End: CGPoint(x: left, y: rect.minY + top),
                    radius: top)
        path.addLine(to: CGPoint(x: left, y: rect.maxY - bottom))
        path.addArc(tangent1End: CGPoint(x: left, y: rect.maxY),
                    tangent2End: CGPoint(x: left + bottom, y: rect.maxY),
                    radius: bottom)
        path.addLine(to: CGPoint(x: right - bottom, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: right, y: rect.maxY),
                    tangent2End: CGPoint(x: right, y: rect.maxY - bottom),
                    radius: bottom)
        path.addLine(to: CGPoint(x: right, y: rect.minY + top))
        path.addArc(tangent1End: CGPoint(x: right, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.minY),
                    radius: top)
        path.closeSubpath()
        return path
    }
}
