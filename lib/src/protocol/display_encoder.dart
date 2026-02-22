import 'dart:typed_data';

import 'constants.dart';
import 'models.dart';

/// Encodes a coordinate value as 4 bytes: integer LE + fraction*10000 LE
/// with sign in bit 7 of byte 3.
Uint8List encodeCoordinate(double value) {
  final bytes = Uint8List(4);
  final sign = value < 0 ? 0x80 : 0;
  final abs = value.abs();
  final integer = abs.truncate();
  final fraction = ((abs - integer) * 10000).round();

  bytes[0] = integer & 0xFF;
  bytes[1] = (integer >> 8) & 0xFF;
  bytes[2] = fraction & 0xFF;
  bytes[3] = ((fraction >> 8) & 0xFF) | sign;

  return bytes;
}

/// Builds the flags byte for display output.
int encodeFlags(DisplayUpdate update) {
  var flags = update.mode.value & 0x03;
  if (update.resetFlag) flags |= 0x40;
  if (update.coordinateSpace == CoordinateSpace.workpiece) flags |= 0x80;
  return flags;
}

/// Encodes a [DisplayUpdate] into a 24-byte logical payload.
Uint8List encodeDisplayPayload(DisplayUpdate update) {
  final payload = Uint8List(displayPayloadLength);

  // Header
  payload[0] = displayHeader[0]; // 0xFE
  payload[1] = displayHeader[1]; // 0xFD
  payload[2] = displayHeader[2]; // 0xFE

  // Flags
  payload[3] = encodeFlags(update);

  // Axis coordinates
  final a1 = encodeCoordinate(update.axis1);
  final a2 = encodeCoordinate(update.axis2);
  final a3 = encodeCoordinate(update.axis3);
  payload.setRange(4, 8, a1);
  payload.setRange(8, 12, a2);
  payload.setRange(12, 16, a3);

  // Feed rate (16-bit LE)
  payload[16] = update.feedRate & 0xFF;
  payload[17] = (update.feedRate >> 8) & 0xFF;

  // Spindle speed (16-bit LE)
  payload[18] = update.spindleSpeed & 0xFF;
  payload[19] = (update.spindleSpeed >> 8) & 0xFF;

  // Bytes 20-23 are padding (already zero)
  return payload;
}

/// Chunks a 24-byte payload into 4 feature reports of 8 bytes each.
///
/// Each report is: `[0x06, <7 data bytes>]`.
List<Uint8List> chunkDisplayReports(Uint8List payload) {
  final reports = <Uint8List>[];
  for (var i = 0; i < displayReportCount; i++) {
    final report = Uint8List(displayReportLength);
    report[0] = displayReportId;
    final offset = i * 7;
    final remaining = payload.length - offset;
    final count = remaining < 7 ? remaining : 7;
    for (var j = 0; j < count; j++) {
      report[1 + j] = payload[offset + j];
    }
    reports.add(report);
  }
  return reports;
}

/// Encodes a [DisplayUpdate] into a list of 4 feature reports ready to send.
List<Uint8List> encodeDisplayUpdate(DisplayUpdate update) {
  return chunkDisplayReports(encodeDisplayPayload(update));
}
