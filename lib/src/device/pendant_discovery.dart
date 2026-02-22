import '../protocol/constants.dart';
import 'hid_backend.dart';

/// Discovers connected WHB04B pendant dongles.
class PendantDiscovery {
  PendantDiscovery(this._backend);

  final HidBackend _backend;

  /// Returns all connected pendant dongles matching the XHC VID/PID.
  List<HidDeviceInfo> findPendants() {
    return _backend.enumerate(pendantVendorId, pendantProductId);
  }
}
