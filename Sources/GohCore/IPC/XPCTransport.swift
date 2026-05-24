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
    private let session: XPCSession

    init(session: XPCSession) {
        self.session = session
    }

    /// Sends a daemon-initiated message to the connected client.
    public func send(_ message: XPCDictionary) throws {
        try session.send(message: message)
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

    private struct SessionAwareHandler: XPCPeerHandler {
        let session: GohXPCServerSession
        let handler: @Sendable (GohXPCServerSession, XPCDictionary) -> XPCDictionary?

        func handleIncomingRequest(_ request: XPCDictionary) -> XPCDictionary? {
            handler(session, request)
        }
    }

    private static func sessionHandler(
        _ handler: @escaping @Sendable (XPCDictionary) -> XPCDictionary?
    ) -> @Sendable (XPCListener.IncomingSessionRequest) -> XPCListener.IncomingSessionRequest.Decision {
        { request in request.accept(incomingMessageHandler: handler) }
    }

    private static func sessionAwareHandler(
        _ handler: @escaping @Sendable (GohXPCServerSession, XPCDictionary) -> XPCDictionary?
    ) -> @Sendable (XPCListener.IncomingSessionRequest) -> XPCListener.IncomingSessionRequest.Decision {
        { request in
            request.accept { session in
                SessionAwareHandler(
                    session: GohXPCServerSession(session: session),
                    handler: handler)
            }
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
        incomingMessageHandler: (@Sendable (XPCDictionary) -> XPCDictionary?)?
    ) throws {
        // `XPCSession` is active on return — never call `activate()` (it traps).
        if let requirement = GohXPCService.peerRequirement(for: mode) {
            session = try XPCSession(
                machService: machServiceName,
                requirement: requirement,
                incomingMessageHandler: incomingMessageHandler)
        } else {
            session = try XPCSession(
                machService: machServiceName,
                incomingMessageHandler: incomingMessageHandler)
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
        incomingMessageHandler: (@Sendable (XPCDictionary) -> XPCDictionary?)?
    ) throws {
        session = try XPCSession(
            endpoint: endpoint,
            incomingMessageHandler: incomingMessageHandler)
    }

    /// Sends `message` and returns the daemon's reply dictionary.
    public func sendSync(_ message: XPCDictionary) throws -> XPCDictionary {
        try session.sendSync(message: message)
    }

    /// Closes the session.
    public func cancel() { session.cancel(reason: "client finished") }
}
