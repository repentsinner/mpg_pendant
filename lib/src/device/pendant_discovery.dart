import '../protocol/constants.dart';
import '../protocol/display_encoder.dart';
import '../protocol/models.dart';
import 'hid_backend.dart';

/// A discovered pendant with separate read and write device paths.
///
/// On Linux/macOS a single HID interface handles both input reports and
/// feature reports, so [readDevice] and [writeDevice] will be the same.
/// On Windows the device enumerates as multiple HID collections —
/// one for input and one for feature reports — so they may differ.
class PendantDeviceInfo {
  const PendantDeviceInfo({required this.readDevice, required this.writeDevice});

  /// Device for reading input reports (buttons, jog wheel, selectors).
  final HidDeviceInfo readDevice;

  /// Device for writing feature reports (display updates).
  final HidDeviceInfo writeDevice;
}

/// Discovers connected WHB04B pendant dongles.
class PendantDiscovery {
  PendantDiscovery(this._backend);

  final HidBackend _backend;

  /// Returns all connected pendant dongles matching the XHC VID/PID.
  ///
  /// On platforms where [HidDeviceInfo.interfaceNumber] is meaningful
  /// (Linux, macOS), filters by [pendantInterfaceNumber] and returns
  /// the single interface for both reads and writes.
  ///
  /// On Windows, hidapi reports all collections as interface 0, so we
  /// probe each candidate to determine which supports feature reports
  /// (display writes) vs input reads.
  List<PendantDeviceInfo> findPendants() {
    final candidates = _backend.enumerate(pendantVendorId, pendantProductId);
    if (candidates.isEmpty) return [];

    // If interface numbers are distinct, filter by them (Linux/macOS).
    final interfaces = candidates.map((d) => d.interfaceNumber).toSet();
    if (interfaces.length > 1) {
      return candidates
          .where((d) => d.interfaceNumber == pendantInterfaceNumber)
          .map((d) => PendantDeviceInfo(readDevice: d, writeDevice: d))
          .toList();
    }

    // Single candidate — assume it handles both.
    if (candidates.length == 1) {
      return [
        PendantDeviceInfo(
          readDevice: candidates.first,
          writeDevice: candidates.first,
        ),
      ];
    }

    // Multiple candidates with same interface (Windows collections).
    // Probe to find which supports feature reports.
    return _probeAndPair(candidates);
  }

  /// Probes each candidate with a feature report write to separate
  /// the write-capable collection from the read-capable one.
  List<PendantDeviceInfo> _probeAndPair(List<HidDeviceInfo> candidates) {
    final probe = encodeDisplayUpdate(const DisplayUpdate());
    HidDeviceInfo? writeDevice;
    final readCandidates = <HidDeviceInfo>[];

    for (final device in candidates) {
      HidDeviceHandle? handle;
      try {
        handle = _backend.open(device.path);
        _backend.sendFeatureReport(handle, probe.first);
        writeDevice = device;
      } on HidException {
        // Can't write feature reports — this is a read collection.
        readCandidates.add(device);
      } finally {
        if (handle != null) {
          try {
            _backend.close(handle);
          } catch (_) {}
        }
      }
    }

    if (writeDevice == null || readCandidates.isEmpty) {
      // Can't determine roles; fall back to first candidate for both.
      return [
        PendantDeviceInfo(
          readDevice: candidates.first,
          writeDevice: candidates.first,
        ),
      ];
    }

    // Pair the first readable collection with the writable one.
    return [
      PendantDeviceInfo(
        readDevice: readCandidates.first,
        writeDevice: writeDevice,
      ),
    ];
  }
}
