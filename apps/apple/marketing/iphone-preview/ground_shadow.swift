import CoreGraphics
import CoreImage
import Foundation
import ImageIO

guard CommandLine.arguments.count == 3 else {
    fputs("usage: ground_shadow.swift input.png output.png\n", stderr)
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let inputCG = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fputs("unable to read input image\n", stderr)
    exit(1)
}

let bounds = CGRect(x: 0, y: 0, width: inputCG.width, height: inputCG.height)
let shadowMask = CGContext(
    data: nil,
    width: inputCG.width,
    height: inputCG.height,
    bitsPerComponent: 8,
    bytesPerRow: inputCG.width * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)
guard let shadowMask else { exit(1) }
shadowMask.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
// CGContext's origin is bottom-left; the phone ends around y=1475 in the
// rendered image, so the grounding ellipse sits around y=420 in CG space.
shadowMask.fillEllipse(in: CGRect(x: bounds.midX - 185, y: 400, width: 370, height: 42))
guard let maskCG = shadowMask.makeImage() else { exit(1) }

let sourceImage = CIImage(cgImage: inputCG)
let mask = CIImage(cgImage: maskCG)
    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 24.0])
    .cropped(to: bounds)
let shadow = CIImage(color: CIColor(red: 0.02, green: 0.025, blue: 0.03, alpha: 0.28))
    .cropped(to: bounds)
    .applyingFilter("CIBlendWithMask", parameters: [
        kCIInputMaskImageKey: mask,
        kCIInputBackgroundImageKey: CIImage(color: CIColor.clear).cropped(to: bounds)
    ])
let outputImage = shadow.composited(over: sourceImage).cropped(to: bounds)
let context = CIContext(options: [.useSoftwareRenderer: false])
guard let outputCG = context.createCGImage(outputImage, from: bounds),
      let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil) else {
    fputs("unable to write output image\n", stderr)
    exit(1)
}
CGImageDestinationAddImage(destination, outputCG, [kCGImagePropertyPNGDictionary: [:]] as CFDictionary)
guard CGImageDestinationFinalize(destination) else { exit(1) }
