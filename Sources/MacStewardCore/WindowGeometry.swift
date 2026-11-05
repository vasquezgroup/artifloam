import Foundation
import CoreGraphics

public enum WindowGeometry {
    public static let preferredSize = CGSize(width: 1160, height: 678)
    /// One-time migration keeps the old centre, then fits the available display.
    public static func fitted(_ frame: CGRect, visible: CGRect, size: CGSize? = nil) -> CGRect {
        let requested = size ?? frame.size
        let width = min(requested.width, visible.width)
        let height = min(requested.height, visible.height)
        return CGRect(x: min(max(frame.midX - width / 2, visible.minX), visible.maxX - width),
                      y: min(max(frame.midY - height / 2, visible.minY), visible.maxY - height),
                      width: width, height: height)
    }
}
