// Makes Glass's own pictures, GlassLight.heic and GlassDark.heic in Screendrop/: soft colour fields of blurred
// shapes, drawn by code, so Sukusho owns them outright. Glass shows them when the desktop picture can't be read
// without a folder-access prompt (`GlassPicture`). Run: swift scripts/make-glass-pictures.swift
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let size = CGSize(width: 1920, height: 1200)

/// A blurred field: a vertical gradient with soft discs of colour on it.
func picture(top: NSColor, bottom: NSColor, discs: [(x: CGFloat, y: CGFloat, r: CGFloat, color: NSColor)]) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let gradient = CGGradient(colorsSpace: space, colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
    for disc in discs {
        context.setFillColor(disc.color.cgColor)
        context.fillEllipse(in: CGRect(x: disc.x * size.width - disc.r, y: (1 - disc.y) * size.height - disc.r,
                                       width: 2 * disc.r, height: 2 * disc.r))
    }
    let sharp = CIImage(cgImage: context.makeImage()!)
    let blurred = sharp.clampedToExtent().applyingGaussianBlur(sigma: 140).cropped(to: sharp.extent)
    return CIContext().createCGImage(blurred, from: sharp.extent, format: .RGBA8, colorSpace: space)!
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func write(_ image: CGImage, to name: String) {
    let url = URL(fileURLWithPath: "Screendrop/\(name).heic")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
    precondition(CGImageDestinationFinalize(destination), "couldn't write \(url.path)")
    print("wrote \(url.path)")
}

// Light: sky to lilac with peach and mint glows, bright enough for dark text on light frost.
write(picture(top: rgb(0xBFD9F2), bottom: rgb(0xE6DDF2), discs: [
    (0.18, 0.30, 420, rgb(0x9CC4EE)), (0.78, 0.22, 380, rgb(0xF4C9B8)),
    (0.62, 0.78, 460, rgb(0xC9B8EC)), (0.12, 0.85, 360, rgb(0xBDE7DA)), (0.92, 0.62, 300, rgb(0xF2D8E6)),
]), to: "GlassLight")

// Dark: navy to indigo with teal and violet glows, dark enough for light text on dark frost.
write(picture(top: rgb(0x0E1A33), bottom: rgb(0x1A1233), discs: [
    (0.20, 0.28, 440, rgb(0x14506B)), (0.80, 0.25, 380, rgb(0x3E2370)),
    (0.60, 0.80, 480, rgb(0x23306E)), (0.10, 0.82, 360, rgb(0x0F4A4A)), (0.92, 0.65, 300, rgb(0x55235E)),
]), to: "GlassDark")
