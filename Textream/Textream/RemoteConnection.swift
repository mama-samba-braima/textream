//
//  RemoteConnection.swift
//  Textream
//

import AppKit
import CoreImage.CIFilterBuiltins

/// The address a phone or tablet scans to drive the prompter, and the QR code for it.
///
/// Shared so Settings and the play-mode panel cannot drift into showing different URLs.
enum RemoteConnection {

    /// The URL to open on another device, or nil when the remote server is not running.
    static var url: String? {
        let settings = NotchSettings.shared
        guard settings.browserServerEnabled else { return nil }
        let host = BrowserServer.localIPAddress() ?? "localhost"
        return "http://\(host):\(settings.browserServerPort)"
    }

    static func qrCode(for string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let ciImage = filter.outputImage else { return nil }
        let scale = 10.0
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
