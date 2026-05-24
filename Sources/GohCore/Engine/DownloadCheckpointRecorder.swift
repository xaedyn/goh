import Foundation
import Synchronization

/// Serializes hot engine checkpoint updates for one job.
final class DownloadCheckpointRecorder: Sendable {
    private let store: CheckpointStore
    private let checkpoint: Mutex<DownloadCheckpoint>

    init(store: CheckpointStore, checkpoint: DownloadCheckpoint) {
        self.store = store
        self.checkpoint = Mutex(checkpoint)
    }

    func recordCompletedPiece(start: UInt64, length: UInt64) throws {
        let snapshot = checkpoint.withLock { checkpoint in
            checkpoint.recordCompletedPiece(start: start, length: length)
            let end = start.addingReportingOverflow(length)
            if !end.overflow {
                checkpoint.partialFileSize = max(checkpoint.partialFileSize, end.partialValue)
            }
            return checkpoint
        }
        try store.save(snapshot)
    }
}
