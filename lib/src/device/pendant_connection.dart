import 'dart:async';

import '../protocol/constants.dart';
import '../protocol/display_encoder.dart';
import '../protocol/input_packet.dart';
import '../protocol/models.dart';
import 'hid_backend.dart';

/// Manages a connection to a single WHB04B pendant.
///
/// Provides a stream of decoded [PendantState] events and methods
/// to send display updates.
class PendantConnection {
  PendantConnection(this._backend, this._deviceInfo);

  final HidBackend _backend;
  final HidDeviceInfo _deviceInfo;
  HidDeviceHandle? _handle;
  StreamController<PendantState>? _controller;
  bool _reading = false;

  /// Whether the connection is currently open.
  bool get isOpen => _handle != null;

  /// Opens the connection and starts reading input reports.
  ///
  /// Returns a stream of decoded pendant state updates.
  Stream<PendantState> open() {
    if (_handle != null) {
      throw StateError('Connection already open');
    }

    _handle = _backend.open(_deviceInfo.path);
    _controller = StreamController<PendantState>(
      onCancel: () => close(),
    );
    _startReading();
    return _controller!.stream;
  }

  void _startReading() {
    _reading = true;
    // Run the read loop asynchronously so it doesn't block.
    Future(() {
      while (_reading && _handle != null) {
        try {
          final data = _backend.read(_handle!, inputPacketLength);
          final state = decodeInputPacket(data);
          if (state != null && _controller != null && !_controller!.isClosed) {
            _controller!.add(state);
          }
        } catch (e) {
          if (_controller != null && !_controller!.isClosed) {
            _controller!.addError(e);
            _controller!.close();
          }
          _reading = false;
          _cleanup();
          return;
        }
      }
    });
  }

  /// Sends a display update to the pendant.
  void updateDisplay(DisplayUpdate update) {
    final handle = _handle;
    if (handle == null) {
      throw StateError('Connection not open');
    }

    final reports = encodeDisplayUpdate(update);
    for (final report in reports) {
      _backend.sendFeatureReport(handle, report);
    }
  }

  /// Sends the display initialization reset sequence.
  void sendResetSequence() {
    updateDisplay(const DisplayUpdate(resetFlag: true));
    updateDisplay(const DisplayUpdate(resetFlag: false));
  }

  /// Closes the connection and releases resources.
  Future<void> close() async {
    _reading = false;
    _cleanup();
    if (_controller != null && !_controller!.isClosed) {
      await _controller!.close();
    }
    _controller = null;
  }

  void _cleanup() {
    final handle = _handle;
    _handle = null;
    if (handle != null) {
      try {
        _backend.close(handle);
      } catch (_) {
        // Best-effort cleanup.
      }
    }
  }
}
