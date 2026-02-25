# SPEC: mpg_pendant

## Problem

CNC operators use MPG pendants (handheld jog controllers) to manually position
their machines. These pendants connect via USB to a host PC, but no
Dart/Flutter package exists to communicate with them. Without one, a
Flutter-based CNC sender cannot read pendant input or update its display.

## Scope

This package is a **pendant driver only**. It decodes pendant input and encodes
display updates. It knows nothing about grbl, serial ports, or machine
control — the consuming application handles that translation.

**Why sender-side, not controller-side:** Typical CNC controllers (e.g.,
grblHAL on Sienci SLB) lack USB host capability. The pendant must be driven
from the PC.

## 1. Hardware Target

*Status: complete — PR #4, 2025-01-15*

The system shall support USB HID-based MPG pendants used by hobbyist and
prosumer CNC operators. Professional CNC pendants use serial or proprietary
connections tied to dedicated controllers and are out of scope.

The architecture shall not be specific to any single pendant family. Adding
support for a new pendant shall not require changes to device I/O or the
public API.

The XHC HB04B family comprises four variants: wired (LHB04B) and wireless
(WHB04B), each in 4-axis and 6-axis configurations. All share USB VID/PID
`10CE:EB93` and the same wire protocol.

Tested with: LHB04B-4 (wired, 4-axis), firmware label TX:V03. Other HB04B
variants are expected to work but have not been verified.

The firmware version is printed on a physical label only. The USB descriptor
exposes a manufacturer string ("KTURT.LTD") but no product string or serial
number (`Product=0, SerialNumber=0`). No known HID report or USB descriptor
field carries the firmware version at runtime.

Supported platforms: Windows, macOS, Linux (desktop only).

**Why desktop-only:** USB HID requires native OS access. Mobile and web
platforms do not expose raw HID interfaces.

## 2. Device Discovery

*Status: complete — PR #4, 2025-01-15*

The system shall enumerate connected pendant devices and return them as
candidates for connection.

- When multiple pendants are connected, all shall be returned.
- When none are connected, an empty list shall be returned.
- When the host OS exposes a single pendant as multiple HID collections, the
  system shall consolidate them into a single logical device.

**Why consolidate:** Windows and macOS create a separate device node for
each HID top-level collection (TLC) in the report descriptor. Linux creates
one device node per USB interface. The number of OS-level device nodes for a
single pendant varies by platform; the consumer should not need to know
this — one pendant means one device.

## 3. Connection Lifecycle

*Status: complete — PR #4, 2025-01-15*

When a pendant is opened, the system shall provide a stream of decoded input
events.

- When a pendant is closed, all resources shall be released.
- When the pendant is physically disconnected, the stream shall emit an error
  and close.
- When a display update is sent after disconnection, the system shall raise an
  error.
- Pendant operations shall not block the consumer's event loop.

**Why non-blocking:** USB HID reads are blocking calls at the OS level.
Running them on the consumer's thread would stall its event loop during
jog operations.

## 4. Input Decoding

*Status: complete — PR #4, 2025-01-15*

The system shall decode HID input reports into structured pendant state values
covering all physical input types.

### 4.1 Buttons

- The system shall decode all pendant buttons to named values.
- When multiple buttons are pressed simultaneously, all shall be reported.
- The system shall support modifier keys that change the meaning of other
  buttons, if the pendant provides them.
- When no button is pressed, the state shall indicate "none."

### 4.2 Jog Events

- The system shall report jog events as (axis, delta) pairs.
- Clockwise/positive rotation shall produce a positive delta;
  counter-clockwise/negative shall produce a negative delta.
- The system shall not emit jog events with no associated axis.

**Why axis+delta pairs:** The consumer needs to know which axis moved and by
how much. How the pendant physically maps user input to axis motion (single
wheel + selector, multiple wheels, etc.) is the driver's concern.

### 4.3 Feed/Step Rate

- The system shall report the currently selected feed or step rate.
- The system shall resolve any modal behavior (e.g., a single knob that
  means different things in step vs. continuous mode) internally, so the
  consumer receives an unambiguous value.

## 5. Display Output

*Status: complete — PR #4, 2025-01-15*

The system shall accept machine state (axis coordinates, feed rate, spindle
speed, and other status) and render it on the pendant's display.

- The system shall encode values in whatever format the pendant firmware
  expects. The consumer provides logical values; the driver handles encoding.
- On connection init, the system shall initialize the display to a known
  state.

**Why init on connect:** The pendant display may retain stale data from a
previous session.

## 6. Input Validation

*Status: complete — PR #4, 2025-01-15*

- Input that fails structural validation shall be dropped silently.
- Unrecognized input codes shall map to a safe default with the raw value
  preserved for diagnostics.

**Why preserve raw values:** Unknown codes may indicate new firmware revisions
or unsupported variants. Preserving them aids debugging without crashing the
consumer.

## 7. Architecture Boundaries

*Status: complete — PR #4, 2025-01-15*

The consumer shall interact with pendants through a generic API expressed in
standard CNC vocabulary (axes, buttons, jog wheel, feed selector, display
updates). The consumer shall not need to know the make, model, or wire
protocol of the connected pendant.

The system shall separate protocol concerns (pendant-specific wire formats)
from device concerns (HID I/O, platform differences) so that each can change
independently.

**Why separate:** Protocol details vary per pendant family. Device I/O varies
per platform. Coupling them would force changes in one to ripple into the
other.

## 8. Dependencies

*Status: complete — PR #4, 2025-01-15*

The system shall use a single native HID library for all desktop platforms
rather than per-platform implementations.

- **hidapi** — Cross-platform USB HID access.

**Why hidapi:** It is the only mature C library that provides a uniform HID
API across Windows, macOS, and Linux. It supports both input reports and
feature reports, which the pendant requires for bidirectional communication.

## 9. Testing Strategy

*Status: complete — PR #4, 2025-01-15*

- Protocol tests shall not require I/O or hardware.
- Device tests shall not require hardware.
- The full test suite shall run without a physical pendant.

**Why no hardware-in-the-loop tests:** The package boundary is bytes in/out.
Simulated I/O exercises the same code paths as real hardware. Hardware
testing requires a physical pendant and is done manually via the example
app.
