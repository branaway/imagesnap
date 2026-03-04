import AVFoundation
import CoreImage
import CoreMedia
import AppKit
import Foundation

// MARK: - Version

let VERSION = "0.3.0"

// MARK: - Command Line Argument Parser

struct Arguments {
    var showHelp: Bool = false
    var verbose: Bool = false
    var quiet: Bool = false
    var listDevices: Bool = false
    var listSizes: Bool = false  // -S: list supported capture sizes for device
    var deviceName: String? = nil
    var warmupDelay: Double = 3.0  // Default 3 seconds (matches v0.2.13+)
    var timelapse: Double? = nil   // Interval in seconds
    var maxCaptures: Int? = nil    // -n flag: limit number of timelapse pictures
    var imageSize: (width: Int, height: Int)? = nil  // -s WxH: output dimensions
    var requestMaxSize: Bool = false  // -M: use largest supported size
    var filename: String = "snapshot.jpg"
    var enableContrast: Bool = false
    var enableDenoise: Bool = false
    var enableSharpen: Bool = false
    var averageFrames: Int? = nil  // -a N: capture N frames and merge (mean) to reduce noise
    var medianFrames: Int? = nil  // --median N: capture N frames and merge (median) to reduce salt-and-pepper noise
    var parseError: String? = nil  // Set when an unknown or invalid option is seen
    
    static func parse() -> Arguments {
        var args = Arguments()
        let arguments = CommandLine.arguments
        var i = 1
        
        while i < arguments.count {
            let arg = arguments[i]
            
            switch arg {
            case "-h", "--help":
                args.showHelp = true
            case "-v":
                args.verbose = true
            case "-q":
                args.quiet = true
            case "-l":
                args.listDevices = true
            case "-S":
                args.listSizes = true
            case "-d":
                i += 1
                if i < arguments.count {
                    args.deviceName = arguments[i]
                }
            case "-w":
                i += 1
                if i < arguments.count, let delay = Double(arguments[i]) {
                    args.warmupDelay = delay
                }
            case "-t":
                i += 1
                if i < arguments.count, let interval = Double(arguments[i]) {
                    args.timelapse = interval
                }
            case "-n":
                i += 1
                if i < arguments.count, let count = Int(arguments[i]) {
                    args.maxCaptures = count
                }
            case "-s":
                i += 1
                if i < arguments.count {
                    let parts = arguments[i].split(separator: "x", omittingEmptySubsequences: false)
                    if parts.count == 2,
                       let w = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                       let h = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                       w > 0, h > 0 {
                        args.imageSize = (width: w, height: h)
                    }
                }
            case "-M", "--max-size":
                args.requestMaxSize = true
            case "-e", "--enhance":
                args.enableContrast = true
                args.enableDenoise = true
                args.enableSharpen = true
            case "-c", "--contrast":
                args.enableContrast = true
            case "--denoise":
                args.enableDenoise = true
            case "--sharpen":
                args.enableSharpen = true
            case "-a", "--average":
                i += 1
                if i < arguments.count, let n = Int(arguments[i]), n > 0 {
                    args.averageFrames = n
                }
            case "--median":
                i += 1
                if i < arguments.count, let n = Int(arguments[i]), n > 0 {
                    args.medianFrames = n
                }
            default:
                if arg.hasPrefix("-") {
                    args.parseError = "Unknown option: \(arg). Use -h for help."
                } else {
                    args.filename = arg
                }
            }
            i += 1
        }
        
        return args
    }
    
    static func printHelp() {
        let programName = (CommandLine.arguments[0] as NSString).lastPathComponent
        let help = """
        USAGE: \(programName) [options] [filename]
        Version: \(VERSION)
        Captures an image from a video device and saves it in a file.
        If no device is specified, the system default will be used.
        If no filename is specified, snapshot.jpg will be used.
        Supported image types: JPEG, TIFF, PNG, GIF, BMP
        
          -h          This help message
          -v          Verbose mode
          -l          List available video devices
          -t x.xx     Take a picture every x.xx seconds
          -n x        Limit the number of timelapse pictures to x
          -s WxH      Capture at camera-supported size only (use -S to list sizes)
          -M          Capture at the largest size supported by the device
          -S          List supported capture sizes for the selected device
          -q          Quiet mode. Do not output any text
          -w x.xx     Warmup. Delay snapshot x.xx seconds after turning on camera
          -d device   Use named video device
          -e          Apply all enhancements (contrast, denoise, sharpen)
          -c          Auto contrast
          --denoise   Noise reduction
          --sharpen   Sharpen
          -a N        Average N frames into one image (reduces noise)
          --median N  Median of N frames (better for salt-and-pepper noise, preserves edges)
        """
        print(help)
    }
}

// MARK: - Output Helpers

class Output {
    static var quiet = false
    static var verbose = false
    
    static func log(_ message: String, terminator: String = "\n") {
        if !quiet {
            print(message, terminator: terminator)
            fflush(stdout)
        }
    }
    
    static func verboseLog(_ message: String) {
        if verbose && !quiet {
            print(message)
            fflush(stdout)
        }
    }
    
    static func error(_ message: String) {
        fputs("\(message)\n", stderr)
    }
}

// MARK: - Camera Manager

class CameraManager: NSObject {
    private var captureSession: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var currentDevice: AVCaptureDevice?
    private var capturedImage: NSImage?
    private var captureComplete = false
    private var captureError: Error?
    /// On macOS, we keep the device locked until after startRunning() so the session doesn't override activeFormat.
    private var deviceLockedForCustomFormat = false
    
    // Get all available video capture devices
    static func listDevices() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .externalUnknown
            ],
            mediaType: .video,
            position: .unspecified
        )
        return discoverySession.devices
    }
    
    static func printDeviceList() {
        let devices = listDevices()
        
        if devices.isEmpty {
            print("No video devices found.")
            return
        }
        
        print("Video Devices:")
        for device in devices {
            print("=> \(device.localizedName)")
        }
    }
    
    static func findDevice(matching name: String?) -> AVCaptureDevice? {
        let devices = listDevices()
        
        guard !devices.isEmpty else {
            return nil
        }
        
        // If no name specified, use first device
        guard let name = name else {
            return devices.first
        }
        
        // First try exact match
        if let exactMatch = devices.first(where: { $0.localizedName == name }) {
            return exactMatch
        }
        
        // Then try substring match (case-insensitive)
        let lowercaseName = name.lowercased()
        if let substringMatch = devices.first(where: { 
            $0.localizedName.lowercased().contains(lowercaseName) 
        }) {
            return substringMatch
        }
        
        return nil
    }
    
    var deviceName: String {
        return currentDevice?.localizedName ?? "Unknown"
    }
    
    /// Dimensions from a device format (video capture size).
    private static func dimensions(of format: AVCaptureDevice.Format) -> (width: Int, height: Int) {
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return (width: Int(dims.width), height: Int(dims.height))
    }
    
    /// All unique capture sizes supported by the device, sorted (smallest first).
    static func supportedSizes(for device: AVCaptureDevice) -> [(width: Int, height: Int)] {
        var set = Set<String>()
        var out: [(width: Int, height: Int)] = []
        for format in device.formats {
            let d = dimensions(of: format)
            let key = "\(d.width)x\(d.height)"
            if set.insert(key).inserted {
                out.append(d)
            }
        }
        out.sort { a, b in
            if a.width != b.width { return a.width < b.width }
            return a.height < b.height
        }
        return out
    }
    
    /// A format on this device that matches the given size, or nil.
    static func format(matching size: (width: Int, height: Int), on device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        device.formats.first { dimensions(of: $0) == size }
    }
    
    static func printSupportedSizes(for device: AVCaptureDevice) {
        let sizes = supportedSizes(for: device)
        if sizes.isEmpty {
            print("No supported capture sizes reported for \"\(device.localizedName)\".")
            return
        }
        print("Supported capture sizes for \"\(device.localizedName)\":")
        for s in sizes {
            print("  \(s.width)x\(s.height)")
        }
    }
    
    func setupSession(device: AVCaptureDevice, requestedSize: (width: Int, height: Int)? = nil) -> Bool {
        currentDevice = device
        
        Output.verboseLog("Setting up capture session for device: \(device.localizedName)")
        
        let customFormat: AVCaptureDevice.Format?
        if let size = requestedSize {
            guard let format = Self.format(matching: size, on: device) else {
                Output.error("Error: Size \(size.width)x\(size.height) is not supported by this device. Use -S to list supported sizes.")
                return false
            }
            customFormat = format
            Output.verboseLog("Using device format \(size.width)x\(size.height)")
        } else {
            customFormat = nil
        }
        
        captureSession = AVCaptureSession()
        captureSession?.beginConfiguration()
        defer { captureSession?.commitConfiguration() }
        
        if let format = customFormat {
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                #if os(iOS) || (os(macOS) && targetEnvironment(macCatalyst))
                device.unlockForConfiguration()
                #else
                // macOS: keep lock until after startRunning() so session preset doesn't override activeFormat
                deviceLockedForCustomFormat = true
                #endif
            } catch {
                Output.error("Error: Could not set device format: \(error.localizedDescription)")
                return false
            }
            #if os(iOS) || (os(macOS) && targetEnvironment(macCatalyst))
            captureSession?.sessionPreset = .inputPriority
            #else
            // macOS: do not set sessionPreset so the session uses the device's activeFormat
            #endif
        } else {
            captureSession?.sessionPreset = .photo
        }
        
        do {
            let input = try AVCaptureDeviceInput(device: device)
            
            if captureSession?.canAddInput(input) == true {
                captureSession?.addInput(input)
            } else {
                Output.error("Error: Cannot add camera input to session.")
                if deviceLockedForCustomFormat { device.unlockForConfiguration(); deviceLockedForCustomFormat = false }
                return false
            }
            
            photoOutput = AVCapturePhotoOutput()
            
            if let photoOutput = photoOutput,
               captureSession?.canAddOutput(photoOutput) == true {
                captureSession?.addOutput(photoOutput)
            } else {
                Output.error("Error: Cannot add photo output to session.")
                if deviceLockedForCustomFormat { device.unlockForConfiguration(); deviceLockedForCustomFormat = false }
                return false
            }
            
            return true
            
        } catch {
            Output.error("Error setting up camera: \(error.localizedDescription)")
            if deviceLockedForCustomFormat { device.unlockForConfiguration(); deviceLockedForCustomFormat = false }
            return false
        }
    }
    
    func startSession() {
        Output.verboseLog("Starting capture session...")
        captureSession?.startRunning()
        if deviceLockedForCustomFormat, let device = currentDevice {
            device.unlockForConfiguration()
            deviceLockedForCustomFormat = false
        }
    }
    
    func stopSession() {
        Output.verboseLog("Stopping capture session...")
        captureSession?.stopRunning()
        if deviceLockedForCustomFormat, let device = currentDevice {
            device.unlockForConfiguration()
            deviceLockedForCustomFormat = false
        }
    }
    
    func capturePhoto() -> NSImage? {
        capturedImage = nil
        captureComplete = false
        captureError = nil
        
        guard let photoOutput = photoOutput else {
            Output.error("Error: Photo output not configured.")
            return nil
        }
        
        let settings = AVCapturePhotoSettings()
        settings.flashMode = .off
        
        photoOutput.capturePhoto(with: settings, delegate: self)
        
        // Wait for capture to complete
        let timeout = Date().addingTimeInterval(10.0)
        while !captureComplete && Date() < timeout {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        
        if let error = captureError {
            Output.error("Capture error: \(error.localizedDescription)")
            return nil
        }
        
        return capturedImage
    }
    
    func saveImage(_ image: NSImage, to path: String) -> Bool {
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else {
            Output.error("Error: Could not process image data.")
            return false
        }
        
        let fileExtension = (path as NSString).pathExtension.lowercased()
        let fileType: NSBitmapImageRep.FileType
        var properties: [NSBitmapImageRep.PropertyKey: Any] = [:]
        
        switch fileExtension {
        case "png":
            fileType = .png
        case "tiff", "tif":
            fileType = .tiff
        case "bmp":
            fileType = .bmp
        case "gif":
            fileType = .gif
        default:
            fileType = .jpeg
            properties[.compressionFactor] = 0.9
        }
        
        guard let imageData = bitmapRep.representation(using: fileType, properties: properties) else {
            Output.error("Error: Could not encode image.")
            return false
        }
        
        do {
            let url = URL(fileURLWithPath: path)
            try imageData.write(to: url)
            return true
        } catch {
            Output.error("Error saving image: \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        defer { captureComplete = true }
        
        if let error = error {
            captureError = error
            return
        }
        
        guard let imageData = photo.fileDataRepresentation() else {
            Output.error("Error: Could not get image data from photo.")
            return
        }
        
        capturedImage = NSImage(data: imageData)
    }
}

// MARK: - Auto Contrast (Core Image)

/// Convert NSImage to CIImage for processing.
private func ciImage(from image: NSImage) -> CIImage? {
    guard let tiffData = image.tiffRepresentation,
          let bitmapRep = NSBitmapImageRep(data: tiffData),
          let cgImage = bitmapRep.cgImage else { return nil }
    return CIImage(cgImage: cgImage)
}

/// Render CIImage to NSImage.
private func nsImage(from ciImage: CIImage, context: CIContext) -> NSImage? {
    let extent = ciImage.extent
    guard extent.width > 0, extent.height > 0,
          let cgImage = context.createCGImage(ciImage, from: extent) else { return nil }
    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
}

/// Compute 2nd and 98th percentile bin index (0–255) for one channel from histogram counts.
private func percentileBounds(counts: [Float], lowPercentile: Float = 0.02, highPercentile: Float = 0.98) -> (low: Int, high: Int) {
    let total = counts.reduce(0, +)
    guard total > 0 else { return (0, 255) }
    var cum: Float = 0
    var low = 0
    var high = 255
    for (i, c) in counts.enumerated() {
        cum += c
        if low == 0 && cum >= total * lowPercentile { low = i }
        if cum >= total * highPercentile { high = i; break }
    }
    if low >= high { high = min(255, low + 1) }
    return (low, high)
}

/// Apply auto contrast by stretching each channel so 2nd–98th percentile maps to full range.
func applyAutoContrast(to image: NSImage) -> NSImage? {
    guard let inputCIImage = ciImage(from: image) else { return nil }
    let context = CIContext(options: [.useSoftwareRenderer: false])
    let extent = inputCIImage.extent
    guard extent.width > 0, extent.height > 0 else { return nil }

    // Build 256-bin area histogram (one pixel per bin; R,G,B = counts per channel).
    guard let histogramFilter = CIFilter(name: "CIAreaHistogram") else { return nil }
    histogramFilter.setValue(inputCIImage, forKey: kCIInputImageKey)
    histogramFilter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
    histogramFilter.setValue(256, forKey: "InputCount")
    histogramFilter.setValue(1, forKey: "InputScale")
    guard let histogramCIImage = histogramFilter.outputImage else { return nil }

    // Render histogram to float buffer to read counts (avoids 8-bit clamping).
    let rowBytes = 256 * 4 * 4 // 256 pixels, RGBA, 4 bytes per float
    var histogramBuffer = [Float](repeating: 0, count: 256 * 4)
    context.render(
        histogramCIImage,
        toBitmap: &histogramBuffer,
        rowBytes: rowBytes,
        bounds: CGRect(x: 0, y: 0, width: 256, height: 1),
        format: .RGBAf,
        colorSpace: nil
    )

    var rCounts = [Float](repeating: 0, count: 256)
    var gCounts = [Float](repeating: 0, count: 256)
    var bCounts = [Float](repeating: 0, count: 256)
    for i in 0..<256 {
        rCounts[i] = histogramBuffer[i * 4 + 0]
        gCounts[i] = histogramBuffer[i * 4 + 1]
        bCounts[i] = histogramBuffer[i * 4 + 2]
    }

    let (rLow, rHigh) = percentileBounds(counts: rCounts)
    let (gLow, gHigh) = percentileBounds(counts: gCounts)
    let (bLow, bHigh) = percentileBounds(counts: bCounts)

    // CIColorMatrix works in 0–1; bins map to intensity i/255. Map [low/255, high/255] -> [0, 1]: scale = 255/(high-low), bias = -low/(high-low).
    func scaleAndBias(low: Int, high: Int) -> (scale: Float, bias: Float) {
        let span = Float(high - low)
        guard span > 0 else { return (1, 0) }
        return (255 / span, -Float(low) / span)
    }
    let (rS, rB) = scaleAndBias(low: rLow, high: rHigh)
    let (gS, gB) = scaleAndBias(low: gLow, high: gHigh)
    let (bS, bB) = scaleAndBias(low: bLow, high: bHigh)

    guard let matrixFilter = CIFilter(name: "CIColorMatrix") else { return nil }
    matrixFilter.setValue(inputCIImage, forKey: kCIInputImageKey)
    matrixFilter.setValue(CIVector(x: CGFloat(rS), y: 0, z: 0, w: 0), forKey: "inputRVector")
    matrixFilter.setValue(CIVector(x: 0, y: CGFloat(gS), z: 0, w: 0), forKey: "inputGVector")
    matrixFilter.setValue(CIVector(x: 0, y: 0, z: CGFloat(bS), w: 0), forKey: "inputBVector")
    matrixFilter.setValue(CIVector(x: CGFloat(rB), y: CGFloat(gB), z: CGFloat(bB), w: 0), forKey: "inputBiasVector")
    guard let outputCIImage = matrixFilter.outputImage else { return nil }

    return nsImage(from: outputCIImage, context: context)
}

/// Apply noise reduction (CINoiseReduction). Use before sharpening.
private func applyDenoise(to image: NSImage, context: CIContext) -> NSImage? {
    guard let input = ciImage(from: image) else { return nil }
    guard let filter = CIFilter(name: "CINoiseReduction") else { return nil }
    filter.setValue(input, forKey: kCIInputImageKey)
    filter.setValue(0.02, forKey: "inputNoiseLevel")
    filter.setValue(0.40, forKey: "inputSharpness")
    guard let output = filter.outputImage else { return nil }
    return nsImage(from: output, context: context)
}

/// Apply luminance sharpening (CISharpenLuminance).
private func applySharpen(to image: NSImage, context: CIContext) -> NSImage? {
    guard let input = ciImage(from: image) else { return nil }
    guard let filter = CIFilter(name: "CISharpenLuminance") else { return nil }
    filter.setValue(input, forKey: kCIInputImageKey)
    filter.setValue(0.5, forKey: "inputSharpness")
    guard let output = filter.outputImage else { return nil }
    return nsImage(from: output, context: context)
}

/// Apply only the requested enhancements. Order: contrast → denoise → sharpen.
func processSnapshot(_ image: NSImage, contrast: Bool, denoise: Bool, sharpen: Bool) -> NSImage {
    guard contrast || denoise || sharpen else { return image }
    let context = CIContext(options: [.useSoftwareRenderer: false])
    var current = image
    if contrast { current = applyAutoContrast(to: current) ?? current }
    if denoise { current = applyDenoise(to: current, context: context) ?? current }
    if sharpen { current = applySharpen(to: current, context: context) ?? current }
    return current
}

/// Merge multiple images by per-pixel arithmetic mean in the same color space as the source.
/// Done in bitmap space to avoid Core Image's linear-space blending (which darkens when adding).
func meanImage(images: [NSImage], context: CIContext) -> NSImage? {
    guard let firstData = images.first?.tiffRepresentation,
          let firstRep = NSBitmapImageRep(data: firstData) else { return nil }
    let w = firstRep.pixelsWide
    let h = firstRep.pixelsHigh
    let n = images.count
    guard w > 0, h > 0, n > 0 else { return nil }

    // Accumulate R,G,B as Double to avoid rounding errors
    var sumR = [Double](repeating: 0, count: w * h)
    var sumG = [Double](repeating: 0, count: w * h)
    var sumB = [Double](repeating: 0, count: w * h)

    for image in images {
        guard let tiffData = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              rep.pixelsWide == w, rep.pixelsHigh == h else { return nil }
        guard let data = rep.bitmapData else { return nil }
        let bpp = rep.bitsPerPixel / 8
        let bpr = rep.bytesPerRow
        let spp = rep.samplesPerPixel
        for y in 0..<h {
            for x in 0..<w {
                let offset = y * bpr + x * bpp
                let r = Double(data[offset])
                let g = spp >= 2 ? Double(data[offset + 1]) : r
                let b = spp >= 3 ? Double(data[offset + 2]) : r
                let i = y * w + x
                sumR[i] += r
                sumG[i] += g
                sumB[i] += b
            }
        }
    }

    // Build output bitmap: mean per channel, same layout as first rep
    let bpr = firstRep.bytesPerRow
    guard let outRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: w,
        pixelsHigh: h,
        bitsPerSample: firstRep.bitsPerSample,
        samplesPerPixel: firstRep.samplesPerPixel,
        hasAlpha: firstRep.hasAlpha,
        isPlanar: false,
        colorSpaceName: firstRep.colorSpaceName,
        bytesPerRow: bpr,
        bitsPerPixel: firstRep.bitsPerPixel
    ) else { return nil }
    guard let outData = outRep.bitmapData else { return nil }
    let outBpp = outRep.bitsPerPixel / 8
    let outBpr = outRep.bytesPerRow
    let outSpp = outRep.samplesPerPixel
    let invN = 1.0 / Double(n)
    for y in 0..<h {
        for x in 0..<w {
            let i = y * w + x
            let offset = y * outBpr + x * outBpp
            outData[offset] = UInt8(min(255, max(0, sumR[i] * invN)))
            if outSpp >= 2 { outData[offset + 1] = UInt8(min(255, max(0, sumG[i] * invN))) }
            if outSpp >= 3 { outData[offset + 2] = UInt8(min(255, max(0, sumB[i] * invN))) }
            if outSpp >= 4 { outData[offset + 3] = 255 }
        }
    }

    let outImage = NSImage(size: NSSize(width: w, height: h))
    outImage.addRepresentation(outRep)
    return outImage
}

/// Merge multiple images by per-pixel median. Better for salt-and-pepper noise and preserves edges.
func medianImage(images: [NSImage], context: CIContext) -> NSImage? {
    guard let firstData = images.first?.tiffRepresentation,
          let firstRep = NSBitmapImageRep(data: firstData) else { return nil }
    let w = firstRep.pixelsWide
    let h = firstRep.pixelsHigh
    let n = images.count
    guard w > 0, h > 0, n > 0 else { return nil }

    // Collect per-pixel values from all images (reused for each pixel)
    var rVals = [UInt8](repeating: 0, count: n)
    var gVals = [UInt8](repeating: 0, count: n)
    var bVals = [UInt8](repeating: 0, count: n)

    // Load all images into a flat buffer [img][y][x] for each channel so we can median per pixel
    var allR = [[UInt8]](repeating: [], count: n)
    var allG = [[UInt8]](repeating: [], count: n)
    var allB = [[UInt8]](repeating: [], count: n)
    let pixels = w * h
    for (idx, image) in images.enumerated() {
        guard let tiffData = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              rep.pixelsWide == w, rep.pixelsHigh == h,
              let data = rep.bitmapData else { return nil }
        let bpp = rep.bitsPerPixel / 8
        let bpr = rep.bytesPerRow
        let spp = rep.samplesPerPixel
        allR[idx] = [UInt8](repeating: 0, count: pixels)
        allG[idx] = [UInt8](repeating: 0, count: pixels)
        allB[idx] = [UInt8](repeating: 0, count: pixels)
        for y in 0..<h {
            for x in 0..<w {
                let offset = y * bpr + x * bpp
                let i = y * w + x
                allR[idx][i] = data[offset]
                allG[idx][i] = spp >= 2 ? data[offset + 1] : data[offset]
                allB[idx][i] = spp >= 3 ? data[offset + 2] : data[offset]
            }
        }
    }

    func medianOf(_ a: inout [UInt8]) -> UInt8 {
        a.sort()
        return a[n / 2]
    }

    let bpr = firstRep.bytesPerRow
    guard let outRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: w,
        pixelsHigh: h,
        bitsPerSample: firstRep.bitsPerSample,
        samplesPerPixel: firstRep.samplesPerPixel,
        hasAlpha: firstRep.hasAlpha,
        isPlanar: false,
        colorSpaceName: firstRep.colorSpaceName,
        bytesPerRow: bpr,
        bitsPerPixel: firstRep.bitsPerPixel
    ) else { return nil }
    guard let outData = outRep.bitmapData else { return nil }
    let outBpp = outRep.bitsPerPixel / 8
    let outBpr = outRep.bytesPerRow
    let outSpp = outRep.samplesPerPixel
    for y in 0..<h {
        for x in 0..<w {
            let i = y * w + x
            for k in 0..<n {
                rVals[k] = allR[k][i]
                gVals[k] = allG[k][i]
                bVals[k] = allB[k][i]
            }
            let offset = y * outBpr + x * outBpp
            outData[offset] = medianOf(&rVals)
            if outSpp >= 2 { outData[offset + 1] = medianOf(&gVals) }
            if outSpp >= 3 { outData[offset + 2] = medianOf(&bVals) }
            if outSpp >= 4 { outData[offset + 3] = 255 }
        }
    }

    let outImage = NSImage(size: NSSize(width: w, height: h))
    outImage.addRepresentation(outRep)
    return outImage
}

/// Capture N frames and merge with mean or median; single frame if N == 1. Caller ensures camera is running.
func captureMerged(camera: CameraManager, frameCount: Int, useMedian: Bool) -> NSImage? {
    guard frameCount >= 1 else { return nil }
    if frameCount == 1 {
        return camera.capturePhoto()
    }
    Output.verboseLog(useMedian ? "Median of \(frameCount) frames..." : "Averaging \(frameCount) frames...")
    var frames: [NSImage] = []
    for _ in 0..<frameCount {
        guard let img = camera.capturePhoto() else { return nil }
        frames.append(img)
    }
    let context = CIContext(options: [.useSoftwareRenderer: false])
    if useMedian {
        return medianImage(images: frames, context: context) ?? frames.first
    }
    return meanImage(images: frames, context: context) ?? frames.first
}

// MARK: - Filename Utilities

func generateTimelapseFilename(base: String, index: Int) -> String {
    let url = URL(fileURLWithPath: base)
    let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
    let nameWithoutExt = url.deletingPathExtension().path
    
    // Format: snapshot-00001.jpg (5 digit padding like original)
    let paddedIndex = String(format: "%05d", index)
    
    return "\(nameWithoutExt)-\(paddedIndex).\(ext)"
}

func findStartingSequenceNumber(base: String) -> Int {
    // Check existing files and find where to continue numbering
    let url = URL(fileURLWithPath: base)
    let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
    let nameWithoutExt = url.deletingPathExtension().lastPathComponent
    let directory = url.deletingLastPathComponent().path
    let workingDir = directory.isEmpty ? "." : directory
    
    let fileManager = FileManager.default
    var maxNumber = 0
    
    do {
        let files = try fileManager.contentsOfDirectory(atPath: workingDir)
        let pattern = "\(nameWithoutExt)-(\\d+)\\.\(ext)"
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        
        for file in files {
            let range = NSRange(file.startIndex..., in: file)
            if let match = regex.firstMatch(in: file, options: [], range: range),
               let numberRange = Range(match.range(at: 1), in: file),
               let number = Int(file[numberRange]) {
                maxNumber = max(maxNumber, number)
            }
        }
    } catch {
        // Ignore errors, start from 1
    }
    
    return maxNumber + 1
}

// MARK: - Main Execution

func main() -> Int32 {
    let args = Arguments.parse()
    
    Output.quiet = args.quiet
    Output.verbose = args.verbose
    
    if let err = args.parseError {
        Output.error(err)
        return 1
    }
    
    if args.showHelp {
        Arguments.printHelp()
        return 0
    }
    
    if args.listDevices {
        CameraManager.printDeviceList()
        return 0
    }
    
    // Resolve device early so we can list sizes or validate -s
    guard let device = CameraManager.findDevice(matching: args.deviceName) else {
        if let name = args.deviceName {
            Output.error("Error: No video device found matching \"\(name)\"")
        } else {
            Output.error("Error: No video devices available.")
        }
        return 1
    }
    
    if args.listSizes {
        CameraManager.printSupportedSizes(for: device)
        return 0
    }
    
    // Check camera authorization status
    let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
    
    switch authStatus {
    case .denied, .restricted:
        Output.error("Error: Camera access denied. Please grant permission in System Preferences > Privacy > Camera.")
        return 1
    case .notDetermined:
        // Request permission synchronously for CLI
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .video) { result in
            granted = result
            semaphore.signal()
        }
        semaphore.wait()
        if !granted {
            Output.error("Error: Camera access not granted.")
            return 1
        }
    case .authorized:
        break
    @unknown default:
        break
    }
    
    let camera = CameraManager()
    
    let requestedSize: (width: Int, height: Int)?
    if args.requestMaxSize {
        let sizes = CameraManager.supportedSizes(for: device)
        if let largest = sizes.last {
            requestedSize = largest
            Output.verboseLog("Using maximum size: \(largest.width)x\(largest.height)")
        } else {
            Output.error("Error: No supported capture sizes reported for this device.")
            return 1
        }
    } else {
        requestedSize = args.imageSize
    }
    
    guard camera.setupSession(device: device, requestedSize: requestedSize) else {
        return 1
    }
    
    camera.startSession()
    
    // Print capturing message with dots for warmup
    Output.log("Capturing image from device \"\(camera.deviceName)\"", terminator: "")
    
    // Warmup with visual dots
    if args.warmupDelay > 0 {
        let dotInterval = 0.1
        let totalDots = Int(args.warmupDelay / dotInterval)
        for _ in 0..<totalDots {
            Output.log(".", terminator: "")
            Thread.sleep(forTimeInterval: dotInterval)
        }
    }
    
    // Handle timelapse mode
    if let interval = args.timelapse {
        var captureCount = 0
        var sequenceNumber = findStartingSequenceNumber(base: args.filename)
        
        // Set up signal handler for graceful exit
        signal(SIGINT) { _ in
            Output.log("\nTimelapse stopped.")
            exit(0)
        }
        
        while true {
            captureCount += 1
            
            // Check if we've reached the limit
            if let maxCaptures = args.maxCaptures, captureCount > maxCaptures {
                break
            }
            
            let outputPath = generateTimelapseFilename(base: args.filename, index: sequenceNumber)
            
            let frameCount = args.medianFrames ?? args.averageFrames ?? 1
            let useMedian = args.medianFrames != nil
            guard let image = captureMerged(camera: camera, frameCount: frameCount, useMedian: useMedian) else {
                Output.error("Error: Failed to capture photo.")
                camera.stopSession()
                return 1
            }
            
            let imageToSave = processSnapshot(image, contrast: args.enableContrast, denoise: args.enableDenoise, sharpen: args.enableSharpen)
            if camera.saveImage(imageToSave, to: outputPath) {
                Output.log(outputPath)
            } else {
                Output.error("Error: Failed to save image to \(outputPath)")
                camera.stopSession()
                return 1
            }
            
            sequenceNumber += 1
            
            // Check again if we've reached the limit before sleeping
            if let maxCaptures = args.maxCaptures, captureCount >= maxCaptures {
                break
            }
            
            // Wait for next capture
            Thread.sleep(forTimeInterval: interval)
        }
    } else {
        // Single capture mode
        let frameCount = args.medianFrames ?? args.averageFrames ?? 1
        let useMedian = args.medianFrames != nil
        guard let image = captureMerged(camera: camera, frameCount: frameCount, useMedian: useMedian) else {
            Output.error("Error: Failed to capture photo.")
            camera.stopSession()
            return 1
        }
        
        let imageToSave = processSnapshot(image, contrast: args.enableContrast, denoise: args.enableDenoise, sharpen: args.enableSharpen)
        if camera.saveImage(imageToSave, to: args.filename) {
            Output.log(args.filename)
        } else {
            Output.error("Error: Failed to save image to \(args.filename)")
            camera.stopSession()
            return 1
        }
    }
    
    camera.stopSession()
    
    return 0
}

// Run the program
exit(main())
