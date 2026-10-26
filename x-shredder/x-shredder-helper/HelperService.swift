import Foundation

/// One instance per XPC connection. Every request is passed to the shared
/// coordinator, which does its own validation.
final class HelperService: NSObject, EraseHelperProtocol {
    private let coordinator: EraseCoordinator

    init(coordinator: EraseCoordinator) {
        self.coordinator = coordinator
    }

    func status(reply: @escaping (Data) -> Void) {
        reply(Wire.encode(coordinator.status()))
    }

    func listEligibleDisks(reply: @escaping (Data) -> Void) {
        reply(Wire.encode(coordinator.eligibleDisks()))
    }

    func startErase(bsdName: String, options: Data, reply: @escaping (String?) -> Void) {
        reply(coordinator.start(bsdName: bsdName, optionsData: options))
    }

    func cancel(reply: @escaping () -> Void) {
        coordinator.cancel()
        reply()
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let coordinator: EraseCoordinator

    init(coordinator: EraseCoordinator) {
        self.coordinator = coordinator
    }

    /// The listener's code-signing requirement has already been applied to
    /// this connection: messages from a peer that does not satisfy it are
    /// never delivered.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: EraseHelperProtocol.self)
        connection.exportedObject = HelperService(coordinator: coordinator)
        connection.remoteObjectInterface = NSXPCInterface(with: EraseClientProtocol.self)

        let coordinator = coordinator
        connection.invalidationHandler = { [weak connection] in
            if let connection { coordinator.remove(connection) }
        }
        coordinator.add(connection)
        connection.resume()
        return true
    }
}
