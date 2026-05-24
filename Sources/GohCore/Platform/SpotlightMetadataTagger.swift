import CoreServices
import Darwin
import Foundation

public enum SpotlightMetadataTaggerError: Error, Equatable {
    case propertyListEncodingFailed(attribute: String)
    case setAttributeFailed(attribute: String, errnoCode: Int32)
}

public struct SpotlightMetadataTagger: Sendable {
    private static let metadataAttributePrefix = "com.apple.metadata:"

    public static let whereFromsAttributeName =
        metadataAttributePrefix + (kMDItemWhereFroms as String)
    public static let downloadedDateAttributeName =
        metadataAttributePrefix + (kMDItemDownloadedDate as String)

    public init() {}

    public func tagCompletedDownload(
        destination: String,
        sourceURL: String,
        downloadedAt: Date = Date()
    ) throws {
        try setMetadata(
            [sourceURL],
            attribute: Self.whereFromsAttributeName,
            path: destination)
        try setMetadata(
            downloadedAt,
            attribute: Self.downloadedDateAttributeName,
            path: destination)
    }

    private func setMetadata(
        _ value: Any,
        attribute: String,
        path: String
    ) throws {
        let data: Data
        do {
            data = try PropertyListSerialization.data(
                fromPropertyList: value,
                format: .binary,
                options: 0)
        } catch {
            throw SpotlightMetadataTaggerError.propertyListEncodingFailed(attribute: attribute)
        }

        let result = data.withUnsafeBytes { rawBuffer in
            setxattr(path, attribute, rawBuffer.baseAddress, rawBuffer.count, 0, 0)
        }
        guard result == 0 else {
            throw SpotlightMetadataTaggerError.setAttributeFailed(
                attribute: attribute,
                errnoCode: errno)
        }
    }
}
