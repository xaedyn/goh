import Dispatch
import Foundation
import Synchronization
import XPC

public struct GohForegroundDownloadSession {
    public var sendSync: (XPCDictionary) throws -> XPCDictionary
    public var receiveNotification: () throws -> GohEnvelope<ProgressEvent>
    public var cancel: () -> Void

    public init(
        sendSync: @escaping (XPCDictionary) throws -> XPCDictionary,
        receiveNotification: @escaping () throws -> GohEnvelope<ProgressEvent>,
        cancel: @escaping () -> Void
    ) {
        self.sendSync = sendSync
        self.receiveNotification = receiveNotification
        self.cancel = cancel
    }
}

public enum GohXPCNotificationInboxError: Error, Sendable, Equatable {
    case malformedProgressNotification(String)
}

public final class GohXPCNotificationInbox: @unchecked Sendable {
    private typealias Message = Result<
        GohEnvelope<ProgressEvent>, GohXPCNotificationInboxError
    >

    private let messages = Mutex<[Message]>([])
    private let semaphore = DispatchSemaphore(value: 0)

    public init() {}

    public func handle(_ message: XPCDictionary) -> XPCDictionary? {
        let decoded: Message
        do {
            let envelope = try message.withUnsafeUnderlyingDictionary { object in
                try GohEnvelope<ProgressEvent>(xpcDictionary: object)
            }
            decoded = .success(envelope)
        } catch {
            decoded = .failure(.malformedProgressNotification("\(error)"))
        }
        messages.withLock { $0.append(decoded) }
        semaphore.signal()
        return nil
    }

    public func receive() throws -> GohEnvelope<ProgressEvent> {
        semaphore.wait()
        return try messages.withLock { $0.removeFirst() }.get()
    }
}

public struct GohForegroundDownload {
    public var request: AddRequest
    public var session: GohForegroundDownloadSession

    public init(request: AddRequest, session: GohForegroundDownloadSession) {
        self.request = request
        self.session = session
    }

    public func run() -> GohCommandLineResult {
        do {
            defer { session.cancel() }

            let (_, job): (UUID, JobSummary) = try sendCommand(
                .add(request: request),
                expecting: JobSummary.self)
            let (subscribeRequestID, baseline): (UUID, SubscribeReply) = try sendCommand(
                .subscribe(request: SubscribeRequest(scope: .job, jobID: job.id)),
                expecting: SubscribeReply.self)

            var output = Self.addedMessage(job)
            output += baseline.snapshot.map(Self.progressLine).joined()
            if let terminal = terminalResult(in: baseline.snapshot, jobID: job.id) {
                return GohCommandLineResult(exitCode: terminal, standardOutput: output)
            }

            while true {
                let notification = try session.receiveNotification()
                let event = try decodeNotification(
                    notification,
                    requestID: subscribeRequestID)
                output += event.snapshot.map(Self.progressLine).joined()
                if let terminal = terminalResult(in: event.snapshot, jobID: job.id) {
                    return GohCommandLineResult(exitCode: terminal, standardOutput: output)
                }
            }
        } catch let error as GohError {
            return GohCommandLineResult(
                exitCode: 1,
                standardError: Self.daemonErrorMessage(error))
        } catch let error as ForegroundError {
            return GohCommandLineResult(
                exitCode: 1,
                standardError: "gohd returned an invalid reply: \(error.message)\n")
        } catch {
            return GohCommandLineResult(
                exitCode: 1,
                standardError: "Could not reach gohd.\nStart the daemon with: brew services start goh\n\n\(error)\n")
        }
    }

    private func sendCommand<Reply: Codable & Sendable>(
        _ command: Command,
        expecting _: Reply.Type
    ) throws -> (UUID, Reply) {
        let requestID = UUID()
        let request = try GohEnvelope(
            protocolVersion: CommandService.protocolVersion,
            requestID: requestID,
            messageType: .request,
            payload: command)
            .xpcDictionary()
        let response = try session.sendSync(XPCDictionary(request))

        return try response.withUnsafeUnderlyingDictionary { object in
            if let reply = try? GohEnvelope<Reply>(xpcDictionary: object),
               reply.messageType == .reply
            {
                guard reply.requestID == requestID else {
                    throw ForegroundError(
                        "daemon reply requestID did not match the request")
                }
                return (requestID, reply.payload)
            }

            if let error = try? GohEnvelope<GohError>(xpcDictionary: object),
               error.messageType == .error
            {
                guard error.requestID == requestID else {
                    throw ForegroundError(
                        "daemon error requestID did not match the request")
                }
                throw error.payload
            }

            throw ForegroundError("daemon returned an unrecognized reply")
        }
    }

    private func decodeNotification(
        _ notification: GohEnvelope<ProgressEvent>,
        requestID: UUID
    ) throws -> ProgressEvent {
        guard notification.messageType == .notification else {
            throw ForegroundError("daemon sent a non-notification progress message")
        }
        guard notification.requestID == requestID else {
            throw ForegroundError(
                "daemon notification requestID did not match the subscription")
        }
        return notification.payload
    }

    private func terminalResult(in snapshots: [ProgressSnapshot], jobID: UInt64) -> Int32? {
        guard let snapshot = snapshots.first(where: { $0.job.id == jobID }) else { return 1 }
        switch snapshot.job.state {
        case .completed:
            return 0
        case .failed:
            return 1
        case .queued, .active, .paused:
            return nil
        }
    }

    private struct ForegroundError: Error, Equatable {
        var message: String

        init(_ message: String) {
            self.message = message
        }
    }
}

private extension GohForegroundDownload {
    static func addedMessage(_ summary: JobSummary) -> String {
        "Added job \(summary.id) (\(summary.state.rawValue)): \(summary.url) -> \(summary.destination)\n"
    }

    static func progressLine(_ snapshot: ProgressSnapshot) -> String {
        let job = snapshot.job
        return "Job \(job.id) \(job.state.rawValue): \(progressText(job.progress)) at \(formatBytes(job.progress.bytesPerSecond))/s\n"
    }

    static func progressText(_ progress: JobProgress) -> String {
        guard let total = progress.bytesTotal else {
            return "\(formatBytes(progress.bytesCompleted))/?"
        }
        let percent = total == 0
            ? 100
            : Int((Double(progress.bytesCompleted) / Double(total) * 100).rounded())
        return "\(formatBytes(progress.bytesCompleted))/\(formatBytes(total)) (\(percent)%)"
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        guard bytes >= 1024 else {
            return "\(bytes) B"
        }

        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        let rounded = value.rounded()
        if abs(value - rounded) < 0.05 {
            return "\(Int(rounded)) \(units[unitIndex])"
        }
        return String(
            format: "%.1f %@",
            locale: Locale(identifier: "en_US_POSIX"),
            value,
            units[unitIndex])
    }

    static func daemonErrorMessage(_ error: GohError) -> String {
        if let message = error.message, !message.isEmpty {
            return "gohd: \(message)\n"
        }
        return "gohd: \(error.code.rawValue)\n"
    }
}
