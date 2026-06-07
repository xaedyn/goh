import Combine
import Foundation
import GohCore

@MainActor
public final class AddDownloadViewModel: ObservableObject {
    @Published public var urlText: String
    @Published public var chosenFolder: String?
    @Published public var automaticConnections: Bool
    @Published public var connectionCount: Int
    @Published public private(set) var errorText: String?

    private let client: any GohMenuClient
    private let folderPicker: any FolderPicker
    private let detector: GohClipboardURLDetector

    public var canAdd: Bool {
        detector.url(from: urlText) != nil
    }

    public init(
        initialURL: String?,
        client: any GohMenuClient,
        folderPicker: any FolderPicker,
        detector: GohClipboardURLDetector = GohClipboardURLDetector()
    ) {
        self.urlText = initialURL ?? ""
        self.chosenFolder = nil
        self.automaticConnections = true
        self.connectionCount = 8
        self.client = client
        self.folderPicker = folderPicker
        self.detector = detector
    }

    public func chooseFolder() async {
        if let path = await folderPicker.chooseFolder() {
            chosenFolder = path
        }
        // Cancelled pick: chosenFolder is unchanged (spec §6, §7.2)
    }

    public func useDefaultFolder() {
        chosenFolder = nil
    }

    /// Builds and submits AddRequest. Returns true on success (caller should close window).
    /// Returns false on validation failure (no-op) or on error (errorText set, window stays open).
    @discardableResult
    public func submit() async -> Bool {
        guard let url = detector.url(from: urlText) else {
            // canAdd == false; no-op — spec §7.2
            return false
        }

        let request = AddRequest(
            url: url.absoluteString,
            destination: chosenFolder,
            connectionCount: automaticConnections
                ? nil
                : UInt8(min(16, max(1, connectionCount)))
        )

        do {
            _ = try await client.add(request)
            errorText = nil
            return true
        } catch {
            errorText = GohMenuErrorMapper.map(error).userFacingMessage
            return false
        }
    }
}
