import 'dart:typed_data';

/// Information about a discovered HID device.
class HidDeviceInfo {
  const HidDeviceInfo({
    required this.vendorId,
    required this.productId,
    required this.path,
    this.manufacturer = '',
    this.product = '',
    this.serialNumber = '',
  });

  final int vendorId;
  final int productId;
  final String path;
  final String manufacturer;
  final String product;
  final String serialNumber;

  @override
  String toString() =>
      'HidDeviceInfo(vid: 0x${vendorId.toRadixString(16)}, '
      'pid: 0x${productId.toRadixString(16)}, path: $path)';
}

/// Opaque handle to an open HID device.
class HidDeviceHandle {
  const HidDeviceHandle(this.id);

  /// Implementation-specific identifier.
  final Object id;
}

/// Abstract interface for HID operations. Implement this to provide
/// platform-specific HID access, or inject a mock for testing.
abstract class HidBackend {
  /// Enumerate connected HID devices matching the given VID/PID.
  /// Pass 0 for either to match all.
  List<HidDeviceInfo> enumerate(int vendorId, int productId);

  /// Open a device by its path. Throws on failure.
  HidDeviceHandle open(String path);

  /// Read up to [length] bytes from the device. Returns the data read.
  /// Throws on error or disconnect. May return fewer bytes than requested.
  Uint8List read(HidDeviceHandle handle, int length, {Duration? timeout});

  /// Send a feature report to the device.
  void sendFeatureReport(HidDeviceHandle handle, Uint8List data);

  /// Close the device handle and release resources.
  void close(HidDeviceHandle handle);
}
