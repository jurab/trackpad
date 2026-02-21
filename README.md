# trackpad

Use your iPhone as a Mac trackpad over USB.

## How it works

- iPhone runs a full-screen touch capture surface and a TCP server
- Mac connects via `iproxy` (USB tunnel), receives touch data, injects cursor/click/scroll events via CGEvent
- Protocol: newline-delimited JSON over TCP port 8765

## Setup

### Prerequisites

```bash
brew install libimobiledevice xcodegen
```

iPhone needs Developer Mode enabled (Settings → Privacy & Security → Developer Mode).

### Build & deploy the iPhone app

```bash
cd PhoneTrackpad
xcodegen generate
xcodebuild -scheme PhoneTrackpad -destination 'id=YOUR_DEVICE_UDID' -allowProvisioningUpdates build
xcrun devicectl device install app --device YOUR_DEVICE_UDID \
  path/to/DerivedData/PhoneTrackpad.../Build/Products/Debug-iphoneos/PhoneTrackpad.app
xcrun devicectl device process launch --device YOUR_DEVICE_UDID com.trackpad.phone
```

You'll need to trust the developer profile on the phone (Settings → General → VPN & Device Management).

### Run the Mac side

```bash
./start.sh
```

Or manually:

```bash
iproxy 8765:8765 &
cd MacReceiver && swift run
```

Grant Accessibility permissions to your terminal when prompted.

## Features

- **1-finger drag** → cursor movement (with acceleration)
- **1-finger tap** → left click
- **Double-tap and drag** → click-hold-move (for dragging windows, selecting text, etc.)
- **2-finger tap** → right click
- **2-finger drag** → scroll (natural direction, with momentum)
- **3-finger swipe up/down** → Mission Control (open/dismiss)
- **3-finger swipe left/right** → switch desktops (Spaces)
- **X/Y sensitivity sliders** — settings panel on phone, values sent to Mac in real-time
- **Debug HUD** — two-column live log (Mac/Phone) on the touch surface, toggle with terminal icon
- **Lock mode** — defers iOS edge gestures so swipes don't trigger Control Center / notifications
- **Landscape support** — rotate for a wider surface
- **Auto-reconnect** — survives app switching and cable reconnection

## Project structure

```
MacReceiver/          Swift Package CLI — gesture recognition + CGEvent injection
PhoneTrackpad/        iOS app — touch capture + TCP server (xcodegen project)
start.sh              Launches iproxy + Mac receiver
```
