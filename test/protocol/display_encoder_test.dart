import 'dart:typed_data';

import 'package:mpg_pendant/mpg_pendant.dart';
import 'package:test/test.dart';

void main() {
  group('Coordinate encoding', () {
    test('encodes positive value 123.4567', () {
      final bytes = encodeCoordinate(123.4567);
      // integer: 123 = 0x007B → [0x7B, 0x00]
      // fraction: 0.4567 * 10000 = 4567 = 0x11D7 → [0xD7, 0x11]
      expect(bytes[0], 0x7B);
      expect(bytes[1], 0x00);
      expect(bytes[2], 0xD7);
      expect(bytes[3], 0x11);
    });

    test('encodes known value -1234.5678 → [0xD2, 0x04, 0x2E, 0x96]', () {
      final bytes = encodeCoordinate(-1234.5678);
      expect(bytes[0], 0xD2); // 1234 & 0xFF
      expect(bytes[1], 0x04); // 1234 >> 8
      expect(bytes[2], 0x2E); // 5678 & 0xFF
      expect(bytes[3], 0x96); // (5678 >> 8) | 0x80
    });

    test('encodes zero', () {
      final bytes = encodeCoordinate(0.0);
      expect(bytes, equals(Uint8List.fromList([0, 0, 0, 0])));
    });

    test('encodes negative zero as zero', () {
      final bytes = encodeCoordinate(-0.0);
      // -0.0 abs is 0.0, sign bit depends on implementation
      expect(bytes[0], 0);
      expect(bytes[1], 0);
      expect(bytes[2], 0);
      // -0.0 in Dart: (-0.0) < 0 is false, so sign bit should not be set
      expect(bytes[3], 0);
    });

    test('encodes integer-only value 500.0', () {
      final bytes = encodeCoordinate(500.0);
      // 500 = 0x01F4
      expect(bytes[0], 0xF4);
      expect(bytes[1], 0x01);
      expect(bytes[2], 0x00);
      expect(bytes[3], 0x00);
    });

    test('encodes fraction-only value 0.1234', () {
      final bytes = encodeCoordinate(0.1234);
      // integer: 0
      // fraction: 1234 = 0x04D2
      expect(bytes[0], 0x00);
      expect(bytes[1], 0x00);
      expect(bytes[2], 0xD2);
      expect(bytes[3], 0x04);
    });

    test('encodes negative value -0.5', () {
      final bytes = encodeCoordinate(-0.5);
      // integer: 0
      // fraction: 5000 = 0x1388
      expect(bytes[0], 0x00);
      expect(bytes[1], 0x00);
      expect(bytes[2], 0x88);
      expect(bytes[3], 0x13 | 0x80); // 0x93
    });
  });

  group('Flags encoding', () {
    test('continuous mode, machine coords, no reset', () {
      final flags = encodeFlags(const DisplayUpdate(
        mode: MotionMode.continuous,
        coordinateSpace: CoordinateSpace.machine,
      ));
      expect(flags, 0x00);
    });

    test('step mode', () {
      final flags = encodeFlags(const DisplayUpdate(mode: MotionMode.step));
      expect(flags & 0x03, 1);
    });

    test('mpg mode', () {
      final flags = encodeFlags(const DisplayUpdate(mode: MotionMode.mpg));
      expect(flags & 0x03, 2);
    });

    test('percent mode', () {
      final flags = encodeFlags(const DisplayUpdate(mode: MotionMode.percent));
      expect(flags & 0x03, 3);
    });

    test('reset flag sets bit 6', () {
      final flags = encodeFlags(const DisplayUpdate(resetFlag: true));
      expect(flags & 0x40, 0x40);
    });

    test('workpiece coordinate space sets bit 7', () {
      final flags = encodeFlags(const DisplayUpdate(
        coordinateSpace: CoordinateSpace.workpiece,
      ));
      expect(flags & 0x80, 0x80);
    });

    test('all flags combined', () {
      final flags = encodeFlags(const DisplayUpdate(
        mode: MotionMode.step,
        resetFlag: true,
        coordinateSpace: CoordinateSpace.workpiece,
      ));
      expect(flags, 0x01 | 0x40 | 0x80); // 0xC1
    });
  });

  group('Display payload assembly', () {
    test('payload is 24 bytes', () {
      final payload = encodeDisplayPayload(const DisplayUpdate());
      expect(payload.length, 24);
    });

    test('payload starts with header 0xFE, 0xFD, 0xFE', () {
      final payload = encodeDisplayPayload(const DisplayUpdate());
      expect(payload[0], 0xFE);
      expect(payload[1], 0xFD);
      expect(payload[2], 0xFE);
    });

    test('flags byte at offset 3', () {
      final payload = encodeDisplayPayload(const DisplayUpdate(
        mode: MotionMode.step,
        resetFlag: true,
      ));
      expect(payload[3], 0x01 | 0x40);
    });

    test('coordinates placed at correct offsets', () {
      final payload = encodeDisplayPayload(const DisplayUpdate(
        axis1: 1.0,
        axis2: 2.0,
        axis3: 3.0,
      ));
      // axis1 at offset 4: 1.0 → [0x01, 0x00, 0x00, 0x00]
      expect(payload[4], 0x01);
      expect(payload[5], 0x00);
      // axis2 at offset 8: 2.0 → [0x02, 0x00, 0x00, 0x00]
      expect(payload[8], 0x02);
      expect(payload[9], 0x00);
      // axis3 at offset 12: 3.0 → [0x03, 0x00, 0x00, 0x00]
      expect(payload[12], 0x03);
      expect(payload[13], 0x00);
    });

    test('feed rate at offset 16 (LE)', () {
      final payload = encodeDisplayPayload(const DisplayUpdate(feedRate: 1000));
      // 1000 = 0x03E8
      expect(payload[16], 0xE8);
      expect(payload[17], 0x03);
    });

    test('spindle speed at offset 18 (LE)', () {
      final payload = encodeDisplayPayload(
        const DisplayUpdate(spindleSpeed: 24000),
      );
      // 24000 = 0x5DC0
      expect(payload[18], 0xC0);
      expect(payload[19], 0x5D);
    });

    test('padding bytes 20-23 are zero', () {
      final payload = encodeDisplayPayload(const DisplayUpdate(
        axis1: 999.999,
        feedRate: 65535,
        spindleSpeed: 65535,
      ));
      expect(payload[20], 0);
      expect(payload[21], 0);
      expect(payload[22], 0);
      expect(payload[23], 0);
    });
  });

  group('Report chunking', () {
    test('produces exactly 4 reports', () {
      final reports = encodeDisplayUpdate(const DisplayUpdate());
      expect(reports.length, 4);
    });

    test('each report is 8 bytes', () {
      final reports = encodeDisplayUpdate(const DisplayUpdate());
      for (final report in reports) {
        expect(report.length, 8);
      }
    });

    test('each report starts with report ID 0x06', () {
      final reports = encodeDisplayUpdate(const DisplayUpdate());
      for (final report in reports) {
        expect(report[0], 0x06);
      }
    });

    test('report 1 contains header bytes', () {
      final reports = encodeDisplayUpdate(const DisplayUpdate());
      // Payload bytes 0-6 → report[1..7]
      expect(reports[0][1], 0xFE); // header[0]
      expect(reports[0][2], 0xFD); // header[1]
      expect(reports[0][3], 0xFE); // header[2]
    });

    test('data spans reports correctly', () {
      // Verify we can reconstruct the full payload from reports
      final update = DisplayUpdate(
        axis1: -1234.5678,
        axis2: 500.0,
        axis3: -0.5,
        feedRate: 1000,
        spindleSpeed: 12000,
        mode: MotionMode.step,
        coordinateSpace: CoordinateSpace.workpiece,
      );
      final payload = encodeDisplayPayload(update);
      final reports = encodeDisplayUpdate(update);

      // Reconstruct payload from reports
      final reconstructed = <int>[];
      for (final report in reports) {
        reconstructed.addAll(report.sublist(1)); // skip report ID
      }

      // First 24 bytes should match the payload
      for (var i = 0; i < 24; i++) {
        expect(reconstructed[i], payload[i],
            reason: 'Mismatch at payload byte $i');
      }
    });
  });
}
