# ADR-001: Target Sender Software, Not Controller

## Status

Accepted

## Context

The XHC WHB04B pendant connects to a host PC via a USB RF dongle. We considered two integration points:

1. **Controller-side** — Connect the dongle directly to the grblHAL controller (e.g., Sienci SLB)
2. **Sender-side** — Connect the dongle to the PC running sender software, which bridges pendant events to grbl commands

The controller-side approach is not feasible because:

- The Sienci SLB's USB port operates in **device mode only** — it cannot act as a USB host to enumerate and read HID devices.
- grblHAL has **no USB host stack** — there is no facility to receive HID input reports from a pendant dongle.
- Even if hardware were modified, grblHAL's real-time control loop is not designed to process HID protocol decoding alongside motion control.

## Decision

We target **sender software** as the integration point. The `mpg_pendant` Dart package runs on the host PC, reads HID reports from the pendant dongle, and exposes a stream of decoded pendant events. The consuming application (a Flutter/Dart CNC sender) is responsible for translating those events into grbl commands sent over serial or ethernet to the controller.

## Consequences

- The package needs cross-platform USB HID access on the host PC (Windows, macOS, Linux).
- We use `hid4flutter` (hidapi via FFI) for HID communication.
- The package is a pure pendant driver — it does not know about grbl commands, serial ports, or network protocols.
- Latency includes USB HID polling (~8ms) plus sender-to-controller transport, which is acceptable for jog operations.
- The consumer app has full control over how pendant events map to machine behavior.
