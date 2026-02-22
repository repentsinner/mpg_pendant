import 'dart:typed_data';

import 'package:mpg_pendant/mpg_pendant.dart';
import 'package:test/test.dart';

/// Helper to build an 8-byte input packet.
Uint8List packet({
  int header = 0x04,
  int seed = 0x00,
  int key1 = 0x00,
  int key2 = 0x00,
  int feed = 0x0D,
  int axis = 0x11,
  int jog = 0x00,
  int checksum = 0x00,
}) {
  return Uint8List.fromList([header, seed, key1, key2, feed, axis, jog, checksum]);
}

void main() {
  group('Input packet decoding', () {
    test('decodes idle packet with no buttons pressed', () {
      final state = decodeInputPacket(packet());
      expect(state, isNotNull);
      expect(state!.button1, PendantButton.none);
      expect(state.button2, PendantButton.none);
      expect(state.axis, PendantAxis.x);
      expect(state.jogDelta, 0);
    });

    test('returns null for short packet', () {
      expect(decodeInputPacket(Uint8List.fromList([0x04, 0x00])), isNull);
    });

    test('returns null for wrong header', () {
      expect(decodeInputPacket(packet(header: 0x05)), isNull);
    });

    group('button codes', () {
      final buttonTests = <int, PendantButton>{
        0x01: PendantButton.reset,
        0x02: PendantButton.stop,
        0x03: PendantButton.startPause,
        0x04: PendantButton.feedPlus,
        0x05: PendantButton.feedMinus,
        0x06: PendantButton.spindlePlus,
        0x07: PendantButton.spindleMinus,
        0x08: PendantButton.mHome,
        0x09: PendantButton.safeZ,
        0x0A: PendantButton.wHome,
        0x0B: PendantButton.spindleOnOff,
        0x0C: PendantButton.fn,
        0x0D: PendantButton.probeZ,
        0x0E: PendantButton.continuous,
        0x0F: PendantButton.step,
        0x10: PendantButton.macro10,
      };

      for (final entry in buttonTests.entries) {
        test('code 0x${entry.key.toRadixString(16)} → ${entry.value.name}', () {
          final state = decodeInputPacket(packet(key1: entry.key));
          expect(state!.button1, entry.value);
        });
      }

      test('unknown button code maps to none', () {
        final state = decodeInputPacket(packet(key1: 0xFF));
        expect(state!.button1, PendantButton.none);
      });
    });

    group('Fn modifier combos', () {
      test('Fn + Reset reports both keys', () {
        final state = decodeInputPacket(packet(key1: 0x0C, key2: 0x01));
        expect(state!.button1, PendantButton.fn);
        expect(state.button2, PendantButton.reset);
      });

      test('Fn + macro10 reports both keys', () {
        final state = decodeInputPacket(packet(key1: 0x0C, key2: 0x10));
        expect(state!.button1, PendantButton.fn);
        expect(state.button2, PendantButton.macro10);
      });
    });

    group('two-button press', () {
      test('two non-Fn buttons pressed simultaneously', () {
        final state = decodeInputPacket(packet(key1: 0x01, key2: 0x02));
        expect(state!.button1, PendantButton.reset);
        expect(state.button2, PendantButton.stop);
      });

      test('single button has key2 as none', () {
        final state = decodeInputPacket(packet(key1: 0x03));
        expect(state!.button1, PendantButton.startPause);
        expect(state.button2, PendantButton.none);
      });
    });

    group('axis selector', () {
      final axisTests = <int, PendantAxis>{
        0x06: PendantAxis.off,
        0x11: PendantAxis.x,
        0x12: PendantAxis.y,
        0x13: PendantAxis.z,
        0x14: PendantAxis.a,
        0x15: PendantAxis.b,
        0x16: PendantAxis.c,
      };

      for (final entry in axisTests.entries) {
        test('code 0x${entry.key.toRadixString(16)} → ${entry.value.name}', () {
          final state = decodeInputPacket(packet(axis: entry.key));
          expect(state!.axis, entry.value);
        });
      }

      test('unknown axis code maps to off', () {
        final state = decodeInputPacket(packet(axis: 0xFF));
        expect(state!.axis, PendantAxis.off);
      });
    });

    group('feed/step selector', () {
      final feedTests = <int, FeedSelector>{
        0x0D: FeedSelector.step0001,
        0x0E: FeedSelector.step001,
        0x0F: FeedSelector.step01,
        0x10: FeedSelector.step1,
        0x1A: FeedSelector.step5,
        0x1B: FeedSelector.step10,
        0x1C: FeedSelector.lead,
      };

      for (final entry in feedTests.entries) {
        test('code 0x${entry.key.toRadixString(16)} → ${entry.value.name}', () {
          final state = decodeInputPacket(packet(feed: entry.key));
          expect(state!.feed, entry.value);
        });
      }

      test('alternate lead code 0x9B maps to lead', () {
        final state = decodeInputPacket(packet(feed: 0x9B));
        expect(state!.feed, FeedSelector.lead);
      });

      test('step mode values are correct', () {
        expect(FeedSelector.step0001.stepValue, 0.001);
        expect(FeedSelector.step001.stepValue, 0.01);
        expect(FeedSelector.step01.stepValue, 0.1);
        expect(FeedSelector.step1.stepValue, 1.0);
        expect(FeedSelector.step5.stepValue, 5.0);
        expect(FeedSelector.step10.stepValue, 10.0);
      });

      test('continuous mode percentages are correct', () {
        expect(FeedSelector.step0001.continuousPercent, 2);
        expect(FeedSelector.step001.continuousPercent, 5);
        expect(FeedSelector.step01.continuousPercent, 10);
        expect(FeedSelector.step1.continuousPercent, 30);
        expect(FeedSelector.step5.continuousPercent, 60);
        expect(FeedSelector.step10.continuousPercent, 100);
      });
    });

    group('jog wheel', () {
      test('positive delta (clockwise)', () {
        final state = decodeInputPacket(packet(jog: 3));
        expect(state!.jogDelta, 3);
      });

      test('negative delta (counter-clockwise)', () {
        // -5 as unsigned byte = 251
        final state = decodeInputPacket(packet(jog: 251));
        expect(state!.jogDelta, -5);
      });

      test('zero delta (stationary)', () {
        final state = decodeInputPacket(packet(jog: 0));
        expect(state!.jogDelta, 0);
      });

      test('maximum positive delta (+127)', () {
        final state = decodeInputPacket(packet(jog: 127));
        expect(state!.jogDelta, 127);
      });

      test('maximum negative delta (-128)', () {
        // -128 as unsigned byte = 128
        final state = decodeInputPacket(packet(jog: 128));
        expect(state!.jogDelta, -128);
      });

      test('single tick clockwise (+1)', () {
        final state = decodeInputPacket(packet(jog: 1));
        expect(state!.jogDelta, 1);
      });

      test('single tick counter-clockwise (-1)', () {
        // -1 as unsigned byte = 255
        final state = decodeInputPacket(packet(jog: 255));
        expect(state!.jogDelta, -1);
      });

      test('axis OFF suppresses jog delta', () {
        final state = decodeInputPacket(packet(axis: 0x06, jog: 10));
        expect(state!.axis, PendantAxis.off);
        expect(state.jogDelta, 0);
      });

      test('axis OFF suppresses negative jog delta', () {
        final state = decodeInputPacket(packet(axis: 0x06, jog: 250));
        expect(state!.axis, PendantAxis.off);
        expect(state.jogDelta, 0);
      });
    });
  });
}
