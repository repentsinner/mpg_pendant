import 'dart:typed_data';

import 'package:mpg_pendant/mpg_pendant.dart';
import 'package:test/test.dart';

/// Mock HID backend for testing without hardware.
class MockHidBackend implements HidBackend {
  final List<HidDeviceInfo> devices;
  final List<Uint8List> readQueue;
  final List<Uint8List> sentFeatureReports = [];
  bool openCalled = false;
  bool closeCalled = false;
  int readIndex = 0;
  Exception? readException;

  /// Paths where [sendFeatureReport] throws [HidException].
  final Set<String> featureReportFailPaths;

  MockHidBackend({
    this.devices = const [],
    this.readQueue = const [],
    this.readException,
    this.featureReportFailPaths = const {},
  });

  @override
  List<HidDeviceInfo> enumerate(int vendorId, int productId) {
    return devices
        .where((d) => d.vendorId == vendorId && d.productId == productId)
        .toList();
  }

  @override
  HidDeviceHandle open(String path) {
    openCalled = true;
    final device = devices.firstWhere(
      (d) => d.path == path,
      orElse: () => throw Exception('Device not found: $path'),
    );
    return HidDeviceHandle(device.path);
  }

  @override
  Uint8List read(HidDeviceHandle handle, int length, {Duration? timeout}) {
    if (readException != null) throw readException!;
    if (readIndex >= readQueue.length) {
      throw Exception('Device disconnected');
    }
    return readQueue[readIndex++];
  }

  @override
  void sendFeatureReport(HidDeviceHandle handle, Uint8List data) {
    if (featureReportFailPaths.contains(handle.id)) {
      throw HidException('HidD_SetFeature: Incorrect function.');
    }
    sentFeatureReports.add(Uint8List.fromList(data));
  }

  @override
  void close(HidDeviceHandle handle) {
    closeCalled = true;
  }
}

Uint8List _packet({
  int key1 = 0x00,
  int key2 = 0x00,
  int feed = 0x0D,
  int axis = 0x11,
  int jog = 0x00,
}) {
  return Uint8List.fromList([0x04, 0x00, key1, key2, feed, axis, jog, 0x00]);
}

/// Helper to create a same-device PendantDeviceInfo (Linux/macOS style).
PendantDeviceInfo _sameDevice(HidDeviceInfo dev) =>
    PendantDeviceInfo(readDevice: dev, writeDevice: dev);

void main() {
  group('PendantDiscovery', () {
    test('finds devices matching VID/PID', () {
      final backend = MockHidBackend(
        devices: [
          const HidDeviceInfo(
            vendorId: pendantVendorId,
            productId: pendantProductId,
            path: '/dev/hidraw0',
            interfaceNumber: 0,
          ),
          const HidDeviceInfo(
            vendorId: 0x1234,
            productId: 0x5678,
            path: '/dev/hidraw1',
            interfaceNumber: 0,
          ),
        ],
      );

      final discovery = PendantDiscovery(backend);
      final pendants = discovery.findPendants();
      expect(pendants.length, 1);
      expect(pendants[0].readDevice.path, '/dev/hidraw0');
    });

    test('returns empty list when no pendants connected', () {
      final backend = MockHidBackend(devices: []);
      final discovery = PendantDiscovery(backend);
      expect(discovery.findPendants(), isEmpty);
    });

    test('filters out devices with wrong interface number', () {
      final backend = MockHidBackend(
        devices: [
          const HidDeviceInfo(
            vendorId: pendantVendorId,
            productId: pendantProductId,
            path: '/dev/hidraw0',
            interfaceNumber: 0,
          ),
          const HidDeviceInfo(
            vendorId: pendantVendorId,
            productId: pendantProductId,
            path: '/dev/hidraw1',
            interfaceNumber: 1,
          ),
        ],
      );

      final discovery = PendantDiscovery(backend);
      final pendants = discovery.findPendants();
      expect(pendants.length, 1);
      expect(pendants[0].readDevice.path, '/dev/hidraw0');
      // Same device for read and write on Linux/macOS.
      expect(pendants[0].writeDevice.path, '/dev/hidraw0');
    });

    test('returns only devices on interface 0', () {
      final backend = MockHidBackend(
        devices: [
          const HidDeviceInfo(
            vendorId: pendantVendorId,
            productId: pendantProductId,
            path: '/dev/hidraw0',
            interfaceNumber: 1,
          ),
          const HidDeviceInfo(
            vendorId: pendantVendorId,
            productId: pendantProductId,
            path: '/dev/hidraw1',
            interfaceNumber: 2,
          ),
        ],
      );

      final discovery = PendantDiscovery(backend);
      expect(discovery.findPendants(), isEmpty);
    });

    test(
      'probes and pairs collections when all interfaces match (Windows)',
      () {
        final backend = MockHidBackend(
          devices: [
            const HidDeviceInfo(
              vendorId: pendantVendorId,
              productId: pendantProductId,
              path: r'\\?\HID#Col01',
              interfaceNumber: 0,
            ),
            const HidDeviceInfo(
              vendorId: pendantVendorId,
              productId: pendantProductId,
              path: r'\\?\HID#Col02',
              interfaceNumber: 0,
            ),
          ],
          featureReportFailPaths: {r'\\?\HID#Col01'},
        );

        final discovery = PendantDiscovery(backend);
        final pendants = discovery.findPendants();
        expect(pendants.length, 1);
        // Col01 should be the read device (feature reports fail there).
        expect(pendants[0].readDevice.path, r'\\?\HID#Col01');
        // Col02 should be the write device (feature reports succeed there).
        expect(pendants[0].writeDevice.path, r'\\?\HID#Col02');
      },
    );

    test('returns single device without probing', () {
      final backend = MockHidBackend(
        devices: [
          const HidDeviceInfo(
            vendorId: pendantVendorId,
            productId: pendantProductId,
            path: '/dev/hidraw0',
            interfaceNumber: 0,
          ),
        ],
      );

      final discovery = PendantDiscovery(backend);
      final pendants = discovery.findPendants();
      expect(pendants.length, 1);
      // open should not have been called (no probing needed)
      expect(backend.openCalled, isFalse);
    });
  });

  group('PendantConnection', () {
    test('opens device and emits decoded state', () async {
      final backend = MockHidBackend(
        devices: [
          const HidDeviceInfo(
            vendorId: pendantVendorId,
            productId: pendantProductId,
            path: '/dev/hidraw0',
          ),
        ],
        readQueue: [_packet(key1: 0x03, axis: 0x12, jog: 5)],
      );

      final conn = PendantConnection.withBackend(
        backend,
        _sameDevice(backend.devices.first),
      );

      final stream = await conn.open();
      final state = await stream.first;

      expect(backend.openCalled, isTrue);
      expect(state.button1, PendantButton.startPause);
      expect(state.axis, PendantAxis.y);
      expect(state.jogDelta, 5);

      await conn.close();
    });

    test('emits error and closes on disconnect', () async {
      final backend = MockHidBackend(
        devices: [
          const HidDeviceInfo(
            vendorId: pendantVendorId,
            productId: pendantProductId,
            path: '/dev/hidraw0',
          ),
        ],
        readException: Exception('Device disconnected'),
      );

      final conn = PendantConnection.withBackend(
        backend,
        _sameDevice(backend.devices.first),
      );
      final stream = await conn.open();

      await expectLater(stream, emitsError(isA<Exception>()));
    });

    test('sends display update as 3 feature reports', () async {
      final backend = MockHidBackend(
        devices: [
          const HidDeviceInfo(
            vendorId: pendantVendorId,
            productId: pendantProductId,
            path: '/dev/hidraw0',
          ),
        ],
      );

      final conn = PendantConnection.withBackend(
        backend,
        _sameDevice(backend.devices.first),
      );
      await conn.open();
      conn.updateDisplay(const DisplayUpdate(axis1: 100.0));

      expect(backend.sentFeatureReports.length, 3);
      for (final report in backend.sentFeatureReports) {
        expect(report.length, 8);
        expect(report[0], 0x06);
      }

      await conn.close();
    });

    test('throws when updating display on closed connection', () {
      final backend = MockHidBackend(
        devices: [
          const HidDeviceInfo(
            vendorId: pendantVendorId,
            productId: pendantProductId,
            path: '/dev/hidraw0',
          ),
        ],
      );

      final conn = PendantConnection.withBackend(
        backend,
        _sameDevice(backend.devices.first),
      );
      expect(
        () => conn.updateDisplay(const DisplayUpdate()),
        throwsA(isA<StateError>()),
      );
    });

    test('sendResetSequence sends two display updates', () async {
      final backend = MockHidBackend(
        devices: [
          const HidDeviceInfo(
            vendorId: pendantVendorId,
            productId: pendantProductId,
            path: '/dev/hidraw0',
          ),
        ],
      );

      final conn = PendantConnection.withBackend(
        backend,
        _sameDevice(backend.devices.first),
      );
      await conn.open();
      conn.sendResetSequence();

      // 2 updates × 3 reports each = 6 feature reports
      expect(backend.sentFeatureReports.length, 6);

      // First update should have reset flag (bit 6) set
      expect(backend.sentFeatureReports[0][4] & 0x40, 0x40);

      // Second update should have reset flag cleared
      expect(backend.sentFeatureReports[3][4] & 0x40, 0x00);

      await conn.close();
    });

    test('detects 6-axis variant from axis B code', () async {
      final backend = MockHidBackend(
        devices: [
          const HidDeviceInfo(
            vendorId: pendantVendorId,
            productId: pendantProductId,
            path: '/dev/hidraw0',
          ),
        ],
        readQueue: [
          _packet(axis: 0x15), // B axis
        ],
      );

      final conn = PendantConnection.withBackend(
        backend,
        _sameDevice(backend.devices.first),
      );
      final stream = await conn.open();
      final state = await stream.first;

      expect(state.axis, PendantAxis.b);
      await conn.close();
    });

    test('detects 6-axis variant from axis C code', () async {
      final backend = MockHidBackend(
        devices: [
          const HidDeviceInfo(
            vendorId: pendantVendorId,
            productId: pendantProductId,
            path: '/dev/hidraw0',
          ),
        ],
        readQueue: [
          _packet(axis: 0x16), // C axis
        ],
      );

      final conn = PendantConnection.withBackend(
        backend,
        _sameDevice(backend.devices.first),
      );
      final stream = await conn.open();
      final state = await stream.first;

      expect(state.axis, PendantAxis.c);
      await conn.close();
    });

    group('fnInverted = true (default)', () {
      test('dual-label button alone reports function name', () async {
        final backend = MockHidBackend(
          devices: [
            const HidDeviceInfo(
              vendorId: pendantVendorId,
              productId: pendantProductId,
              path: '/dev/hidraw0',
            ),
          ],
          readQueue: [
            _packet(key1: 0x04), // feedPlus alone
          ],
        );

        final conn = PendantConnection.withBackend(
          backend,
          _sameDevice(backend.devices.first),
        );
        final state = await (await conn.open()).first;
        expect(state.button1, PendantButton.feedPlus);
        expect(state.button2, PendantButton.none);
        await conn.close();
      });

      test('Fn + dual-label button reports macro, Fn stripped', () async {
        final backend = MockHidBackend(
          devices: [
            const HidDeviceInfo(
              vendorId: pendantVendorId,
              productId: pendantProductId,
              path: '/dev/hidraw0',
            ),
          ],
          readQueue: [
            _packet(key1: 0x0C, key2: 0x04), // fn + feedPlus
          ],
        );

        final conn = PendantConnection.withBackend(
          backend,
          _sameDevice(backend.devices.first),
        );
        final state = await (await conn.open()).first;
        expect(state.button1, PendantButton.macro1);
        expect(state.button2, PendantButton.none);
        await conn.close();
      });

      test('Fn alone reports fn', () async {
        final backend = MockHidBackend(
          devices: [
            const HidDeviceInfo(
              vendorId: pendantVendorId,
              productId: pendantProductId,
              path: '/dev/hidraw0',
            ),
          ],
          readQueue: [
            _packet(key1: 0x0C), // fn alone
          ],
        );

        final conn = PendantConnection.withBackend(
          backend,
          _sameDevice(backend.devices.first),
        );
        final state = await (await conn.open()).first;
        expect(state.button1, PendantButton.fn);
        expect(state.button2, PendantButton.none);
        await conn.close();
      });

      test('dedicated button alone unchanged', () async {
        final backend = MockHidBackend(
          devices: [
            const HidDeviceInfo(
              vendorId: pendantVendorId,
              productId: pendantProductId,
              path: '/dev/hidraw0',
            ),
          ],
          readQueue: [
            _packet(key1: 0x01), // reset
          ],
        );

        final conn = PendantConnection.withBackend(
          backend,
          _sameDevice(backend.devices.first),
        );
        final state = await (await conn.open()).first;
        expect(state.button1, PendantButton.reset);
        expect(state.button2, PendantButton.none);
        await conn.close();
      });

      test('Fn + dedicated button strips Fn', () async {
        final backend = MockHidBackend(
          devices: [
            const HidDeviceInfo(
              vendorId: pendantVendorId,
              productId: pendantProductId,
              path: '/dev/hidraw0',
            ),
          ],
          readQueue: [
            _packet(key1: 0x0C, key2: 0x02), // fn + stop
          ],
        );

        final conn = PendantConnection.withBackend(
          backend,
          _sameDevice(backend.devices.first),
        );
        final state = await (await conn.open()).first;
        expect(state.button1, PendantButton.stop);
        expect(state.button2, PendantButton.none);
        await conn.close();
      });

      test('Fn + macro10 strips Fn', () async {
        final backend = MockHidBackend(
          devices: [
            const HidDeviceInfo(
              vendorId: pendantVendorId,
              productId: pendantProductId,
              path: '/dev/hidraw0',
            ),
          ],
          readQueue: [
            _packet(key1: 0x0C, key2: 0x10), // fn + macro10
          ],
        );

        final conn = PendantConnection.withBackend(
          backend,
          _sameDevice(backend.devices.first),
        );
        final state = await (await conn.open()).first;
        expect(state.button1, PendantButton.macro10);
        expect(state.button2, PendantButton.none);
        await conn.close();
      });
    });

    group('fnInverted = false', () {
      test('dual-label button alone reports macro name', () async {
        final backend = MockHidBackend(
          devices: [
            const HidDeviceInfo(
              vendorId: pendantVendorId,
              productId: pendantProductId,
              path: '/dev/hidraw0',
            ),
          ],
          readQueue: [
            _packet(key1: 0x04), // feedPlus alone
          ],
        );

        final conn = PendantConnection.withBackend(
          backend,
          _sameDevice(backend.devices.first),
          fnInverted: false,
        );
        final state = await (await conn.open()).first;
        expect(state.button1, PendantButton.macro1);
        expect(state.button2, PendantButton.none);
        await conn.close();
      });

      test(
        'Fn + dual-label button reports function name, Fn stripped',
        () async {
          final backend = MockHidBackend(
            devices: [
              const HidDeviceInfo(
                vendorId: pendantVendorId,
                productId: pendantProductId,
                path: '/dev/hidraw0',
              ),
            ],
            readQueue: [
              _packet(key1: 0x0C, key2: 0x04), // fn + feedPlus
            ],
          );

          final conn = PendantConnection.withBackend(
            backend,
            _sameDevice(backend.devices.first),
            fnInverted: false,
          );
          final state = await (await conn.open()).first;
          expect(state.button1, PendantButton.feedPlus);
          expect(state.button2, PendantButton.none);
          await conn.close();
        },
      );

      test('Fn + dedicated button strips Fn', () async {
        final backend = MockHidBackend(
          devices: [
            const HidDeviceInfo(
              vendorId: pendantVendorId,
              productId: pendantProductId,
              path: '/dev/hidraw0',
            ),
          ],
          readQueue: [
            _packet(key1: 0x0C, key2: 0x02), // fn + stop
          ],
        );

        final conn = PendantConnection.withBackend(
          backend,
          _sameDevice(backend.devices.first),
          fnInverted: false,
        );
        final state = await (await conn.open()).first;
        expect(state.button1, PendantButton.stop);
        expect(state.button2, PendantButton.none);
        await conn.close();
      });
    });

    group('motion mode tracking', () {
      test('defaults to continuous', () {
        final backend = MockHidBackend(
          devices: [
            const HidDeviceInfo(
              vendorId: pendantVendorId,
              productId: pendantProductId,
              path: '/dev/hidraw0',
            ),
          ],
        );

        final conn = PendantConnection.withBackend(
          backend,
          _sameDevice(backend.devices.first),
        );
        expect(conn.motionMode, MotionMode.continuous);
      });

      test('step button switches mode to step', () async {
        final backend = MockHidBackend(
          devices: [
            const HidDeviceInfo(
              vendorId: pendantVendorId,
              productId: pendantProductId,
              path: '/dev/hidraw0',
            ),
          ],
          readQueue: [
            _packet(key1: 0x0F), // step button
          ],
        );

        final conn = PendantConnection.withBackend(
          backend,
          _sameDevice(backend.devices.first),
        );
        await (await conn.open()).first;
        expect(conn.motionMode, MotionMode.step);
        await conn.close();
      });

      test('continuous button switches mode to continuous', () async {
        final backend = MockHidBackend(
          devices: [
            const HidDeviceInfo(
              vendorId: pendantVendorId,
              productId: pendantProductId,
              path: '/dev/hidraw0',
            ),
          ],
          readQueue: [
            _packet(key1: 0x0F), // step first
            _packet(key1: 0x0E), // then continuous
          ],
        );

        final conn = PendantConnection.withBackend(
          backend,
          _sameDevice(backend.devices.first),
        );
        final states = await (await conn.open()).take(2).toList();
        expect(states[0].button1, PendantButton.step);
        expect(states[1].button1, PendantButton.continuous);
        expect(conn.motionMode, MotionMode.continuous);
        await conn.close();
      });

      test('step button re-sends last display update with step mode', () async {
        final backend = MockHidBackend(
          devices: [
            const HidDeviceInfo(
              vendorId: pendantVendorId,
              productId: pendantProductId,
              path: '/dev/hidraw0',
            ),
          ],
          readQueue: [
            _packet(key1: 0x0F), // step button
          ],
        );

        final conn = PendantConnection.withBackend(
          backend,
          _sameDevice(backend.devices.first),
        );
        final stream = await conn.open();

        // Send initial display update (mode defaults to continuous).
        conn.updateDisplay(const DisplayUpdate(feedRate: 500));
        final initialReportCount = backend.sentFeatureReports.length;
        expect(initialReportCount, 3);

        // Consume the step button press — triggers mode change + re-send.
        await stream.first;

        // Should have sent 3 more feature reports with step mode.
        expect(backend.sentFeatureReports.length, initialReportCount + 3);

        // Verify the re-sent flags byte has step mode (bits 0-1 = 1).
        final resent = backend.sentFeatureReports[initialReportCount];
        // Report format: [0x06, payload[0..6]], flags at payload[3]
        // First report carries payload bytes 0-6, flags is at payload[3] = report[4].
        expect(resent[4] & 0x03, MotionMode.step.value);

        await conn.close();
      });

      test('no re-send when no prior display update', () async {
        final backend = MockHidBackend(
          devices: [
            const HidDeviceInfo(
              vendorId: pendantVendorId,
              productId: pendantProductId,
              path: '/dev/hidraw0',
            ),
          ],
          readQueue: [
            _packet(key1: 0x0F), // step button
          ],
        );

        final conn = PendantConnection.withBackend(
          backend,
          _sameDevice(backend.devices.first),
        );
        await (await conn.open()).first;

        // No display updates should have been sent.
        expect(backend.sentFeatureReports, isEmpty);
        // But mode should still be tracked.
        expect(conn.motionMode, MotionMode.step);
        await conn.close();
      });

      test('motionMode setter updates tracked mode', () async {
        final backend = MockHidBackend(
          devices: [
            const HidDeviceInfo(
              vendorId: pendantVendorId,
              productId: pendantProductId,
              path: '/dev/hidraw0',
            ),
          ],
        );

        final conn = PendantConnection.withBackend(
          backend,
          _sameDevice(backend.devices.first),
        );
        await conn.open();
        conn.motionMode = MotionMode.mpg;
        expect(conn.motionMode, MotionMode.mpg);

        conn.updateDisplay(const DisplayUpdate());

        // Flags byte should reflect mpg (value 2).
        final flags = backend.sentFeatureReports[0][4];
        expect(flags & 0x03, MotionMode.mpg.value);

        await conn.close();
      });

      test('updateDisplay uses tracked motion mode', () async {
        final backend = MockHidBackend(
          devices: [
            const HidDeviceInfo(
              vendorId: pendantVendorId,
              productId: pendantProductId,
              path: '/dev/hidraw0',
            ),
          ],
        );

        final conn = PendantConnection.withBackend(
          backend,
          _sameDevice(backend.devices.first),
        );
        await conn.open();
        // Caller passes step mode, but tracked mode is continuous (default).
        conn.updateDisplay(const DisplayUpdate(mode: MotionMode.step));

        // Flags byte should reflect continuous (tracked), not step (caller).
        final flags = backend.sentFeatureReports[0][4];
        expect(flags & 0x03, MotionMode.continuous.value);

        await conn.close();
      });
    });

    test('uses separate handles for read and write', () async {
      final backend = MockHidBackend(
        devices: [
          const HidDeviceInfo(
            vendorId: pendantVendorId,
            productId: pendantProductId,
            path: r'\\?\HID#Col01',
          ),
          const HidDeviceInfo(
            vendorId: pendantVendorId,
            productId: pendantProductId,
            path: r'\\?\HID#Col02',
          ),
        ],
        featureReportFailPaths: {r'\\?\HID#Col01'},
      );

      final pendant = PendantDeviceInfo(
        readDevice: backend.devices[0],
        writeDevice: backend.devices[1],
      );

      final conn = PendantConnection.withBackend(backend, pendant);
      await conn.open();
      // Write should go to Col02 (not Col01 which would throw).
      conn.updateDisplay(const DisplayUpdate());
      expect(backend.sentFeatureReports.length, 3);

      await conn.close();
    });
  });
}
