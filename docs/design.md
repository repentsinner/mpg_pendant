# Design: mpg_pendant

## Architecture Overview

The package is split into two layers:

```
┌─────────────────────────────────────────┐
│            Consumer Application          │
│     (Flutter/Dart CNC sender app)        │
├─────────────────────────────────────────┤
│          Public API (barrel file)         │
│            mpg_pendant.dart              │
├──────────────────┬──────────────────────┤
│   Protocol Layer │    Device Layer       │
│  (pure Dart,     │  (HID I/O via        │
│   no I/O)        │   hid4flutter FFI)   │
│                  │                       │
│  input_packet    │  hid_backend          │
│  display_encoder │  hidapi_backend       │
│  constants       │  pendant_discovery    │
│  models          │  pendant_connection   │
└──────────────────┴──────────────────────┘
```

**Protocol layer** — Pure functions that decode input packets and encode display updates. Fully testable without hardware or mocks.

**Device layer** — Manages HID device discovery, connection lifecycle, and I/O. Uses an abstract `HidBackend` interface so tests can inject a mock implementation.

## Data Models

### Enums

```dart
enum PendantButton {
  none,       // 0x00
  reset,      // 0x01
  stop,       // 0x02
  startPause, // 0x03
  feedPlus,   // 0x04
  feedMinus,  // 0x05
  spindlePlus,  // 0x06
  spindleMinus, // 0x07
  mHome,      // 0x08
  safeZ,      // 0x09
  wHome,      // 0x0A
  spindleOnOff, // 0x0B
  fn,         // 0x0C
  probeZ,     // 0x0D
  continuous, // 0x0E
  step,       // 0x0F
  macro10,    // 0x10
}

enum PendantAxis {
  off,  // 0x06
  x,    // 0x11
  y,    // 0x12
  z,    // 0x13
  a,    // 0x14
  b,    // 0x15  (6-axis only)
  c,    // 0x16  (6-axis only)
}

enum FeedSelector {
  step0001,  // 0x0D — step: 0.001, continuous: 2%
  step001,   // 0x0E — step: 0.01,  continuous: 5%
  step01,    // 0x0F — step: 0.1,   continuous: 10%
  step1,     // 0x10 — step: 1.0,   continuous: 30%
  step5,     // 0x1A — step: 5.0,   continuous: 60%
  step10,    // 0x1B — step: 10.0,  continuous: 100%
  lead,      // 0x1C — lead mode
}

enum MotionMode { continuous, step, mpg, percent }
enum CoordinateSpace { machine, workpiece }
```

### Value Classes

```dart
class PendantState {
  final PendantButton button1;
  final PendantButton button2;
  final PendantAxis axis;
  final FeedSelector feed;
  final int jogDelta;  // signed, -128..+127
}

class DisplayUpdate {
  final double axis1;  // X or A
  final double axis2;  // Y or B
  final double axis3;  // Z or C
  final int feedRate;
  final int spindleSpeed;
  final MotionMode mode;
  final bool resetFlag;
  final CoordinateSpace coordinateSpace;
}
```

## Interfaces

### HidBackend (abstract, mockable)

```dart
abstract class HidBackend {
  List<HidDeviceInfo> enumerate(int vendorId, int productId);
  HidDeviceHandle open(String path);
  List<int> read(HidDeviceHandle handle, int length, {Duration? timeout});
  void sendFeatureReport(HidDeviceHandle handle, List<int> data);
  void close(HidDeviceHandle handle);
}
```

### PendantDiscovery

```dart
class PendantDiscovery {
  PendantDiscovery(this._backend);
  List<HidDeviceInfo> findPendants();
}
```

### PendantConnection

```dart
class PendantConnection {
  PendantConnection(this._backend, this._deviceInfo);
  Stream<PendantState> get events;
  void updateDisplay(DisplayUpdate update);
  void sendResetSequence();
  Future<void> close();
}
```

## Protocol Details

### Input Packet (8 bytes, device → host)

| Byte | Field        | Type   | Description                          |
|------|-------------|--------|--------------------------------------|
| 0    | Header      | u8     | Always `0x04`                        |
| 1    | Seed        | u8     | Rotating value for checksum          |
| 2    | Key1        | u8     | First button code (`0x00` = none)    |
| 3    | Key2        | u8     | Second button code (`0x00` = none)   |
| 4    | Feed/Step   | u8     | Feed selector position               |
| 5    | Axis        | u8     | Axis selector position               |
| 6    | Jog Delta   | i8     | Signed wheel rotation (-128..+127)   |
| 7    | Checksum    | u8     | Packet integrity (not validated)      |

### Display Output (4 × 8-byte feature reports, host → device)

Each report starts with report ID `0x06`, followed by 7 data bytes.

Logical 24-byte payload layout:

| Offset | Field          | Encoding                               |
|--------|---------------|----------------------------------------|
| 0–2    | Header        | `0xFE, 0xFD, 0xFE`                    |
| 3      | Flags         | See flags byte below                   |
| 4–7    | Axis 1 coord  | Fixed-point 4 bytes                    |
| 8–11   | Axis 2 coord  | Fixed-point 4 bytes                    |
| 12–15  | Axis 3 coord  | Fixed-point 4 bytes                    |
| 16–17  | Feed rate     | 16-bit LE unsigned                     |
| 18–19  | Spindle speed | 16-bit LE unsigned                     |
| 20–23  | Padding       | Zeros                                  |

**Coordinate encoding:** 4 bytes per value.
- Bytes 0-1: absolute integer part, little-endian
- Bytes 2-3: (fractional × 10000), little-endian, with sign in bit 7 of byte 3

**Flags byte:**
- Bits 0–1: Motion mode (0=CONT, 1=STEP, 2=MPG, 3=PCT)
- Bit 6: Reset flag
- Bit 7: Coordinate space (0=machine, 1=workpiece)

## Platform Strategy

- **Desktop (Windows, macOS, Linux):** `hid4flutter` package provides hidapi bindings via `dart:ffi`.
- **Mobile/Web:** Not supported (no USB HID access).

## Error Handling

- **Disconnection:** HID read returns error/empty → stream emits error and closes.
- **Permission errors:** Propagated as exceptions from `HidBackend.open()`.
- **Malformed packets:** Invalid header byte → packet dropped silently. Unknown button/axis/feed codes → mapped to a safe default with the raw code preserved.

## Testability

The `HidBackend` abstraction is the key testability seam:
- Protocol tests use hardcoded byte arrays — no mocks needed.
- Device tests inject a `MockHidBackend` that returns scripted byte sequences.
- No physical hardware required for the full test suite.
