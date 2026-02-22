import 'dart:typed_data';

import 'package:hidapi/hidapi.dart' as hidapi;

import 'hid_backend.dart';

/// Concrete [HidBackend] implementation using the hidapi package.
///
/// Delegates to the cross-platform hidapi C library via FFI bindings.
class HidapiHidBackend implements HidBackend {
  HidapiHidBackend() {
    hidapi.hidInit();
  }

  final Map<Object, hidapi.HidDevice> _openDevices = {};

  @override
  List<HidDeviceInfo> enumerate(int vendorId, int productId) {
    return hidapi
        .hidEnumerate(vendorId: vendorId, productId: productId)
        .map(
          (d) => HidDeviceInfo(
            vendorId: d.vendorId,
            productId: d.productId,
            path: d.path,
            manufacturer: d.manufacturer,
            product: d.product,
            serialNumber: d.serialNumber,
            usagePage: d.usagePage,
            usage: d.usage,
            interfaceNumber: d.interfaceNumber,
          ),
        )
        .toList();
  }

  @override
  HidDeviceHandle open(String path) {
    try {
      final dev = hidapi.hidOpenPath(path);
      _openDevices[path] = dev;
      return HidDeviceHandle(path);
    } on hidapi.HidException catch (e) {
      throw HidException(e.message);
    }
  }

  @override
  Uint8List read(HidDeviceHandle handle, int length, {Duration? timeout}) {
    final dev = _openDevices[handle.id];
    if (dev == null) throw HidException('Device not open');
    try {
      return dev.read(length, timeout: timeout);
    } on hidapi.HidException catch (e) {
      throw HidException(e.message);
    }
  }

  @override
  void sendFeatureReport(HidDeviceHandle handle, Uint8List data) {
    final dev = _openDevices[handle.id];
    if (dev == null) throw HidException('Device not open');
    try {
      dev.sendFeatureReport(data);
    } on hidapi.HidException catch (e) {
      throw HidException(e.message);
    }
  }

  @override
  void close(HidDeviceHandle handle) {
    final dev = _openDevices.remove(handle.id);
    dev?.close();
  }

  /// Clean up hidapi library resources.
  void dispose() {
    for (final dev in _openDevices.values) {
      dev.close();
    }
    _openDevices.clear();
    hidapi.hidExit();
  }
}
