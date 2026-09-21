import AppKit
import ImageIO
import UniformTypeIdentifiers

@main struct RemoteImagePasteChecks {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kero-image-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let width = 64, height = 48
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            pixels[offset] = UInt8(x * 4)
            pixels[offset + 1] = UInt8(y * 5)
            pixels[offset + 2] = 128
        } }
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        let fixture = NSMutableData()
        let encoder = CGImageDestinationCreateWithData(fixture, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(encoder, image, nil)
        precondition(CGImageDestinationFinalize(encoder))
        let board = NSPasteboard(name: .init("kero-image-check-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setData(fixture as Data, forType: .png)
        let encoded = try RemoteImagePaste.png(RemoteImagePaste.capture(board)!)
        let source = CGImageSourceCreateWithData(encoded as CFData, nil)!
        let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        precondition(decoded.width == width && decoded.height == height)
        let path = directory.appendingPathComponent("image with spaces.png")
        try encoded.write(to: path)
        board.clearContents(); board.setString(path.absoluteString, forType: .fileURL)
        precondition(RemoteImagePaste.capture(board) != nil)
        _ = try RemoteImagePaste.png(RemoteImagePaste.capture(board)!)
        board.clearContents(); board.setString("ordinary text", forType: .string)
        precondition(RemoteImagePaste.capture(board) == nil)
        do { _ = try RemoteImagePaste.png(.data(Data("invalid".utf8))); fatalError("invalid image accepted") } catch {}
        do { _ = try RemoteImagePaste.png(.data(Data(count: 32 * 1024 * 1024 + 1))); fatalError("oversized image accepted") } catch {}
        // A deterministic, non-sensitive image for the real Preview -> terminal test.
        try encoded.write(to: URL(fileURLWithPath: "/tmp/kero-clipboard-fixture.png"))
        print("PASS: private pasteboard image/file capture, PNG dimensions, ordinary text, invalid and oversized input")
    }
}
