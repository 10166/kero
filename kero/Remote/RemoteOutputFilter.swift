import Foundation

/// The filter retains partial escape sequences between frames. Remote image
/// paths must never be resolved against the controller's filesystem.
nonisolated final class RemoteOutputFilter {
    private let handle = kero_remote_output_filter_new()

    deinit { kero_remote_output_filter_free(handle) }

    func receive(_ data: Data) -> Data {
        data.withUnsafeBytes { bytes in
            var count = 0
            guard let output = kero_remote_output_filter_feed(
                handle, bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count, &count
            ), count > 0 else { return Data() }
            return Data(bytes: output, count: count)
        }
    }
}
