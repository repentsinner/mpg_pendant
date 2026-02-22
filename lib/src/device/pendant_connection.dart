import 'dart:async';

import '../protocol/constants.dart';
import '../protocol/display_encoder.dart';
import '../protocol/input_packet.dart';
import '../protocol/models.dart';
import 'hid_backend.dart';
import 'pendant_discovery.dart';

/// Manages a connection to a single WHB04B pendant.
///
/// Provides a stream of decoded [PendantState] events and methods
/// to send display updates.
///
/// On Windows the pendant exposes separate HID collections for input
/// reads and feature report writes, so this class manages two handles
/// when needed.
class PendantConnection {
  PendantConnection(this._backend, this._pendant, {this.fnInverted = true});

  final HidBackend _backend;
  final PendantDeviceInfo _pendant;

  /// When true (default), dual-label buttons report their function name
  /// (feedPlus, mHome, etc.) without Fn, and their macro name (macro1-9)
  /// with Fn held. When false, the mapping is reversed.
  final bool fnInverted;

  /// Current motion mode, updated when continuous/step buttons are pressed.
  /// Can also be set programmatically.
  MotionMode motionMode = MotionMode.continuous;

  DisplayUpdate? _lastDisplayUpdate;
  HidDeviceHandle? _readHandle;
  HidDeviceHandle? _writeHandle;
  StreamController<PendantState>? _controller;
  bool _reading = false;

  /// Whether the connection is currently open.
  bool get isOpen => _readHandle != null;

  /// Opens the connection and starts reading input reports.
  ///
  /// Returns a stream of decoded pendant state updates.
  Stream<PendantState> open() {
    if (_readHandle != null) {
      throw StateError('Connection already open');
    }

    _readHandle = _backend.open(_pendant.readDevice.path);
    if (_pendant.writeDevice.path != _pendant.readDevice.path) {
      _writeHandle = _backend.open(_pendant.writeDevice.path);
    } else {
      _writeHandle = _readHandle;
    }
    _controller = StreamController<PendantState>(
      onCancel: () => close(),
    );
    _startReading();
    return _controller!.stream;
  }

  void _startReading() {
    _reading = true;
    // Run the read loop asynchronously, yielding to the event loop
    // between reads so stream listeners can process events.
    Future(() async {
      while (_reading && _readHandle != null) {
        try {
          final data = _backend.read(
            _readHandle!,
            inputPacketLength,
            timeout: const Duration(milliseconds: 100),
          );
          if (data.isNotEmpty) {
            final raw = decodeInputPacket(data);
            if (raw != null &&
                _controller != null &&
                !_controller!.isClosed) {
              final state = _interpretButtons(raw);
              _trackMotionMode(state);
              _controller!.add(state);
            }
          }
          // Yield to the event loop so stream listeners can fire.
          await Future<void>.delayed(Duration.zero);
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
  ///
  /// The [MotionMode] in [update] is ignored; the tracked [motionMode]
  /// (set by continuous/step button presses) is used instead.
  void updateDisplay(DisplayUpdate update) {
    final handle = _writeHandle;
    if (handle == null) {
      throw StateError('Connection not open');
    }

    _lastDisplayUpdate = update;
    final effective = DisplayUpdate(
      axis1: update.axis1,
      axis2: update.axis2,
      axis3: update.axis3,
      feedRate: update.feedRate,
      spindleSpeed: update.spindleSpeed,
      mode: motionMode,
      resetFlag: update.resetFlag,
      coordinateSpace: update.coordinateSpace,
    );

    final reports = encodeDisplayUpdate(effective);
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

  /// Updates [motionMode] when continuous/step buttons are pressed.
  /// Re-sends the last display update with the new mode if available.
  void _trackMotionMode(PendantState state) {
    MotionMode? newMode;
    if (state.button1 == PendantButton.continuous ||
        state.button2 == PendantButton.continuous) {
      newMode = MotionMode.continuous;
    } else if (state.button1 == PendantButton.step ||
        state.button2 == PendantButton.step) {
      newMode = MotionMode.step;
    }

    if (newMode != null && newMode != motionMode) {
      motionMode = newMode;
      if (_lastDisplayUpdate != null) {
        updateDisplay(_lastDisplayUpdate!);
      }
    }
  }

  /// Interprets raw button state according to [fnInverted] setting.
  ///
  /// Fn is always consumed by the interpretation layer:
  /// - Fn + dual-label → applies inversion, Fn stripped
  /// - Fn + non-dual → Fn stripped, button reported alone
  /// - Fn alone → reported as fn
  PendantState _interpretButtons(PendantState raw) {
    final hasFn =
        raw.button1 == PendantButton.fn || raw.button2 == PendantButton.fn;
    if (!hasFn) {
      // No Fn held.
      if (fnInverted) {
        // Dual-label buttons already have function names — pass through.
        return raw;
      }
      // fnInverted=false: dual-label buttons alone → macro equivalent.
      final b1 = raw.button1.isDualLabel
          ? raw.button1.macroEquivalent!
          : raw.button1;
      final b2 = raw.button2.isDualLabel
          ? raw.button2.macroEquivalent!
          : raw.button2;
      return PendantState(
        button1: b1,
        button2: b2,
        axis: raw.axis,
        feed: raw.feed,
        jogDelta: raw.jogDelta,
      );
    }

    // Fn is held. Find the chord partner (the non-fn button).
    final partner = raw.button1 == PendantButton.fn
        ? raw.button2
        : raw.button1;

    if (partner == PendantButton.none) {
      // Fn alone.
      return PendantState(
        button1: PendantButton.fn,
        button2: PendantButton.none,
        axis: raw.axis,
        feed: raw.feed,
        jogDelta: raw.jogDelta,
      );
    }

    // Fn + some button. Determine the interpreted button.
    PendantButton interpreted;
    if (partner.isDualLabel) {
      if (fnInverted) {
        // Default mode: Fn swaps to macro.
        interpreted = partner.macroEquivalent!;
      } else {
        // Non-inverted: Fn swaps to function name (already the raw name).
        interpreted = partner;
      }
    } else {
      // Non-dual button: just strip Fn.
      interpreted = partner;
    }

    return PendantState(
      button1: interpreted,
      button2: PendantButton.none,
      axis: raw.axis,
      feed: raw.feed,
      jogDelta: raw.jogDelta,
    );
  }

  void _cleanup() {
    final readHandle = _readHandle;
    final writeHandle = _writeHandle;
    _readHandle = null;
    _writeHandle = null;
    if (readHandle != null) {
      try {
        _backend.close(readHandle);
      } catch (_) {
        // Best-effort cleanup.
      }
    }
    if (writeHandle != null && writeHandle != readHandle) {
      try {
        _backend.close(writeHandle);
      } catch (_) {
        // Best-effort cleanup.
      }
    }
  }
}
