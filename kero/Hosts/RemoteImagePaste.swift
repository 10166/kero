import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Captures only the user's explicit paste. Image decoding and host I/O happen
/// off the main thread; no terminal output is allowed to read the pasteboard.
enum RemoteImagePaste {
    @MainActor private static var inFlight = false
    @MainActor static func begin() -> Bool {
        guard !inFlight else { return false }
        inFlight = true
        return true
    }
    @MainActor static func finish() { inFlight = false }
    nonisolated enum Source: Sendable { case data(Data), file(URL) }

    @MainActor static func capture(_ pasteboard: NSPasteboard) -> Source? {
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            return .data(data)
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], urls.count == 1,
            let url = urls.first, url.isFileURL,
            UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        {
            return .file(url)
        }
        return nil
    }

    nonisolated static func png(_ source: Source) throws -> Data {
        let data: Data
        switch source {
        case .data(let bytes): data = bytes
        case .file(let url):
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 32 * 1024 * 1024 else { throw DaemonWire.Failure("Clipboard image is too large") }
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        }
        guard data.count <= 32 * 1024 * 1024,
            let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, width <= 40_000_000 / height,
            let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else { throw DaemonWire.Failure("Cannot read clipboard image (maximum 40 megapixels)") }
        let result = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                result, UTType.png.identifier as CFString, 1, nil)
        else { throw DaemonWire.Failure("Cannot encode clipboard image") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), result.length <= 4 * 1024 * 1024
        else { throw DaemonWire.Failure("Remote image paste supports PNG images up to 4 MiB") }
        return result as Data
    }
}
