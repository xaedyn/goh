import Foundation

/// Injectable seam for choosing a folder. The live impl (NSOpenPanelFolderPicker)
/// lives in goh-menu so GohMenuBar stays AppKit-panel-free and unit-testable.
public protocol FolderPicker: Sendable {
    /// Presents a directory chooser. Returns the chosen folder path, or nil if cancelled.
    @MainActor func chooseFolder() async -> String?
}
