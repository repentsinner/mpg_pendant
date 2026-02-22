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

  MockHidBackend({
    this.devices = const [],
    this.readQueue = const [],
    this.readException,
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

void main() {
  group('PendantDiscovery', () {
    test('finds devices matching VID/PID', () {
      final backend = MockHidBackend(devices: [
        const HidDeviceInfo(
          vendorId: pendantVendorId,
          productId: pendantProductId,
          path: '/dev/hidraw0',
        ),
        const HidDeviceInfo(
          vendorId: 0x1234,
          productId: 0x5678,
          path: '/dev/hidraw1',
        ),
      ]);

      final discovery = PendantDiscovery(backend);
      final pendants = discovery.findPendants();
      expect(pendants.length, 1);
      expect(pendants[0].path, '/dev/hidraw0');
    });

    test('returns empty list when no pendants connected', () {
      final backend = MockHidBackend(devices: []);
      final discovery = PendantDiscovery(backend);
      expect(discovery.findPendants(), isEmpty);
    });

    test('returns multiple pendants when connected', () {
      final backend = MockHidBackend(devices: [
        const HidDeviceInfo(
          vendorId: pendantVendorId,
          productId: pendantProductId,
          path: '/dev/hidraw0',
        ),
        const HidDeviceInfo(
          vendorId: pendantVendorId,
          productId: pendantProductId,
          path: '/dev/hidraw1',
        ),
      ]);

      final discovery = PendantDiscovery(backend);
      expect(discovery.findPendants().length, 2);
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
        readQueue: [
          _packet(key1: 0x03, axis: 0x12, jog: 5),
        ],
      );

      final conn = PendantConnection(
        backend,
        backend.devices.first,
      );

      final stream = conn.open();
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

      final conn = PendantConnection(backend, backend.devices.first);
      final stream = conn.open();

      await expectLater(stream, emitsError(isA<Exception>()));
    });

    test('sends display update as 4 feature reports', () {
      final backend = MockHidBackend(
        devices: [
          const HidDeviceInfo(
            vendorId: pendantVendorId,
            productId: pendantProductId,
            path: '/dev/hidraw0',
          ),
        ],
      );

      final conn = PendantConnection(backend, backend.devices.first);
      conn.open();
      conn.updateDisplay(const DisplayUpdate(axis1: 100.0));

      expect(backend.sentFeatureReports.length, 4);
      for (final report in backend.sentFeatureReports) {
        expect(report.length, 8);
        expect(report[0], 0x06);
      }

      conn.close();
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

      final conn = PendantConnection(backend, backend.devices.first);
      expect(
        () => conn.updateDisplay(const DisplayUpdate()),
        throwsA(isA<StateError>()),
      );
    });

    test('sendResetSequence sends two display updates', () {
      final backend = MockHidBackend(
        devices: [
          const HidDeviceInfo(
            vendorId: pendantVendorId,
            productId: pendantProductId,
            path: '/dev/hidraw0',
          ),
        ],
      );

      final conn = PendantConnection(backend, backend.devices.first);
      conn.open();
      conn.sendResetSequence();

      // 2 updates × 4 reports each = 8 feature reports
      expect(backend.sentFeatureReports.length, 8);

      // First update should have reset flag (bit 6) set
      // Report 1, byte 4 (payload offset 3) is the flags byte
      // Report 1 data: [0x06, 0xFE, 0xFD, 0xFE, flags, ...]
      expect(backend.sentFeatureReports[0][4] & 0x40, 0x40);

      // Second update should have reset flag cleared
      expect(backend.sentFeatureReports[4][4] & 0x40, 0x00);

      conn.close();
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

      final conn = PendantConnection(backend, backend.devices.first);
      final stream = conn.open();
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

      final conn = PendantConnection(backend, backend.devices.first);
      final stream = conn.open();
      final state = await stream.first;

      expect(state.axis, PendantAxis.c);
      await conn.close();
    });
  });
}
