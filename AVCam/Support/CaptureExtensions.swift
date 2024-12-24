/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
Extensions on AVFoundation capture and related types.
*/

@preconcurrency
import AVFoundation

extension CMVideoDimensions: @retroactive Equatable, @retroactive Comparable {
    
    static let zero = CMVideoDimensions()
    
    public static func == (lhs: CMVideoDimensions, rhs: CMVideoDimensions) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height
    }
    
    public static func < (lhs: CMVideoDimensions, rhs: CMVideoDimensions) -> Bool {
        lhs.width < rhs.width && lhs.height < rhs.height
    }
}

extension AVCaptureDevice {
    var activeFormat10BitVariant: AVCaptureDevice.Format? {
        formats.filter {
            $0.maxFrameRate == self.activeFormat.maxFrameRate &&
            $0.formatDescription.dimensions == self.activeFormat.formatDescription.dimensions
        }
        .first(where: { $0.isTenBitFormat })
    }
    
    var activeFormatAppleLogVariant: AVCaptureDevice.Format? {
        logger.debug("Current format: \(self.activeFormat.formatDescription.dimensions.width)x\(self.activeFormat.formatDescription.dimensions.height)")
        logger.debug("Current frame rate: \(self.activeFormat.maxFrameRate)")
        
        // First try to find a format matching current dimensions and frame rate
        let matchingFormat = formats.first(where: { format in
            let matches = format.formatDescription.dimensions == self.activeFormat.formatDescription.dimensions &&
            format.maxFrameRate >= self.activeFormat.maxFrameRate &&
            format.supportsAppleLog
            
            if matches {
                logger.debug("Found matching format with Apple Log support")
                logger.debug("Format: \(format.formatDescription.dimensions.width)x\(format.formatDescription.dimensions.height)")
                logger.debug("Frame rate: \(format.maxFrameRate)")
                logger.debug("Color spaces: \(format.supportedColorSpaces.map { String(describing: $0) })")
            }
            
            return matches
        })
        
        if matchingFormat != nil {
            return matchingFormat
        }
        
        logger.debug("No exact match found, searching for highest quality Apple Log format")
        
        // If no exact match, find the highest quality format that supports Apple Log
        let bestFormat = formats
            .filter { $0.supportsAppleLog }
            .sorted { $0.formatDescription.dimensions.width * $0.formatDescription.dimensions.height >
                     $1.formatDescription.dimensions.width * $1.formatDescription.dimensions.height }
            .first
        
        if let bestFormat = bestFormat {
            logger.debug("Found best alternative format:")
            logger.debug("Format: \(bestFormat.formatDescription.dimensions.width)x\(bestFormat.formatDescription.dimensions.height)")
            logger.debug("Frame rate: \(bestFormat.maxFrameRate)")
            logger.debug("Color spaces: \(bestFormat.supportedColorSpaces.map { String(describing: $0) })")
        } else {
            logger.debug("No Apple Log format found")
        }
        
        return bestFormat
    }
}

extension AVCaptureDevice.Format {
    var isTenBitFormat: Bool {
        formatDescription.mediaSubType.rawValue == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }
    
    var supportsAppleLog: Bool {
        let supports = self.supportedColorSpaces.contains(.appleLog)
        let formatDescription = "\(self.formatDescription.dimensions.width)x\(self.formatDescription.dimensions.height)"
        let colorSpaces: [AVCaptureColorSpace] = Array(self.supportedColorSpaces)
        logger.debug("Format \(formatDescription) supports Apple Log: \(supports)")
        logger.debug("Supported color spaces: \(colorSpaces.map { String(describing: $0) })")
        return supports
    }
    
    var maxFrameRate: Double {
        videoSupportedFrameRateRanges.last?.maxFrameRate ?? 0
    }
}

