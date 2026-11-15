import CoreGraphics
import Foundation

public enum CaptureDimensionCalculator {
    /// Maximum pixel width accepted reliably by older Intel QuickSync hardware encoders.
    public static let maxIntelQuickSyncWidth: Int = 4096

    /// Rounds a floating-point dimension down to the nearest positive even integer (>= 2).
    public static func roundDownEven(_ value: CGFloat) -> Int {
        guard value.isFinite, value >= 2.0 else { return 2 }
        return max(2, (Int(floor(value)) / 2) * 2)
    }

    /// Computes physical hardware-encode dimensions from logical points, Retina scale, and resolution cap.
    /// Guarantees even dimensions and clamps width <= 4096 to avoid Intel QuickSync software fallback on 5K displays.
    public static func computeTargetDimensions(
        logicalWidth: CGFloat,
        logicalHeight: CGFloat,
        pointPixelScale: CGFloat,
        cap: ResolutionCap
    ) -> (width: Int, height: Int) {
        guard logicalWidth > 0, logicalHeight > 0, pointPixelScale > 0 else {
            return (2, 2)
        }

        var pixelWidth = logicalWidth * pointPixelScale
        var pixelHeight = logicalHeight * pointPixelScale

        if let maxHeight = cap.maxHeight {
            let capHeight = CGFloat(maxHeight)
            if pixelHeight > capHeight {
                let scale = capHeight / pixelHeight
                pixelWidth *= scale
                pixelHeight = capHeight
            }
        }

        let maxWidth = CGFloat(maxIntelQuickSyncWidth)
        if pixelWidth > maxWidth {
            let scale = maxWidth / pixelWidth
            pixelHeight *= scale
            pixelWidth = maxWidth
        }

        return (
            width: roundDownEven(pixelWidth),
            height: roundDownEven(pixelHeight)
        )
    }
}
