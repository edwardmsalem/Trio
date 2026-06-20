import AVFoundation
import CoreVideo
import Foundation

/// A rough food-portion estimate derived from a LiDAR depth capture. Advisory only
/// — it nudges the AI's carb estimate, never sets carbs or doses.
struct PortionEstimate {
    enum Size: String {
        case small
        case medium
        case large
    }

    let size: Size
    let volumeML: Double // approximate food volume above the plate, in mL (cm³)

    /// A line for the AI prompt so it can weight its estimate by measured size.
    var promptHint: String {
        "DEPTH SENSOR: the plate was measured with LiDAR and the food looks like a \(size.rawValue) portion (~\(Int(volumeML)) mL of food above the plate). Weight your carb estimate toward this measured size."
    }

    /// A short line for the review UI.
    var displayText: String {
        "LiDAR portion: \(size.rawValue) (~\(Int(volumeML)) mL)"
    }
}

/// Turns a LiDAR depth map into a coarse food-volume estimate by treating the
/// median depth as the plate surface and integrating how much the food rises above
/// it, scaled to real-world area via the camera intrinsics. Approximate by design;
/// returns nil whenever the data isn't suitable so the caller falls back cleanly.
enum PortionVolumeEstimator {
    static func estimate(from depthData: AVDepthData) -> PortionEstimate? {
        let converted = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let map = converted.depthDataMap
        guard let calibration = converted.cameraCalibrationData else { return nil }

        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }

        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(map) else { return nil }

        // Sample the central 60% — the food is assumed roughly centered on the plate.
        let xStart = Int(Double(width) * 0.2)
        let xEnd = Int(Double(width) * 0.8)
        let yStart = Int(Double(height) * 0.2)
        let yEnd = Int(Double(height) * 0.8)

        func depthAt(_ x: Int, _ y: Int) -> Float {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            return row[x]
        }

        // Collect valid depths to find the plate surface (median).
        var depths: [Float] = []
        depths.reserveCapacity((xEnd - xStart) * (yEnd - yStart) / 4)
        var yy = yStart
        while yy < yEnd {
            var xx = xStart
            while xx < xEnd {
                let d = depthAt(xx, yy)
                if d.isFinite, d > 0.05, d < 2.0 { depths.append(d) } // 5 cm – 2 m plausible
                xx += 2
            }
            yy += 2
        }
        guard depths.count > 200 else { return nil }

        depths.sort()
        let plateDepth = depths[depths.count / 2] // median ≈ plate/table surface

        // Camera intrinsics, scaled from their reference resolution to the depth map.
        let intrinsics = calibration.intrinsicMatrix
        let reference = calibration.intrinsicMatrixReferenceDimensions
        guard reference.width > 0, reference.height > 0 else { return nil }
        let fx = Double(intrinsics.columns.0.x) * Double(width) / Double(reference.width)
        let fy = Double(intrinsics.columns.1.y) * Double(height) / Double(reference.height)
        guard fx > 0, fy > 0 else { return nil }

        // Integrate height-above-plate × per-pixel real-world area for raised pixels.
        let minRise: Float = 0.005 // ignore < 5 mm (noise)
        let maxRise: Float = 0.15 // clamp > 15 cm (outliers)
        var volumeCubicMeters = 0.0
        yy = yStart
        while yy < yEnd {
            var xx = xStart
            while xx < xEnd {
                let d = depthAt(xx, yy)
                if d.isFinite, d > 0.05, d < plateDepth {
                    let rise = min(maxRise, plateDepth - d)
                    if rise > minRise {
                        // Pixel footprint at this depth (sampled every 2 px).
                        let pixelArea = (Double(d) / fx) * (Double(d) / fy) * 4.0
                        volumeCubicMeters += Double(rise) * pixelArea
                    }
                }
                xx += 2
            }
            yy += 2
        }

        let volumeML = volumeCubicMeters * 1_000_000 // m³ → cm³ (mL)
        guard volumeML > 1 else { return nil } // nothing meaningfully raised

        let size: PortionEstimate.Size
        switch volumeML {
        case ..<150: size = .small
        case 150 ..< 500: size = .medium
        default: size = .large
        }
        return PortionEstimate(size: size, volumeML: min(volumeML, 4000))
    }

    static var isAvailable: Bool {
        AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) != nil
    }
}
