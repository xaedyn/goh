import Darwin
import Dispatch
import Foundation

public final class GohTerminalExitMonitor: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let queue: DispatchQueue
    private let onExit: @Sendable () -> Void
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var originalTermios: termios?

    public init(
        fileDescriptor: Int32 = STDIN_FILENO,
        queue: DispatchQueue = DispatchQueue.global(qos: .userInitiated),
        onExit: @escaping @Sendable () -> Void
    ) {
        self.fileDescriptor = fileDescriptor
        self.queue = queue
        self.onExit = onExit
    }

    deinit {
        cancel()
    }

    public static func isExitByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "q"), UInt8(ascii: "Q"), 0x1B, 0x04:
            return true
        default:
            return false
        }
    }

    public func start() {
        lock.lock()
        guard source == nil else {
            lock.unlock()
            return
        }

        originalTermios = enterImmediateInputMode()
        let readSource = DispatchSource.makeReadSource(
            fileDescriptor: fileDescriptor,
            queue: queue)
        source = readSource
        lock.unlock()

        readSource.setEventHandler { [weak self] in
            self?.readAvailableInput()
        }
        readSource.resume()
    }

    public func cancel() {
        lock.lock()
        let readSource = source
        source = nil
        let termiosToRestore = originalTermios
        originalTermios = nil
        lock.unlock()

        readSource?.cancel()
        restoreTerminalMode(termiosToRestore)
    }

    private func enterImmediateInputMode() -> termios? {
        guard isatty(fileDescriptor) == 1 else { return nil }

        var original = termios()
        guard tcgetattr(fileDescriptor, &original) == 0 else { return nil }

        var immediate = original
        immediate.c_lflag &= ~tcflag_t(ICANON | ECHO)
        guard tcsetattr(fileDescriptor, TCSANOW, &immediate) == 0 else {
            return nil
        }
        return original
    }

    private func restoreTerminalMode(_ mode: termios?) {
        guard var mode else { return }
        _ = tcsetattr(fileDescriptor, TCSANOW, &mode)
    }

    private func readAvailableInput() {
        let byteCount = max(1, min(availableByteCount(), 4_096))
        var buffer = [UInt8](repeating: 0, count: byteCount)
        let count = Darwin.read(fileDescriptor, &buffer, buffer.count)

        guard count > 0 else { return }
        if buffer.prefix(count).contains(where: Self.isExitByte) {
            onExit()
        }
    }

    private func availableByteCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let source else { return 1 }
        return Int(source.data)
    }
}
