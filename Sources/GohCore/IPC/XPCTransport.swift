import Foundation
import Synchronization
import XPC

extension GohXPCService {
    /// The XPC peer requirement to enforce for `mode`, or `nil` when peer
    /// validation is relaxed for development.
    ///
    /// The designated signing identifier is pinned once code signing is
    /// configured (see `DESIGN.md` §3.1); same-team membership is the floor.
    public static func peerRequirement(for mode: PeerValidationMode) -> XPCPeerRequirement? {
        switch mode {
        case .enforced:
            return .isFromSameTeam()
        case .relaxedForDevelopment:
            return nil
        }
    }
}

/// The daemon side of an accepted XPC session.
public struct GohXPCServerSession: Sendable {
    private let sendMessage: @Sendable (XPCDictionary) throws -> Void
    private let registerCancellationHandler: @Sendable (
        @escaping @Sendable () -> Void
    ) -> Void

    fileprivate init(
        session: XPCSession,
        cancellationHandlers: GohXPCSessionCancellationHandlers
    ) {
        self.sendMessage = { message in
            try session.send(message: message)
        }
        self.registerCancellationHandler = { handler in
            cancellationHandlers.register(handler)
        }
    }

    /// Creates a server-session wrapper over a custom send function. This keeps
    /// subscription notification encoding testable without depending on
    /// anonymous-listener push delivery on every CI runner.
    init(
        send: @escaping @Sendable (XPCDictionary) throws -> Void,
        registerCancellationHandler: @escaping @Sendable (
            @escaping @Sendable () -> Void
        ) -> Void = { _ in }
    ) {
        self.sendMessage = send
        self.registerCancellationHandler = registerCancellationHandler
    }

    /// Sends a daemon-initiated message to the connected client.
    public func send(_ message: XPCDictionary) throws {
        try sendMessage(message)
    }

    /// Registers work to run when the accepted XPC session is cancelled.
    public func onCancel(_ handler: @escaping @Sendable () -> Void) {
        registerCancellationHandler(handler)
    }
}

private final class GohXPCSessionCancellationHandlers: Sendable {
    private struct State: Sendable {
        var callbacks: [UUID: @Sendable () -> Void] = [:]
        var cancelled = false
    }

    private let state = Mutex(State())

    func register(_ handler: @escaping @Sendable () -> Void) {
        let callImmediately = state.withLock { state in
            guard !state.cancelled else { return true }
            state.callbacks[UUID()] = handler
            return false
        }
        if callImmediately {
            handler()
        }
    }

    func cancelAll() {
        let callbacks = state.withLock { state in
            guard !state.cancelled else {
                let callbacks: [(@Sendable () -> Void)] = []
                return callbacks
            }
            state.cancelled = true
            let callbacks = Array(state.callbacks.values)
            state.callbacks.removeAll()
            return callbacks
        }
        for callback in callbacks {
            callback()
        }
    }
}

private final class GohXPCServerSessionBox: Sendable {
    private let session = Mutex<GohXPCServerSession?>(nil)

    func set(_ value: GohXPCServerSession) {
        session.withLock { $0 = value }
    }

    func handle(
        _ handler: @Sendable (GohXPCServerSession, XPCDictionary) -> XPCDictionary?,
        message: XPCDictionary
    ) -> XPCDictionary? {
        guard let current = session.withLock({ $0 }) else { return nil }
        return handler(current, message)
    }
}

/// A validated XPC listener.
///
/// An XPC listener is active as soon as it is created — there is no separate
/// `activate()` step, and calling `activate()` traps with `_xpc_api_misuse`. In
/// production `gohd` binds its Mach service with an
/// OS-enforced peer requirement (`init(machServiceName:mode:handler:)`); the
/// anonymous initializer is for in-process integration testing, where the
/// listener carries no peer requirement (see `DESIGN.md` §3).
public final class GohXPCListener {
    private let listener: XPCListener

    private static func sessionHandler(
        _ handler: @escaping @Sendable (XPCDictionary) -> XPCDictionary?
    ) -> @Sendable (XPCListener.IncomingSessionRequest) -> XPCListener.IncomingSessionRequest.Decision {
        { request in request.accept(incomingMessageHandler: handler) }
    }

    private static func sessionAwareHandler(
        _ handler: @escaping @Sendable (GohXPCServerSession, XPCDictionary) -> XPCDictionary?
    ) -> @Sendable (XPCListener.IncomingSessionRequest) -> XPCListener.IncomingSessionRequest.Decision {
        { request in
            let cancellationHandlers = GohXPCSessionCancellationHandlers()
            let sessionBox = GohXPCServerSessionBox()
            let (decision, session) = request.accept(
                incomingMessageHandler: { message in
                    sessionBox.handle(handler, message: message)
                },
                cancellationHandler: { _ in
                    cancellationHandlers.cancelAll()
                })
            sessionBox.set(GohXPCServerSession(
                session: session,
                cancellationHandlers: cancellationHandlers))
            return decision
        }
    }

    /// A Mach-service listener for the daemon. `.enforced` binds the service
    /// with an OS-enforced peer requirement, validated at session-accept;
    /// `.relaxedForDevelopment` binds it without a requirement.
    public init(
        machServiceName: String,
        mode: PeerValidationMode,
        handler: @escaping @Sendable (XPCDictionary) -> XPCDictionary?
    ) throws {
        // `XPCListener` is active on return — never call `activate()` (it traps).
        if let requirement = GohXPCService.peerRequirement(for: mode) {
            listener = try XPCListener(
                service: machServiceName, requirement: requirement,
                incomingSessionHandler: Self.sessionHandler(handler))
        } else {
            listener = try XPCListener(
                service: machServiceName,
                incomingSessionHandler: Self.sessionHandler(handler))
        }
    }

    /// A Mach-service listener whose handler can send server-initiated messages
    /// over the accepted session.
    public init(
        machServiceName: String,
        mode: PeerValidationMode,
        sessionHandler handler: @escaping @Sendable (
            GohXPCServerSession, XPCDictionary
        ) -> XPCDictionary?
    ) throws {
        // `XPCListener` is active on return — never call `activate()` (it traps).
        if let requirement = GohXPCService.peerRequirement(for: mode) {
            listener = try XPCListener(
                service: machServiceName, requirement: requirement,
                incomingSessionHandler: Self.sessionAwareHandler(handler))
        } else {
            listener = try XPCListener(
                service: machServiceName,
                incomingSessionHandler: Self.sessionAwareHandler(handler))
        }
    }

    /// An anonymous listener for in-process integration testing. Carries no peer
    /// requirement; a client connects to it through `endpoint`.
    public init(
        anonymousHandler handler: @escaping @Sendable (XPCDictionary) -> XPCDictionary?
    ) {
        listener = XPCListener(incomingSessionHandler: Self.sessionHandler(handler))
    }

    /// An anonymous listener whose handler can send server-initiated messages
    /// over the accepted session.
    public init(
        anonymousSessionHandler handler: @escaping @Sendable (
            GohXPCServerSession, XPCDictionary
        ) -> XPCDictionary?
    ) {
        listener = XPCListener(incomingSessionHandler: Self.sessionAwareHandler(handler))
    }

    /// The endpoint a client connects to. Meaningful for anonymous listeners.
    public var endpoint: XPCEndpoint { listener.endpoint }

    /// Stops the listener.
    public func cancel() { listener.cancel() }
}

/// A validated XPC session from a client to a `gohd` listener.
///
/// An XPC session is active as soon as it is created — there is no `activate()`
/// step, and calling `activate()` traps with `_xpc_api_misuse`. The peer
/// requirement is supplied at construction so the daemon is validated before any
/// message is exchanged (see `DESIGN.md` §3.2).
public final class GohXPCClient {
    private let session: XPCSession

    /// Connects to the daemon's Mach service, validating the daemon per `mode`.
    public init(machServiceName: String, mode: PeerValidationMode) throws {
        // `XPCSession` is active on return — never call `activate()` (it traps).
        if let requirement = GohXPCService.peerRequirement(for: mode) {
            session = try XPCSession(machService: machServiceName, requirement: requirement)
        } else {
            session = try XPCSession(machService: machServiceName)
        }
    }

    /// Connects to the daemon's Mach service with a handler for daemon-initiated
    /// messages.
    public init(
        machServiceName: String,
        mode: PeerValidationMode,
        incomingMessageHandler: (@Sendable (XPCDictionary) -> XPCDictionary?)?,
        cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
    ) throws {
        // `XPCSession` is active on return — never call `activate()` (it traps).
        if let requirement = GohXPCService.peerRequirement(for: mode) {
            session = try XPCSession(
                machService: machServiceName,
                requirement: requirement,
                incomingMessageHandler: incomingMessageHandler,
                cancellationHandler: cancellationHandler)
        } else {
            session = try XPCSession(
                machService: machServiceName,
                incomingMessageHandler: incomingMessageHandler,
                cancellationHandler: cancellationHandler)
        }
    }

    /// Connects to an anonymous listener's `endpoint` — for in-process
    /// integration testing.
    public init(endpoint: XPCEndpoint) throws {
        session = try XPCSession(endpoint: endpoint)
    }

    /// Connects to an anonymous listener's `endpoint` with a handler for
    /// daemon-initiated messages.
    public init(
        endpoint: XPCEndpoint,
        incomingMessageHandler: (@Sendable (XPCDictionary) -> XPCDictionary?)?,
        cancellationHandler: (@Sendable (XPCRichError) -> Void)? = nil
    ) throws {
        session = try XPCSession(
            endpoint: endpoint,
            incomingMessageHandler: incomingMessageHandler,
            cancellationHandler: cancellationHandler)
    }

    /// Sends `message` and returns the daemon's reply dictionary.
    public func sendSync(_ message: XPCDictionary) throws -> XPCDictionary {
        try session.sendSync(message: message)
    }

    /// Closes the session.
    public func cancel() { session.cancel(reason: "client finished") }
}
