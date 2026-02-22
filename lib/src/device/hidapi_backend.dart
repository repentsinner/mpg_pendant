import 'dart:typed_data';

import 'package:hid4flutter/hid4flutter.dart' as hid4flutter;

import 'hid_backend.dart';

/// Concrete [HidBackend] implementation using the hid4flutter package.
///
/// This provides cross-platform HID access via hidapi FFI bindings.
/// Note: Feature report support depends on the hid4flutter version;
/// this implementation may need to be extended with direct FFI calls
/// for full feature report support.
class HidapiBackend implements HidBackend {
  final Map<Object, hid4flutter.HidDevice> _openDevices = {};

  @override
  List<HidDeviceInfo> enumerate(int vendorId, int productId) {
    // hid4flutter uses async API; this is a synchronous wrapper
    // that will need to be adapted based on the actual usage pattern.
    // For now, this serves as the integration point.
    throw UnimplementedError(
      'HidapiBackend.enumerate requires async adaptation. '
      'Use PendantDiscovery.findPendantsAsync() instead.',
    );
  }

  @override
  HidDeviceHandle open(String path) {
    throw UnimplementedError(
      'HidapiBackend.open requires async adaptation.',
    );
  }

  @override
  Uint8List read(HidDeviceHandle handle, int length, {Duration? timeout}) {
    throw UnimplementedError(
      'HidapiBackend.read requires async adaptation.',
    );
  }

  @override
  void sendFeatureReport(HidDeviceHandle handle, Uint8List data) {
    throw UnimplementedError(
      'Feature report support pending hid4flutter API extension.',
    );
  }

  @override
  void close(HidDeviceHandle handle) {
    _openDevices.remove(handle.id);
  }
}
