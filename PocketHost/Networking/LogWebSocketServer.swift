import Foundation
import Network

final class LogWebSocketServer: @unchecked Sendable {
    private struct SubscribeMessage: Decodable {
        let token: String
        let projectID: String
    }

    private final class Client: @unchecked Sendable {
        let id = UUID()
        let connection: NWConnection
        var projectID: String?
        var subscriptionID: UUID?
        init(connection: NWConnection) { self.connection = connection }
    }

    private let queue = DispatchQueue(label: "PocketHost.LogWebSocket")
    private let lock = NSLock()
    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    private let logs: LogBroker
    private let apiKey: String
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    init(logs: LogBroker, apiKey: String) {
        self.logs = logs
        self.apiKey = apiKey
    }

    var isRunning: Bool { listener != nil }

    func start(port: UInt16 = 8081) throws {
        guard listener == nil else { return }
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw POSIXError(.EINVAL) }
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.stop() }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        let current = Array(clients.values)
        clients.removeAll()
        lock.unlock()
        for client in current {
            if let projectID = client.projectID, let subscriptionID = client.subscriptionID {
                logs.unsubscribe(projectID: projectID, id: subscriptionID)
            }
            client.connection.cancel()
        }
    }

    private func accept(_ connection: NWConnection) {
        let client = Client(connection: connection)
        lock.lock(); clients[client.id] = client; lock.unlock()
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .failed, .cancelled: self.cleanup(client)
            default: break
            }
        }
        connection.start(queue: queue)
        receiveSubscription(client)
    }

    private func receiveSubscription(_ client: Client) {
        client.connection.receiveMessage { [weak self, weak client] data, _, _, error in
            guard let self, let client else { return }
            if let error {
                self.sendText("{\"error\":\"\(self.escape(error.localizedDescription))\"}", client: client)
                self.cleanup(client)
                return
            }
            guard let data,
                  let message = try? JSONDecoder().decode(SubscribeMessage.self, from: data),
                  message.token == self.apiKey,
                  !message.projectID.isEmpty else {
                self.sendText("{\"error\":\"unauthorized\"}", client: client)
                client.connection.cancel()
                return
            }

            client.projectID = message.projectID
            for entry in self.logs.recent(projectID: message.projectID, limit: 200) {
                self.send(entry, client: client)
            }
            client.subscriptionID = self.logs.subscribe(projectID: message.projectID) { [weak self, weak client] entry in
                guard let self, let client else { return }
                self.send(entry, client: client)
            }
            self.sendText("{\"type\":\"subscribed\",\"projectID\":\"\(self.escape(message.projectID))\"}", client: client)
            self.receiveControl(client)
        }
    }

    private func receiveControl(_ client: Client) {
        client.connection.receiveMessage { [weak self, weak client] data, context, _, error in
            guard let self, let client else { return }
            if error != nil { self.cleanup(client); return }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               metadata.opcode == .close {
                self.cleanup(client)
                return
            }
            if let data, let text = String(data: data, encoding: .utf8), text == "ping" {
                self.sendText("pong", client: client)
            }
            self.receiveControl(client)
        }
    }

    private func send(_ entry: LogEntry, client: Client) {
        guard let data = try? encoder.encode(entry), let text = String(data: data, encoding: .utf8) else { return }
        sendText(text, client: client)
    }

    private func sendText(_ text: String, client: Client) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "PocketHost.websocket.text", metadata: [metadata])
        client.connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func cleanup(_ client: Client) {
        if let projectID = client.projectID, let subscriptionID = client.subscriptionID {
            logs.unsubscribe(projectID: projectID, id: subscriptionID)
        }
        lock.lock(); clients[client.id] = nil; lock.unlock()
        client.connection.cancel()
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
