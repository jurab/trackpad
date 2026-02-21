import UIKit
import Network
import Combine

class TouchSender: ObservableObject {
    @Published var isConnected = false
    let port: UInt16 = 8765

    private var listener: NWListener?
    private var connection: NWConnection?
    private let encoder = JSONEncoder()
    private let queue = DispatchQueue(label: "touchsender", qos: .userInteractive)

    init() {
        startListener()

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.restart()
        }
    }

    func restart() {
        print("[Lifecycle] foregrounded, restarting listener")
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        isConnected = false
        startListener()
    }

    func startListener() {
        do {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let params = NWParameters(tls: nil, tcp: tcp)

            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)

            listener?.newConnectionHandler = { [weak self] conn in
                self?.handleConnection(conn)
            }

            listener?.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    print("[Listener] ready on port \(self.port)")
                case .failed(let error):
                    print("[Listener] failed: \(error), restarting...")
                    self.listener?.cancel()
                    self.startListener()
                default:
                    break
                }
            }

            listener?.start(queue: queue)
        } catch {
            print("[Listener] create failed: \(error)")
        }
    }

    private func handleConnection(_ conn: NWConnection) {
        // If we already have a working connection, reject the new one (likely iproxy probe)
        if let existing = connection, existing.state == .ready {
            print("[Conn] rejecting new connection — already have active one")
            conn.cancel()
            return
        }

        // Cancel any non-ready previous connection
        connection?.cancel()
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            print("[Conn] state: \(state)")
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.isConnected = true
                    self?.sendHello()
                    print("[Conn] Mac connected!")
                case .failed, .cancelled:
                    self?.isConnected = false
                    self?.connection = nil
                    print("[Conn] Mac disconnected")
                default:
                    break
                }
            }
        }

        conn.start(queue: queue)
    }

    private func sendHello() {
        guard let connection else { return }
        let hello = "{\"type\":\"hello\"}\n".data(using: .utf8)!
        connection.send(content: hello, completion: .contentProcessed { error in
            if let error {
                print("[Conn] hello send error: \(error)")
            } else {
                print("[Conn] hello sent")
            }
        })
    }

    func send(touches: [TouchData]) {
        guard let connection, isConnected else { return }

        let message = TouchMessage(touches: touches)
        guard var data = try? encoder.encode(message) else { return }
        data.append(0x0A) // newline delimiter

        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                print("[Send] error: \(error)")
            }
        })
    }

    func sendSettings(sensX: Double, sensY: Double) {
        guard let connection, isConnected else { return }
        let json = "{\"type\":\"settings\",\"sensX\":\(sensX),\"sensY\":\(sensY)}\n"
        let data = json.data(using: .utf8)!
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                print("[Send] settings error: \(error)")
            }
        })
    }
}
