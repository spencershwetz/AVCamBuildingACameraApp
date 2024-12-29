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
        logger.debug("Current color space: \(self.activeColorSpace.rawValue)")
        
        // First try to find a format matching current dimensions and frame rate
        let matchingFormat = formats.first(where: { format in
            // Check if this format explicitly supports Apple Log and BT.2020
            let hasAppleLog = format.supportedColorSpaces.contains(.appleLog)
            let hasBT2020 = format.supportedColorSpaces.contains(.HLG_BT2020) // This indicates BT.2020 primaries support
            let dimensionsMatch = format.formatDescription.dimensions == self.activeFormat.formatDescription.dimensions
            let frameRateMatch = format.maxFrameRate >= self.activeFormat.maxFrameRate
            
            // Make sure this format supports both Apple Log and BT.2020
            let colorSpaces = Set(format.supportedColorSpaces)
            let hasRequiredColorSpaces = hasAppleLog && hasBT2020
            
            let matches = hasRequiredColorSpaces && dimensionsMatch && frameRateMatch
            
            if matches {
                logger.debug("Found matching format with Apple Log support")
                logger.debug("Format: \(format.formatDescription.dimensions.width)x\(format.formatDescription.dimensions.height)")
                logger.debug("Frame rate: \(format.maxFrameRate)")
                logger.debug("Color spaces: \(Array(colorSpaces).map { String(describing: $0) })")
                logger.debug("Has BT.2020: \(hasBT2020)")
                logger.debug("Has Apple Log: \(hasAppleLog)")
            }
            
            return matches
        })
        
        if matchingFormat != nil {
            return matchingFormat
        }
        
        logger.debug("No exact match found, searching for highest quality Apple Log format")
        
        // If no exact match, find the highest quality format that supports both Apple Log and BT.2020
        let bestFormat = formats
            .filter { format in
                format.supportedColorSpaces.contains(.appleLog) &&
                format.supportedColorSpaces.contains(.HLG_BT2020) // Ensures BT.2020 primaries support
            }
            .sorted { $0.formatDescription.dimensions.width * $0.formatDescription.dimensions.height >
                     $1.formatDescription.dimensions.width * $1.formatDescription.dimensions.height }
            .first
        
        if let bestFormat = bestFormat {
            logger.debug("Found best alternative format:")
            logger.debug("Format: \(bestFormat.formatDescription.dimensions.width)x\(bestFormat.formatDescription.dimensions.height)")
            logger.debug("Frame rate: \(bestFormat.maxFrameRate)")
            logger.debug("Color spaces: \(Array(bestFormat.supportedColorSpaces).map { String(describing: $0) })")
        } else {
            logger.debug("No suitable Apple Log format found")
        }
        
        return bestFormat
    }
}

extension AVCaptureDevice.Format {
    var isTenBitFormat: Bool {
        formatDescription.mediaSubType.rawValue == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }
    
    var supportsAppleLog: Bool {
        // Check for both Apple Log and BT.2020 support
        let hasAppleLog = self.supportedColorSpaces.contains(.appleLog)
        let hasBT2020 = self.supportedColorSpaces.contains(.HLG_BT2020)
        let formatDescription = "\(self.formatDescription.dimensions.width)x\(self.formatDescription.dimensions.height)"
        let colorSpaces = Array(self.supportedColorSpaces)
        
        logger.debug("Format \(formatDescription) supports Apple Log: \(hasAppleLog)")
        logger.debug("Format \(formatDescription) supports BT.2020: \(hasBT2020)")
        logger.debug("Supported color spaces: \(colorSpaces.map { String(describing: $0) })")
        
        return hasAppleLog && hasBT2020 // Need both for proper Apple Log support
    }
    
    var film24FPS: CMTime {
        CMTimeMake(value: 1001, timescale: 24000)
    }
    
    var maxFrameRate: Double {
        videoSupportedFrameRateRanges.last?.maxFrameRate ?? 0
    }
    
    func supports24FPS() -> Bool {
        videoSupportedFrameRateRanges.contains { range in
            range.minFrameRate <= 23.976 && range.maxFrameRate >= 23.976
        }
    }
    
    var appleLogColorSpace: AVCaptureColorSpace {
        .appleLog
    }
    
    var sRGBColorSpace: AVCaptureColorSpace {
        .sRGB
    }
    
    func supportsColorSpace(_ colorSpace: AVCaptureColorSpace) -> Bool {
        supportedColorSpaces.contains(colorSpace)
    }
}

