import SwiftUI

/// The silhouette of the island: it hangs from the top edge of the screen with
/// two small concave "ears" (like the real notch) and two rounded bottom
/// corners. Everything animates, so the shape morphs smoothly between states.
///
/// The ears are drawn inside the frame: the black body is `topRadius` narrower
/// than the frame on each side.
///
/// When `neckWidth` is narrower than the frame, the shape becomes a "T": a neck
/// of that width crosses the menu bar, hidden by the notch, and the full-width
/// body starts below `neckHeight`. That is how the open island leaves the menu
/// bar's menus and icons alone: macOS will not move them out of the way, so the
/// island goes behind the notch and opens underneath them.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// Width of the part that crosses the menu bar. Zero means the whole frame.
    var neckWidth: CGFloat = 0
    /// Height of the menu bar strip the neck crosses.
    var neckHeight: CGFloat = 0

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(topRadius, bottomRadius), neckWidth) }
        set {
            topRadius = newValue.first.first
            bottomRadius = newValue.first.second
            neckWidth = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }

        // Springs overshoot: keep every radius valid for whatever size we are given.
        let ear = max(0, min(topRadius, rect.height / 2, rect.width / 4))
        let neck = neckWidth > 0 ? min(neckWidth, rect.width) : rect.width
        let left = rect.midX - neck / 2 + ear
        let right = rect.midX + neck / 2 - ear
        let bodyHeight = rect.height - neckHeight
        // A "T" only once there is a real body below the neck and real
        // shoulders beside it; until then, the plain notch shape.
        let isT = neckHeight > 0 && bodyHeight > 2 && left - rect.minX > ear + 2

        path.move(to: CGPoint(x: left - ear, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: left, y: rect.minY),
                    tangent2End: CGPoint(x: left, y: rect.minY + ear),
                    radius: ear)

        if isT {
            let y = rect.minY + neckHeight
            let fillet = max(0, min(8, bodyHeight / 2, (left - rect.minX) / 2))
            let corner = max(0, min(16, bodyHeight / 2, left - rect.minX - fillet))
            let bottom = max(0, min(bottomRadius, bodyHeight - corner, rect.width / 2))

            path.addLine(to: CGPoint(x: left, y: y - fillet))
            path.addArc(tangent1End: CGPoint(x: left, y: y),
                        tangent2End: CGPoint(x: left - fillet, y: y), radius: fillet)
            path.addLine(to: CGPoint(x: rect.minX + corner, y: y))
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: y),
                        tangent2End: CGPoint(x: rect.minX, y: y + corner), radius: corner)
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottom))
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                        tangent2End: CGPoint(x: rect.minX + bottom, y: rect.maxY), radius: bottom)
            path.addLine(to: CGPoint(x: rect.maxX - bottom, y: rect.maxY))
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                        tangent2End: CGPoint(x: rect.maxX, y: rect.maxY - bottom), radius: bottom)
            path.addLine(to: CGPoint(x: rect.maxX, y: y + corner))
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: y),
                        tangent2End: CGPoint(x: rect.maxX - corner, y: y), radius: corner)
            path.addLine(to: CGPoint(x: right + fillet, y: y))
            path.addArc(tangent1End: CGPoint(x: right, y: y),
                        tangent2End: CGPoint(x: right, y: y - fillet), radius: fillet)
        } else {
            let bottom = max(0, min(bottomRadius, rect.height - ear, (right - left) / 2))
            path.addLine(to: CGPoint(x: left, y: rect.maxY - bottom))
            path.addArc(tangent1End: CGPoint(x: left, y: rect.maxY),
                        tangent2End: CGPoint(x: left + bottom, y: rect.maxY), radius: bottom)
            path.addLine(to: CGPoint(x: right - bottom, y: rect.maxY))
            path.addArc(tangent1End: CGPoint(x: right, y: rect.maxY),
                        tangent2End: CGPoint(x: right, y: rect.maxY - bottom), radius: bottom)
        }

        path.addLine(to: CGPoint(x: right, y: rect.minY + ear))
        path.addArc(tangent1End: CGPoint(x: right, y: rect.minY),
                    tangent2End: CGPoint(x: right + ear, y: rect.minY),
                    radius: ear)
        path.closeSubpath()
        return path
    }
}
