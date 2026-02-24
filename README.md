Cross-platform USB HID driver for CNC MPG pendants. Decodes button presses,
jog wheel movement, and selector positions into structured Dart objects.
Encodes machine state back to the pendant's LCD display.

Currently supports XHC WHB04B-family pendants (xHB04B, WHB04B-4, WHB04B-6).

## Features

- **Device discovery** — enumerates connected pendants, consolidates
  platform-specific HID collections into a single logical device
- **Input decoding** — buttons (with Fn modifier), 6-axis jog wheel,
  feed/step selector, continuous/step mode tracking
- **Display output** — axis coordinates, feed rate, spindle speed,
  coordinate space, and motion mode
- **Non-blocking I/O** — HID reads run in a dedicated isolate
- **Cross-platform** — Windows, macOS, Linux (desktop only)

## Requirements

- Dart SDK `>=3.10.0 <4.0.0`
- A C toolchain for building the native [hidapi](https://github.com/libusb/hidapi)
  dependency (CMake, a C compiler)

## Getting started

Add the dependency:

```yaml
dependencies:
  mpg_pendant:
    git:
      url: https://github.com/repentsinner/mpg-pendant.git
```

The native `hidapi` library builds automatically via Dart's
[native assets](https://dart.dev/interop/c-interop#native-assets) hook on
first run.

## Usage

### Discover and connect

```dart
import 'package:mpg_pendant/mpg_pendant.dart';

final backend = HidapiHidBackend();
final discovery = PendantDiscovery(backend);

final pendants = discovery.findPendants();
if (pendants.isEmpty) {
  print('No pendant found.');
  return;
}

final conn = PendantConnection(pendants.first);
final stream = await conn.open();
conn.sendResetSequence();
```

### Read input events

```dart
stream.listen((PendantState state) {
  print('Button: ${state.button1}');
  print('Axis: ${state.axis}, Jog: ${state.jogDelta}');
  print('Feed: ${state.feed}');
});
```

### Update the display

```dart
conn.updateDisplay(DisplayUpdate(
  axis1: 12.345,
  axis2: -6.789,
  axis3: 0.0,
  feedRate: 1000,
  spindleSpeed: 12000,
  coordinateSpace: CoordinateSpace.workpiece,
));
```

### Clean up

```dart
await conn.close();
```

## Supported hardware

| Family | Models | Interface |
|--------|--------|-----------|
| XHC WHB04B | xHB04B, WHB04B-4, WHB04B-6 | USB HID wireless dongle |

The architecture supports adding new pendant families without changing the
public API or device I/O layer.

## Platform notes

- **Windows** — the pendant enumerates as multiple HID collections; the
  driver probes to identify read vs. write endpoints automatically.
- **macOS / Linux** — a single HID interface handles both directions.
- **Linux** — you may need a udev rule to grant non-root access to the
  device. Example:

  ```
  SUBSYSTEM=="hidraw", ATTRS{idVendor}=="10ce", MODE="0666"
  ```

## Additional information

- [SPEC.md](SPEC.md) — design rationale and requirements
- [Example app](example/pendant_monitor.dart) — terminal-based monitor
  that exercises all inputs and drives the display at 125 Hz
- [Issue tracker](https://github.com/repentsinner/mpg-pendant/issues)

This package is a pendant driver only. It does not implement grbl, serial
communication, or machine control — the consuming application handles that.
