import Foundation
import Network
import CoreGraphics

// MARK: - Protocol

struct TouchData: Codable {
    let id: Int
    let x: Float
    let y: Float
    let phase: String // "began", "moved", "ended", "cancelled"
}

struct TouchMessage: Codable {
    let touches: [TouchData]
}

// MARK: - Gesture Recognition + Event Injection

class GestureEngine {
    var debugSend: ((String) -> Void)?
    func debug(_ msg: String) {
        print("  \(msg)")
        debugSend?(msg)
    }

    struct TouchState {
        var x: Float
        var y: Float
        var startX: Float
        var startY: Float
    }

    var activeTouches: [Int: TouchState] = [:]
    var maxConcurrentTouches = 0
    var touchSequenceStart: Date?
    var maxDisplacement: Float = 0

    // Scroll momentum
    var scrollVelocityX: CGFloat = 0
    var scrollVelocityY: CGFloat = 0
    var momentumTimer: DispatchSourceTimer?
    let momentumDecay: CGFloat = 0.92
    let momentumMinVelocity: CGFloat = 0.5
    var wasScrolling = false

    // Double-tap drag / double-click
    var lastTapTime: Date?
    var isDragging = false
    var pendingDoubleTap = false
    let doubleTapWindow: TimeInterval = 0.3
    let dragDisplacementThreshold: Float = 0.008

    // Three-finger swipe
    var threeFingerTriggered = false
    let threeFingerSwipeThreshold: Float = 0.05

    // Movement ramp-up (dampens initial jitter on finger placement)
    var moveFrameCount = 0
    let rampFrames = 5

    // Tuning — sensX/sensY adjustable from phone
    var sensX: CGFloat = 1.0
    var sensY: CGFloat = 1.0
    let baseSensitivity: CGFloat = 1800
    let tapMaxDuration: TimeInterval = 0.25
    let tapMaxDisplacement: Float = 0.015

    func process(_ message: TouchMessage) {
        var beganTouches: [TouchData] = []
        var movedTouches: [TouchData] = []
        var endedTouches: [TouchData] = []

        for touch in message.touches {
            switch touch.phase {
            case "began": beganTouches.append(touch)
            case "moved": movedTouches.append(touch)
            case "ended": endedTouches.append(touch)
            case "cancelled": endedTouches.append(touch)
            default: break
            }
        }

        // --- Begins ---
        for touch in beganTouches {
            if activeTouches.isEmpty {
                maxConcurrentTouches = 0
                touchSequenceStart = Date()
                maxDisplacement = 0
                moveFrameCount = 0
                stopMomentum()
                scrollVelocityX = 0
                scrollVelocityY = 0

                // Double-tap: defer decision until we see movement (→ drag) or lift (→ double-click)
                if let lastTap = lastTapTime,
                   Date().timeIntervalSince(lastTap) < doubleTapWindow {
                    pendingDoubleTap = true
                    lastTapTime = nil
                }
            }
            activeTouches[touch.id] = TouchState(
                x: touch.x, y: touch.y,
                startX: touch.x, startY: touch.y
            )
        }
        maxConcurrentTouches = max(maxConcurrentTouches, activeTouches.count)

        // --- Moves ---
        if !movedTouches.isEmpty {
            var totalDX: Float = 0
            var totalDY: Float = 0
            var moveCount = 0

            for touch in movedTouches {
                guard var state = activeTouches[touch.id] else { continue }
                totalDX += touch.x - state.x
                totalDY += touch.y - state.y
                moveCount += 1

                state.x = touch.x
                state.y = touch.y
                activeTouches[touch.id] = state

                let disp = hypot(touch.x - state.startX, touch.y - state.startY)
                maxDisplacement = max(maxDisplacement, disp)
            }

            if moveCount > 0 {
                moveFrameCount += 1
                let avgDX = CGFloat(totalDX) / CGFloat(moveCount)
                let avgDY = CGFloat(totalDY) / CGFloat(moveCount)

                // Apply per-axis sensitivity + acceleration curve
                let scaledDX = avgDX * sensX
                let scaledDY = avgDY * sensY
                let magnitude = sqrt(scaledDX * scaledDX + scaledDY * scaledDY)
                let accel = 1.0 + magnitude * 8.0
                let ramp = moveFrameCount <= rampFrames
                    ? CGFloat(moveFrameCount) / CGFloat(rampFrames)
                    : 1.0
                let dx = scaledDX * baseSensitivity * accel * ramp
                let dy = scaledDY * baseSensitivity * accel * ramp

                let fingerCount = activeTouches.count
                if fingerCount == 1 {
                    if pendingDoubleTap && !isDragging && maxDisplacement > dragDisplacementThreshold {
                        // Finger moved enough — commit to drag
                        let pos = currentCursorPos()
                        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                          mouseCursorPosition: pos, mouseButton: .left)
                        down?.post(tap: .cghidEventTap)
                        isDragging = true
                        pendingDoubleTap = false
                        debug("drag started")
                    }
                    if isDragging {
                        dragCursor(dx: dx, dy: dy)
                    } else if !pendingDoubleTap {
                        moveCursor(dx: dx, dy: dy)
                    }
                } else if fingerCount == 2 {
                    let sx = scaledDX * baseSensitivity * 0.6
                    let sy = scaledDY * baseSensitivity * 0.6
                    scroll(dx: sx, dy: sy)
                    // Track velocity for momentum (exponential moving average)
                    scrollVelocityX = scrollVelocityX * 0.3 + sx * 0.7
                    scrollVelocityY = scrollVelocityY * 0.3 + sy * 0.7
                    wasScrolling = true
                    stopMomentum()
                } else if fingerCount == 3 && !threeFingerTriggered {
                    // Check displacement from start for any active touch
                    for (_, state) in activeTouches {
                        let dispX = state.x - state.startX
                        let dispY = state.y - state.startY
                        if abs(dispX) > threeFingerSwipeThreshold || abs(dispY) > threeFingerSwipeThreshold {
                            if abs(dispY) > abs(dispX) {
                                if dispY < 0 {
                                    triggerMissionControl()
                                    debug("3f ↑ Mission Control")
                                } else {
                                    triggerMissionControl()
                                    debug("3f ↓ Mission Control")
                                }
                            } else {
                                if dispX < 0 {
                                    triggerSwitchDesktop(right: true)
                                    debug("3f → next desktop")
                                } else {
                                    triggerSwitchDesktop(right: false)
                                    debug("3f ← prev desktop")
                                }
                            }
                            threeFingerTriggered = true
                            break
                        }
                    }
                }
            }
        }

        // --- Ends ---
        for touch in endedTouches {
            if let state = activeTouches[touch.id] {
                let disp = hypot(touch.x - state.startX, touch.y - state.startY)
                maxDisplacement = max(maxDisplacement, disp)
            }
            activeTouches.removeValue(forKey: touch.id)
        }

        // Check for tap / drag end / momentum when all fingers lifted
        if activeTouches.isEmpty, let start = touchSequenceStart {
            let duration = Date().timeIntervalSince(start)

            if isDragging {
                // End drag — release mouse button
                let pos = currentCursorPos()
                let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                mouseCursorPosition: pos, mouseButton: .left)
                up?.post(tap: .cghidEventTap)
                isDragging = false
                pendingDoubleTap = false
                debug("drag ended")
            } else if pendingDoubleTap {
                // Second tap lifted without moving — double-click
                doubleClick()
                pendingDoubleTap = false
            } else if duration < tapMaxDuration && maxDisplacement < tapMaxDisplacement {
                if maxConcurrentTouches == 1 {
                    click()
                    lastTapTime = Date() // record for double-tap drag detection
                } else if maxConcurrentTouches == 2 {
                    rightClick()
                }
            } else if wasScrolling {
                startMomentum()
            }
            wasScrolling = false
            threeFingerTriggered = false
            touchSequenceStart = nil
        }
    }

    // MARK: - CGEvent Injection

    private func currentCursorPos() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    func moveCursor(dx: CGFloat, dy: CGFloat) {
        let pos = currentCursorPos()
        let newPos = CGPoint(x: pos.x + dx, y: pos.y + dy)
        let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                           mouseCursorPosition: newPos, mouseButton: .left)
        event?.post(tap: .cghidEventTap)
    }

    func dragCursor(dx: CGFloat, dy: CGFloat) {
        let pos = currentCursorPos()
        let newPos = CGPoint(x: pos.x + dx, y: pos.y + dy)
        let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                           mouseCursorPosition: newPos, mouseButton: .left)
        event?.post(tap: .cghidEventTap)
    }

    func click() {
        let pos = currentCursorPos()
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                          mouseCursorPosition: pos, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                        mouseCursorPosition: pos, mouseButton: .left)
        up?.post(tap: .cghidEventTap)
        debug("tap (click)")
    }

    func doubleClick() {
        let pos = currentCursorPos()
        for _ in 0..<2 {
            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                              mouseCursorPosition: pos, mouseButton: .left)
            down?.setIntegerValueField(.mouseEventClickState, value: 2)
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                            mouseCursorPosition: pos, mouseButton: .left)
            up?.setIntegerValueField(.mouseEventClickState, value: 2)
            up?.post(tap: .cghidEventTap)
        }
        debug("double-click")
    }

    func rightClick() {
        let pos = currentCursorPos()
        let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown,
                          mouseCursorPosition: pos, mouseButton: .right)
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp,
                        mouseCursorPosition: pos, mouseButton: .right)
        up?.post(tap: .cghidEventTap)
        debug("2f tap (right click)")
    }

    func simulateKey(_ keyCode: CGKeyCode, control: Bool = false) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        if control {
            down?.flags = .maskControl
            up?.flags = .maskControl
        }
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    func triggerMissionControl() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"System Events\" to key code 126 using control down"]
        try? task.run()
    }

    func triggerSwitchDesktop(right: Bool) {
        let keyCode = right ? 124 : 123
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"System Events\" to key code \(keyCode) using control down"]
        try? task.run()
    }

    func stopMomentum() {
        momentumTimer?.cancel()
        momentumTimer = nil
    }

    func startMomentum() {
        stopMomentum()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.016, repeating: 0.016) // ~60fps
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.scrollVelocityX *= self.momentumDecay
            self.scrollVelocityY *= self.momentumDecay

            if abs(self.scrollVelocityX) < self.momentumMinVelocity &&
               abs(self.scrollVelocityY) < self.momentumMinVelocity {
                self.stopMomentum()
                return
            }

            self.scroll(dx: self.scrollVelocityX, dy: self.scrollVelocityY)
        }
        timer.resume()
        momentumTimer = timer
    }

    func scroll(dx: CGFloat, dy: CGFloat) {
        // Natural scrolling (content follows finger direction)
        if abs(dy) > 0.1 {
            let vScroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                  wheelCount: 1, wheel1: Int32(dy), wheel2: 0, wheel3: 0)
            vScroll?.post(tap: .cghidEventTap)
        }
        if abs(dx) > 0.1 {
            let hScroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                  wheelCount: 1, wheel1: 0, wheel2: Int32(dx), wheel3: 0)
            hScroll?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Network Client (connects to phone via iproxy)

class PhoneConnection {
    let engine = GestureEngine()
    let host: String
    let port: UInt16
    var connection: NWConnection?
    var buffer = Data()
    let decoder = JSONDecoder()
    var isReconnecting = false

    init(host: String = "127.0.0.1", port: UInt16 = 8765) {
        self.host = host
        self.port = port
        engine.debugSend = { [weak self] msg in
            self?.sendDebug(msg)
        }
    }

    func sendDebug(_ msg: String) {
        guard let connection else { return }
        let json = "{\"type\":\"debug\",\"msg\":\"\(msg)\"}\n"
        let data = json.data(using: .utf8)!
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func start() {
        connect()
        dispatchMain()
    }

    func connect() {
        // Cancel any existing connection
        connection?.cancel()
        connection = nil
        isReconnecting = false

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)

        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: params
        )

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("✓ Connected to phone")
                self?.receive()
            case .failed(let error):
                print("✗ Connection failed: \(error)")
                self?.scheduleReconnect()
            case .waiting(let error):
                print("  Waiting: \(error)")
            default:
                break
            }
        }

        conn.start(queue: .main)
        self.connection = conn
    }

    func scheduleReconnect() {
        guard !isReconnecting else { return }
        isReconnecting = true
        print("  Reconnecting in 3s...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.connect()
        }
    }

    func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data {
                self.buffer.append(data)
                self.processBuffer()
            }

            if isComplete {
                print("  Phone disconnected.")
                self.connection?.cancel()
                self.connection = nil
                self.scheduleReconnect()
            } else if error == nil {
                self.receive()
            }
        }
    }

    func processBuffer() {
        // Split by newline, process complete JSON lines
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer = Data(buffer[buffer.index(after: newlineIndex)...])

            guard !lineData.isEmpty else { continue }

            // Check for control messages (have "type" field)
            if let str = String(data: lineData, encoding: .utf8), str.contains("\"type\"") {
                if let ctrl = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                    let msgType = ctrl["type"] as? String ?? ""
                    if msgType == "settings" {
                        if let sx = ctrl["sensX"] as? Double { engine.sensX = CGFloat(sx) }
                        if let sy = ctrl["sensY"] as? Double { engine.sensY = CGFloat(sy) }
                        print("  ← settings: sensX=\(engine.sensX) sensY=\(engine.sensY)")
                    } else {
                        print("  ← \(msgType)")
                    }
                }
                continue
            }

            do {
                let message = try decoder.decode(TouchMessage.self, from: lineData)
                engine.process(message)
            } catch {
                // Skip malformed lines
            }
        }
    }
}

// MARK: - Main

// Disable stdout buffering so output shows immediately in pipes
setbuf(stdout, nil)

print("TrackpadMac - iPhone Trackpad Receiver")
print("=======================================")
print("")
print("Make sure iproxy is running:")
print("  iproxy 8765:8765")
print("")
print("Waiting for connection to phone on localhost:8765...")
print("(Accessibility permissions required for cursor control)")
print("")

let client = PhoneConnection()
client.start()
