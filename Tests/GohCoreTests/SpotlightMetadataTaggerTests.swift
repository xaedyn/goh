import Darwin
import Foundation
import Testing

import GohCore

@Suite("Spotlight metadata tagger")
struct SpotlightMetadataTaggerTests {

    @Test("completed downloads receive where-from and downloaded-date metadata")
    func completedDownloadReceivesSpotlightMetadata() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "goh-spotlight-\(UUID().uuidString)")
        try Data("download".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let downloadedAt = Date(timeIntervalSinceReferenceDate: 42)
        try SpotlightMetadataTagger().tagCompletedDownload(
            destination: fileURL.path,
            sourceURL: "https://example.com/file.zip",
            downloadedAt: downloadedAt)

        let whereFroms = try xattrPropertyList(
            path: fileURL.path,
            name: "com.apple.metadata:kMDItemWhereFroms") as? [String]
        let downloadedDate = try xattrPropertyList(
            path: fileURL.path,
            name: "com.apple.metadata:kMDItemDownloadedDate") as? Date

        #expect(whereFroms == ["https://example.com/file.zip"])
        #expect(downloadedDate == downloadedAt)
    }

    @Test("missing destination reports the failed metadata attribute")
    func missingDestinationReportsFailedAttribute() {
        #expect(throws: SpotlightMetadataTaggerError.self) {
            try SpotlightMetadataTagger().tagCompletedDownload(
                destination: "/tmp/goh-missing-\(UUID().uuidString)",
                sourceURL: "https://example.com/file.zip",
                downloadedAt: Date(timeIntervalSinceReferenceDate: 42))
        }
    }

    private func xattrPropertyList(path: String, name: String) throws -> Any {
        let length = getxattr(path, name, nil, 0, 0, 0)
        #expect(length > 0)
        var bytes = [UInt8](repeating: 0, count: length)
        let read = getxattr(path, name, &bytes, bytes.count, 0, 0)
        #expect(read == length)
        return try PropertyListSerialization.propertyList(
            from: Data(bytes),
            options: [],
            format: nil)
    }
}
