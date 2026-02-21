import SwiftUI
import UIKit

// MARK: - Touch data model (matches Mac receiver)

struct TouchData: Codable {
    let id: Int
    let x: Float
    let y: Float
    let phase: String
}

struct TouchMessage: Codable {
    let touches: [TouchData]
}

// MARK: - Raw touch capture UIView

class RawTouchView: UIView {
    var onTouchEvent: (([TouchData]) -> Void)?

    // Stable ID tracking - UITouch objects persist through a touch lifecycle
    private var touchIDMap: [UITouch: Int] = [:]
    private var nextID = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = UIColor(white: 0.08, alpha: 1)
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            touchIDMap[touch] = nextID
            nextID += 1
        }
        sendAll(event?.allTouches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        sendAll(event?.allTouches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        sendAll(event?.allTouches)
        for touch in touches {
            touchIDMap.removeValue(forKey: touch)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        sendAll(event?.allTouches)
        for touch in touches {
            touchIDMap.removeValue(forKey: touch)
        }
    }

    private func sendAll(_ allTouches: Set<UITouch>?) {
        guard let allTouches, !allTouches.isEmpty else { return }
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }

        let data: [TouchData] = allTouches.compactMap { touch in
            guard let id = touchIDMap[touch] else { return nil }
            let loc = touch.location(in: self)
            let phase: String
            switch touch.phase {
            case .began: phase = "began"
            case .moved: phase = "moved"
            case .ended: phase = "ended"
            case .cancelled: phase = "cancelled"
            case .stationary: phase = "moved" // treat as no-op, Mac will see zero delta
            default: return nil
            }
            return TouchData(
                id: id,
                x: Float(loc.x / w),
                y: Float(loc.y / h),
                phase: phase
            )
        }

        onTouchEvent?(data)
    }
}

// MARK: - SwiftUI wrapper

struct TrackpadSurface: UIViewRepresentable {
    let sender: TouchSender

    func makeUIView(context: Context) -> RawTouchView {
        let view = RawTouchView()
        view.onTouchEvent = { touches in
            sender.send(touches: touches)
        }
        return view
    }

    func updateUIView(_ uiView: RawTouchView, context: Context) {}
}

// MARK: - Main view

struct TrackpadView: View {
    @StateObject private var sender = TouchSender()
    @ObservedObject private var lockState = LockState.shared
    @State private var showSettings = false
    @AppStorage("sensX") private var sensX: Double = 1.0
    @AppStorage("sensY") private var sensY: Double = 1.0

    var body: some View {
        ZStack {
            TrackpadSurface(sender: sender)

            VStack {
                HStack {
                    Circle()
                        .fill(sender.isConnected ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                    Text(sender.isConnected ? "Connected" : "Waiting for connection...")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))

                    Spacer()

                    Button {
                        lockState.isLocked.toggle()
                    } label: {
                        Image(systemName: lockState.isLocked ? "lock.fill" : "lock.open")
                            .font(.system(size: 16))
                            .foregroundColor(lockState.isLocked ? .white : .white.opacity(0.5))
                            .frame(width: 44, height: 44)
                    }

                    Button {
                        showSettings.toggle()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 18))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(width: 44, height: 44)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 50)

                Spacer()
            }

            if showSettings {
                SettingsOverlay(
                    sensX: $sensX,
                    sensY: $sensY,
                    onDismiss: { showSettings = false },
                    onChanged: { sender.sendSettings(sensX: sensX, sensY: sensY) }
                )
            }
        }
        .onChange(of: sender.isConnected) { connected in
            if connected {
                sender.sendSettings(sensX: sensX, sensY: sensY)
            }
        }
    }
}

// MARK: - Settings overlay

struct SettingsOverlay: View {
    @Binding var sensX: Double
    @Binding var sensY: Double
    let onDismiss: () -> Void
    let onChanged: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Settings")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 32, height: 32)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("X sensitivity: \(sensX, specifier: "%.2f")")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                Slider(value: $sensX, in: 0.2...3.0, step: 0.05)
                    .tint(.white.opacity(0.5))
                    .onChange(of: sensX) { _ in onChanged() }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Y sensitivity: \(sensY, specifier: "%.2f")")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                Slider(value: $sensY, in: 0.2...3.0, step: 0.05)
                    .tint(.white.opacity(0.5))
                    .onChange(of: sensY) { _ in onChanged() }
            }

            Button {
                sensX = 1.0
                sensY = 1.0
                onChanged()
            } label: {
                Text("Reset")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.15))
                .shadow(radius: 20)
        )
        .frame(maxWidth: 320)
    }
}
