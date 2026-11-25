import Flutter
import UIKit
import ImageIO

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let photos = FlutterMethodChannel(
      name: "dev.soramaru/photos",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    photos.setMethodCallHandler { call, result in
      guard call.method == "convertHeic" else { result(FlutterMethodNotImplemented); return }
      guard let input = call.arguments as? FlutterStandardTypedData,
        (16...20_971_520).contains(input.data.count) else {
        result(FlutterError(code: "photo_decode", message: "Invalid HEIF", details: nil))
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        let output = Self.convertHeif(input.data)
        DispatchQueue.main.async {
          if let output { result(FlutterStandardTypedData(bytes: output)) }
          else { result(FlutterError(code: "photo_decode", message: "HEIF conversion failed", details: nil)) }
        }
      }
    }
    let drafts = FlutterMethodChannel(
      name: "dev.soramaru/drafts",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    drafts.setMethodCallHandler { call, result in
      guard call.method == "excludeFromBackup" else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        let support = try FileManager.default.url(
          for: .applicationSupportDirectory, in: .userDomainMask,
          appropriateFor: nil, create: true
        )
        var directory = support.appendingPathComponent("soramaru-drafts", isDirectory: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        result(nil)
      } catch {
        result(FlutterError(code: "draft_storage", message: "Backup exclusion failed", details: nil))
      }
    }
  }

  private static func convertHeif(_ input: Data) -> Data? {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(input as CFData, options),
      CGImageSourceGetCount(source) == 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      (1...16384).contains(width), (1...16384).contains(height), width * height <= 64_000_000,
      let raster = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: min(2048, max(width, height)),
        kCGImageSourceShouldCacheImmediately: true
      ] as CFDictionary) else { return nil }
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: raster.width, height: raster.height,
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else { return nil }
    context.draw(raster, in: CGRect(x: 0, y: 0, width: CGFloat(raster.width), height: CGFloat(raster.height)))
    guard let srgb = context.makeImage() else { return nil }
    let bytes = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil)
      else { return nil }
    CGImageDestinationAddImage(destination, srgb, [kCGImageDestinationLossyCompressionQuality: 0.96] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? bytes as Data : nil
  }
}
