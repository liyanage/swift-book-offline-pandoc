import ArgumentParser
import Foundation
import CoreGraphics
import AppKit
import UniformTypeIdentifiers
import CoreText

@main
struct CoverGenerator: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cover-generator",
        abstract: "Generate Swift book cover images with vector logo and text"
    )

    @Option(help: "Version text to display (e.g. 'Swift 6.2 Edition')")
    var version: String = "Swift 6.2 Edition"

    @Option(help: "Output path for the PNG file")
    var output: String = "cover.png"

    @Option(help: "Path to the PDF logo file")
    var logoPath: String = "cover/Swift_logo_color.pdf"

    func run() throws {
        let outputURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        let logoURL = URL(fileURLWithPath: (logoPath as NSString).expandingTildeInPath)

        let generator = CoverImageGenerator()
        try generator.generateCover(
            version: version,
            logoURL: logoURL,
            outputURL: outputURL
        )

        print("Cover image generated: \(outputURL.path)")
    }
}

class CoverImageGenerator {
    static let canvasWidth: CGFloat = 1440
    static let canvasHeight: CGFloat = 2160
    static let horizontalOffset: CGFloat = 20

    func generateCover(version: String, logoURL: URL, outputURL: URL) throws {
        guard let context = createBitmapContext() else {
            throw CoverGeneratorError.contextCreationFailed
        }

        // Fill with white background
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: Self.canvasWidth, height: Self.canvasHeight))

        // Draw logo
        try drawLogo(context: context, logoURL: logoURL)

        // Draw main title
        try drawMainTitle(context: context)

        // Draw version text
        try drawVersionText(context: context, version: version)

        // Export to PNG
        try exportToPNG(context: context, outputURL: outputURL)
    }

    // Helper: convert a 4-letter OpenType tag (e.g., "opsz") to a FourCharCode key
    private func fourCharCode(_ tag: String) -> UInt32 {
        precondition(tag.utf8.count == 4, "Axis tag must be 4 chars")
        return tag.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func makeVariableFont(name postScriptOrFamily: String, size: CGFloat, opticalSize: CGFloat) -> CTFont {
        // Build the variation dictionary: keys are FourCharCode wrapped in NSNumber
        let opszKey = NSNumber(value: fourCharCode("opsz"))
        let variations: [NSNumber: CGFloat] = [opszKey: opticalSize]

        let attrs: [CFString: Any] = [
            kCTFontNameAttribute: postScriptOrFamily as CFString,   // or kCTFontFamilyNameAttribute
            kCTFontVariationAttribute: variations as NSDictionary
        ]

        let desc = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
        // The size here sets the em size; opsz is an additional axis value
        return CTFontCreateWithFontDescriptor(desc, size, nil)
    }

    private func createBitmapContext() -> CGContext? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil,
            width: Int(Self.canvasWidth),
            height: Int(Self.canvasHeight),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private func drawLogo(context: CGContext, logoURL: URL) throws {
        guard let pdfDocument = CGPDFDocument(logoURL as CFURL),
              let pdfPage = pdfDocument.page(at: 1) else {
            throw CoverGeneratorError.logoLoadFailed
        }

        // Position logo at top center
        let logoSize: CGFloat = 507
        let logoX = (Self.canvasWidth - logoSize) / 2 + Self.horizontalOffset
        let logoY = Self.canvasHeight - 759
        let logoRect = CGRect(x: logoX, y: logoY, width: logoSize, height: logoSize)

        context.saveGState()
        context.translateBy(x: logoRect.origin.x, y: logoRect.origin.y)
        context.scaleBy(x: logoRect.width / pdfPage.getBoxRect(.mediaBox).width,
                       y: logoRect.height / pdfPage.getBoxRect(.mediaBox).height)
        context.drawPDFPage(pdfPage)
        context.restoreGState()
    }

    private func centerJustifiedFrameSetter(string: String, fontSize: CGFloat) -> CTFramesetter {
        let font = makeVariableFont(name: "SFPro-Regular", size: fontSize, opticalSize: 17)
        // let font = CTFontCreateWithName("SFPro-Regular" as CFString, fontSize, nil)

        var alignment: CTTextAlignment = .center
        let paragraphStyle: CTParagraphStyle = withUnsafePointer(to: &alignment) { ptr in
            var setting = CTParagraphStyleSetting(
                spec: .alignment,
                valueSize: MemoryLayout<CTTextAlignment>.size,
                value: ptr
            )
            return CTParagraphStyleCreate(&setting, 1)
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(gray: 0.15, alpha: 1.0),
            .paragraphStyle: paragraphStyle,
        ]

        let attributedString = NSAttributedString(string: string, attributes: attributes)
        return CTFramesetterCreateWithAttributedString(attributedString)
    }

    private func drawMainTitle(context: CGContext) throws {
        let titleText = "The Swift\nProgramming\nLanguage"
        let framesetter = centerJustifiedFrameSetter(string: titleText, fontSize: 155)

        // Calculate text size
        let textSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: Self.canvasWidth, height: Self.canvasHeight),
            nil
        )

        let textX = (Self.canvasWidth - textSize.width) / 2 + Self.horizontalOffset
        let textY = Self.canvasHeight / 2 - textSize.height / 2 - 105
        let textRect = CGRect(x: textX, y: textY, width: textSize.width, height: textSize.height)

        let path = CGPath(rect: textRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)

        context.saveGState()
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private func drawVersionText(context: CGContext, version: String) throws {
        let framesetter = centerJustifiedFrameSetter(string: version, fontSize: 110)

        // Calculate text size
        let textSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: Self.canvasWidth, height: 150),
            nil
        )

        let textX = (Self.canvasWidth - textSize.width) / 2 + Self.horizontalOffset
        let textY: CGFloat = 469
        let textRect = CGRect(x: textX, y: textY, width: textSize.width, height: textSize.height)

        let path = CGPath(rect: textRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)

        context.saveGState()
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private func exportToPNG(context: CGContext, outputURL: URL) throws {
        guard let image = context.makeImage() else {
            throw CoverGeneratorError.imageCreationFailed
        }

        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CoverGeneratorError.exportFailed
        }

        CGImageDestinationAddImage(destination, image, nil)

        if !CGImageDestinationFinalize(destination) {
            throw CoverGeneratorError.exportFailed
        }
    }
}

enum CoverGeneratorError: Error, LocalizedError {
    case contextCreationFailed
    case logoLoadFailed
    case fontLoadFailed
    case imageCreationFailed
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .contextCreationFailed:
            return "Failed to create graphics context"
        case .logoLoadFailed:
            return "Failed to load PDF logo file"
        case .fontLoadFailed:
            return "Failed to load SF Pro font"
        case .imageCreationFailed:
            return "Failed to create image from context"
        case .exportFailed:
            return "Failed to export PNG file"
        }
    }
}