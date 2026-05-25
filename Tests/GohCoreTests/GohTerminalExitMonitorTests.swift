import Darwin
import Dispatch
import Testing

import GohCore

@Suite("terminal exit monitor")
struct GohTerminalExitMonitorTests {

    @Test("exit bytes cover top-style quit keys")
    func exitBytesCoverTopStyleQuitKeys() {
        #expect(GohTerminalExitMonitor.isExitByte(UInt8(ascii: "q")))
        #expect(GohTerminalExitMonitor.isExitByte(UInt8(ascii: "Q")))
        #expect(GohTerminalExitMonitor.isExitByte(0x1B))
        #expect(GohTerminalExitMonitor.isExitByte(0x04))
        #expect(!GohTerminalExitMonitor.isExitByte(UInt8(ascii: "x")))
    }

    @Test("monitor invokes handler when a quit key arrives")
    func monitorInvokesHandlerWhenQuitKeyArrives() {
        var fileDescriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&fileDescriptors) == 0 else {
            Issue.record("pipe failed")
            return
        }
        defer {
            close(fileDescriptors[0])
            close(fileDescriptors[1])
        }

        let probe = ExitProbe()
        let monitor = GohTerminalExitMonitor(fileDescriptor: fileDescriptors[0]) {
            probe.signal()
        }
        monitor.start()
        defer { monitor.cancel() }

        var quitByte = UInt8(ascii: "q")
        let written = withUnsafeBytes(of: &quitByte) { bytes in
            Darwin.write(fileDescriptors[1], bytes.baseAddress, bytes.count)
        }

        #expect(written == 1)
        #expect(probe.wait() == .success)
    }
}

private final class ExitProbe: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func signal() {
        semaphore.signal()
    }

    func wait() -> DispatchTimeoutResult {
        semaphore.wait(timeout: .now() + .seconds(1))
    }
}
