import 'dart:typed_data';

import 'constants.dart';
import 'models.dart';

/// Decodes an 8-byte HID input report into a [PendantState].
///
/// Returns `null` if the packet is malformed (wrong length or header).
PendantState? decodeInputPacket(Uint8List data) {
  if (data.length < inputPacketLength) return null;
  if (data[0] != inputReportHeader) return null;

  final button1 = PendantButton.fromCode(data[2]);
  final button2 = PendantButton.fromCode(data[3]);
  final jogSelector = JogSelector.fromCode(data[4]);
  final axis = PendantAxis.fromCode(data[5]);

  // Jog delta is a signed 8-bit value at byte 6.
  int jogDelta = data[6];
  if (jogDelta > 127) jogDelta -= 256;

  // Suppress jog when axis is OFF.
  if (axis == PendantAxis.off) jogDelta = 0;

  return PendantState(
    button1: button1,
    button2: button2,
    axis: axis,
    jogSelector: jogSelector,
    jogDelta: jogDelta,
  );
}
