/// Button codes reported by the pendant.
enum PendantButton {
  none(0x00),
  reset(0x01),
  stop(0x02),
  startPause(0x03),
  feedPlus(0x04),
  feedMinus(0x05),
  spindlePlus(0x06),
  spindleMinus(0x07),
  mHome(0x08),
  safeZ(0x09),
  wHome(0x0A),
  spindleOnOff(0x0B),
  fn(0x0C),
  probeZ(0x0D),
  continuous(0x0E),
  step(0x0F),
  macro10(0x10),
  macro1(0x81),
  macro2(0x82),
  macro3(0x83),
  macro4(0x84),
  macro5(0x85),
  macro6(0x86),
  macro7(0x87),
  macro8(0x88),
  macro9(0x89);

  const PendantButton(this.code);
  final int code;

  /// Buttons with dual function/macro labels. Maps the function button
  /// to its corresponding macro.
  static const _fnPairs = {
    PendantButton.feedPlus: PendantButton.macro1,
    PendantButton.feedMinus: PendantButton.macro2,
    PendantButton.spindlePlus: PendantButton.macro3,
    PendantButton.spindleMinus: PendantButton.macro4,
    PendantButton.mHome: PendantButton.macro5,
    PendantButton.safeZ: PendantButton.macro6,
    PendantButton.wHome: PendantButton.macro7,
    PendantButton.spindleOnOff: PendantButton.macro8,
    PendantButton.probeZ: PendantButton.macro9,
  };

  /// Whether this button has dual function/macro labels.
  bool get isDualLabel => _fnPairs.containsKey(this);

  /// Returns the macro equivalent of this dual-label button, or null.
  PendantButton? get macroEquivalent => _fnPairs[this];

  /// Returns the function equivalent of this macro button, or null.
  PendantButton? get functionEquivalent {
    for (final entry in _fnPairs.entries) {
      if (entry.value == this) return entry.key;
    }
    return null;
  }

  static PendantButton fromCode(int code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return none;
  }
}

/// Axis selector positions.
enum PendantAxis {
  off(0x06),
  x(0x11),
  y(0x12),
  z(0x13),
  a(0x14),
  b(0x15),
  c(0x16);

  const PendantAxis(this.code);
  final int code;

  static PendantAxis fromCode(int code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return off;
  }
}

/// 7-position rotary feed selector.
///
/// Each position has mode-dependent meaning:
/// - **Step mode**: [stepValue] is the jog increment in inches, as shown on
///   the device firmware display. Positions 4–5 are blank on the faceplate;
///   the firmware clamps their step display to 1.0.
/// - **Continuous mode**: [continuousPercent] is the feed override percentage,
///   matching the faceplate labels.
/// - **Lead** (position 6): spindle-synchronous mode. Neither step size nor
///   percentage applies; both fields are null.
enum FeedSelector {
  position0(0x0D, 0.001, 2),
  position1(0x0E, 0.01, 5),
  position2(0x0F, 0.1, 10),
  position3(0x10, 1.0, 30),
  position4(0x1A, 1.0, 60),
  position5(0x1B, 1.0, 100),
  position6(0x1C, null, null);

  const FeedSelector(this.code, this.stepValue, this.continuousPercent);
  final int code;

  /// Jog increment in inches, or null for Lead mode.
  final double? stepValue;

  /// Feed override percentage, or null for Lead mode.
  final int? continuousPercent;

  static FeedSelector fromCode(int code) {
    // Handle alternate lead code from some firmware versions
    if (code == 0x9B) return position6;
    for (final value in values) {
      if (value.code == code) return value;
    }
    return position0;
  }
}

/// Motion mode for display flags.
enum MotionMode {
  continuous(0),
  step(1),
  mpg(2),
  percent(3);

  const MotionMode(this.value);
  final int value;
}

/// Coordinate space for display flags.
enum CoordinateSpace {
  machine(0),
  workpiece(1);

  const CoordinateSpace(this.value);
  final int value;
}

/// Decoded state from a single pendant input packet.
class PendantState {
  const PendantState({
    required this.button1,
    required this.button2,
    required this.axis,
    required this.feed,
    required this.jogDelta,
  });

  final PendantButton button1;
  final PendantButton button2;
  final PendantAxis axis;
  final FeedSelector feed;

  /// Signed jog wheel delta (-128..+127). Zero when axis is OFF.
  final int jogDelta;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PendantState &&
          button1 == other.button1 &&
          button2 == other.button2 &&
          axis == other.axis &&
          feed == other.feed &&
          jogDelta == other.jogDelta;

  @override
  int get hashCode => Object.hash(button1, button2, axis, feed, jogDelta);

  @override
  String toString() =>
      'PendantState(button1: $button1, button2: $button2, '
      'axis: $axis, feed: $feed, jogDelta: $jogDelta)';
}

/// Data to send to the pendant display.
class DisplayUpdate {
  const DisplayUpdate({
    this.axis1 = 0.0,
    this.axis2 = 0.0,
    this.axis3 = 0.0,
    this.feedRate = 0,
    this.spindleSpeed = 0,
    this.mode = MotionMode.continuous,
    this.resetFlag = false,
    this.coordinateSpace = CoordinateSpace.machine,
  });

  /// X or A axis coordinate.
  final double axis1;

  /// Y or B axis coordinate.
  final double axis2;

  /// Z or C axis coordinate.
  final double axis3;

  final int feedRate;
  final int spindleSpeed;
  final MotionMode mode;
  final bool resetFlag;
  final CoordinateSpace coordinateSpace;
}
