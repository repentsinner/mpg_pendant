# Requirements: mpg_pendant

## Overview

The `mpg_pendant` package provides cross-platform USB HID communication with XHC WHB04B-family CNC pendants (xHB04B, WHB04B-4, WHB04B-6). It decodes input from the pendant and encodes display updates back to it.

## User Stories & EARS Acceptance Criteria

### R1: Device Discovery

**As a** sender application, **I want to** discover connected pendant dongles, **so that** I can present them to the user and establish a connection.

**EARS Criteria:**

- **R1.1** When the system enumerates HID devices, then devices with VID `0x10CE` and PID `0xEB93` shall be identified as pendant dongles.
- **R1.2** When multiple pendant dongles are connected, then all matching devices shall be returned.
- **R1.3** When no pendant dongle is connected, then an empty list shall be returned.

### R2: Connection Lifecycle

**As a** sender application, **I want to** open and close connections to a pendant, **so that** I can manage its lifecycle cleanly.

**EARS Criteria:**

- **R2.1** When a pendant device is opened, then the connection shall provide a stream of input events.
- **R2.2** When a pendant device is closed, then all resources (HID handle, stream) shall be released.
- **R2.3** When the pendant is physically disconnected during an active connection, then the stream shall emit an error and close.
- **R2.4** When sending a display update after disconnection, then an error shall be raised.

### R3: Button Events

**As a** sender application, **I want to** receive decoded button press/release events, **so that** I can trigger the appropriate machine actions.

**EARS Criteria:**

- **R3.1** When a button is pressed, then the corresponding `PendantButton` enum value shall be emitted.
- **R3.2** When the Fn key (code `0x0C`) is held and another button is pressed, then the event shall indicate an Fn-modified press.
- **R3.3** When two non-Fn buttons are pressed simultaneously, then both button codes shall be reported.
- **R3.4** When all buttons are released, then button fields shall be `PendantButton.none`.
- **R3.5** The system shall decode all 16 button codes (`0x01`–`0x10`) to named enum values.

### R4: Jog Wheel

**As a** sender application, **I want to** receive jog wheel rotation events, **so that** I can issue jog commands to the machine.

**EARS Criteria:**

- **R4.1** When the jog wheel rotates clockwise, then a positive signed delta shall be reported.
- **R4.2** When the jog wheel rotates counter-clockwise, then a negative signed delta shall be reported.
- **R4.3** When the jog wheel is stationary, then delta shall be zero.
- **R4.4** The jog delta shall be a signed 8-bit value in the range -128 to +127.
- **R4.5** When the axis selector is OFF, then jog events shall be suppressed (delta forced to zero).

### R5: Axis Selector

**As a** sender application, **I want to** know which axis is selected, **so that** I can direct jog commands to the correct axis.

**EARS Criteria:**

- **R5.1** When the axis knob is turned, then the corresponding `PendantAxis` value shall be reported (OFF, X, Y, Z, A, B, C).
- **R5.2** When axis codes `0x15` (B) or `0x16` (C) are received, then the pendant shall be identified as a 6-axis variant.
- **R5.3** When the axis is OFF (code `0x06`), then jog wheel deltas shall be suppressed.

### R6: Feed/Step Selector

**As a** sender application, **I want to** know the feed rate or step size selection, **so that** I can apply the correct jog parameters.

**EARS Criteria:**

- **R6.1** When the feed/step knob is turned, then the selected position shall be reported with both step-mode and continuous-mode interpretations.
- **R6.2** The system shall decode all 7 selector positions: 0.001/2%, 0.01/5%, 0.1/10%, 1.0/30%, 5.0/60%, 10.0/100%, Lead.
- **R6.3** When the Lead position is selected, then the step value shall indicate lead mode.

### R7: Display Output

**As a** sender application, **I want to** send coordinate and status information to the pendant display, **so that** the operator can see machine state.

**EARS Criteria:**

- **R7.1** When coordinates are provided, then they shall be encoded as 4-byte fixed-point values (integer LE + fraction*10000 LE with sign in MSB of byte 3).
- **R7.2** Given the value `-1234.5678`, then the encoded bytes shall be `[0xD2, 0x04, 0x2E, 0x96]`.
- **R7.3** When a display update is sent, then it shall be chunked into 4 feature reports of 8 bytes each, with report ID `0x06`.
- **R7.4** The flags byte shall encode motion mode (bits 0-1), reset flag (bit 6), and coordinate space (bit 7).
- **R7.5** When initializing the display, then a reset sequence (set reset flag, clear reset flag) shall be sent.
- **R7.6** The display payload shall begin with header bytes `0xFE, 0xFD, 0xFE`.

### R8: Multi-variant Support

**As a** sender application, **I want to** use the same API for 4-axis and 6-axis pendants, **so that** my code does not need variant-specific handling.

**EARS Criteria:**

- **R8.1** When a 4-axis pendant reports axes OFF/X/Y/Z/A, then all axis values shall be decoded correctly.
- **R8.2** When a 6-axis pendant additionally reports B and C axes, then these shall also be decoded correctly.
- **R8.3** The `PendantAxis` enum shall include all 7 positions (OFF, X, Y, Z, A, B, C) regardless of hardware variant.
