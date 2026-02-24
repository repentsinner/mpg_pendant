import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../protocol/constants.dart';
import '../protocol/display_encoder.dart';
import '../protocol/input_packet.dart';
import '../protocol/models.dart';
import 'hid_backend.dart';
import 'hid_worker.dart';
import 'hidapi_hid_backend.dart';
import 'isolate_messages.dart';
import 'pendant_discovery.dart';

/// Manages a connection to a single WHB04B pendant.
///
/// Provides a stream of decoded [PendantState] events and methods
/// to send display updates.
///
/// Production path: [PendantConnection.new] spawns a worker isolate
/// that owns all HID I/O, polling with a short timeout (~2ms) to
/// reach the USB interrupt endpoint's native delivery rate.
///
/// Test path: [PendantConnection.withBackend] runs synchronously on
/// the main isolate using an injected [HidBackend].
class PendantConnection {
  /// Production constructor — spawns a worker isolate for HID I/O.
  PendantConnection(this._pendant, {this.fnInverted = true})
      : _backend = null,
        _useIsolate = true;

  /// Test constructor — runs HID I/O synchronously on the main isolate.
  PendantConnection.withBackend(
    HidBackend backend,
    this._pendant, {
    this.fnInverted = true,
  })  : _backend = backend,
        _useIsolate = false;

  final HidBackend? _backend;
  final PendantDeviceInfo _pendant;
  final bool _useIsolate;

  /// When true (default), dual-label buttons report their function name
  /// (feedPlus, mHome, etc.) without Fn, and their macro name (macro1-9)
  /// with Fn held. When false, the mapping is reversed.
  final bool fnInverted;

  /// Current motion mode, updated when continuous/step buttons are pressed.
  /// Can also be set programmatically.
  MotionMode motionMode = MotionMode.continuous;

  DisplayUpdate? _lastDisplayUpdate;
  StreamController<PendantState>? _controller;

  // Sync path fields.
  HidDeviceHandle? _readHandle;
  HidDeviceHandle? _writeHandle;
  bool _reading = false;

  // Isolate path fields.
  Isolate? _isolate;
  SendPort? _commandPort;
  ReceivePort? _eventPort;
  Completer<void>? _stoppedCompleter;

  // Main-isolate write handle (used when _useIsolate is true).
  HidapiHidBackend? _writeBackend;
  HidDeviceHandle? _isolateWriteHandle;

  /// Whether the connection is currently open.
  bool get isOpen => _useIsolate ? _isolate != null : _readHandle != null;

  /// Opens the connection and starts reading input reports.
  ///
  /// Returns a future that completes with a stream of decoded pendant
  /// state updates once the connection is established.
  Future<Stream<PendantState>> open() async {
    if (isOpen) {
      throw StateError('Connection already open');
    }

    _controller = StreamController<PendantState>(
      onCancel: () => close(),
    );

    if (_useIsolate) {
      await _openIsolate();
    } else {
      _openSync();
    }

    return _controller!.stream;
  }

  // ── Isolate path ────────────────────────────────────────────────────────

  Future<void> _openIsolate() async {
    _eventPort = ReceivePort();
    _stoppedCompleter = Completer<void>();

    final readyCompleter = Completer<SendPort>();

    _eventPort!.listen((message) {
      if (message is WorkerReady) {
        readyCompleter.complete(message.commandPort);
      } else if (message is InputPacketEvent) {
        _handleInputPacket(message.data);
      } else if (message is WorkerError) {
        if (_controller != null && !_controller!.isClosed) {
          _controller!.addError(Exception(message.message));
        }
      } else if (message is WorkerStopped) {
        _eventPort?.close();
        if (!_stoppedCompleter!.isCompleted) {
          _stoppedCompleter!.complete();
        }
      }
    });

    // Open write handle on the main isolate so display writes don't
    // contend with the worker's read loop.
    _writeBackend = HidapiHidBackend();
    _isolateWriteHandle = _writeBackend!.open(_pendant.writeDevice.path);

    final startup = WorkerStartup(
      sendPort: _eventPort!.sendPort,
      readDevicePath: _pendant.readDevice.path,
    );

    _isolate = await Isolate.spawn(hidWorkerEntryPoint, startup);
    _commandPort = await readyCompleter.future;
  }

  // ── Sync path (tests) ──────────────────────────────────────────────────

  void _openSync() {
    final backend = _backend!;
    _readHandle = backend.open(_pendant.readDevice.path);
    if (_pendant.writeDevice.path != _pendant.readDevice.path) {
      _writeHandle = backend.open(_pendant.writeDevice.path);
    } else {
      _writeHandle = _readHandle;
    }
    _startReadingSync();
  }

  void _startReadingSync() {
    _reading = true;
    Future(() async {
      while (_reading && _readHandle != null) {
        try {
          final data = _backend!.read(
            _readHandle!,
            inputPacketLength,
            timeout: const Duration(milliseconds: 100),
          );
          if (data.isNotEmpty) {
            _handleInputPacket(data);
          }
          await Future<void>.delayed(Duration.zero);
        } catch (e) {
          if (_controller != null && !_controller!.isClosed) {
            _controller!.addError(e);
            _controller!.close();
          }
          _reading = false;
          _cleanupSync();
          return;
        }
      }
    });
  }

  // ── Shared packet handling ─────────────────────────────────────────────

  void _handleInputPacket(Uint8List data) {
    final raw = decodeInputPacket(data);
    if (raw != null && _controller != null && !_controller!.isClosed) {
      final state = _interpretButtons(raw);
      _trackMotionMode(state);
      _controller!.add(state);
    }
  }

  /// Sends a display update to the pendant.
  ///
  /// The [MotionMode] in [update] is ignored; the tracked [motionMode]
  /// (set by continuous/step button presses) is used instead.
  void updateDisplay(DisplayUpdate update) {
    if (!isOpen) {
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

    if (_useIsolate) {
      final handle = _isolateWriteHandle!;
      for (final report in reports) {
        _writeBackend!.sendFeatureReport(handle, report);
      }
    } else {
      final handle = _writeHandle!;
      for (final report in reports) {
        _backend!.sendFeatureReport(handle, report);
      }
    }
  }

  /// Sends the display initialization reset sequence.
  void sendResetSequence() {
    updateDisplay(const DisplayUpdate(resetFlag: true));
    updateDisplay(const DisplayUpdate(resetFlag: false));
  }

  /// Closes the connection and releases resources.
  Future<void> close() async {
    if (_useIsolate) {
      await _closeIsolate();
    } else {
      _closeSync();
    }
    if (_controller != null && !_controller!.isClosed) {
      if (_controller!.hasListener) {
        await _controller!.close();
      } else {
        _controller!.close();
      }
    }
    _controller = null;
  }

  // ── Isolate cleanup ────────────────────────────────────────────────────

  Future<void> _closeIsolate() async {
    // Mark closed immediately so concurrent callers (e.g. display timer)
    // see isOpen == false and stop writing.
    final isolate = _isolate;
    _isolate = null;

    // Close the main-isolate write handle while the hidapi library is
    // still alive. The worker's cleanup calls hidExit(), which tears
    // down global state — any handle use after that segfaults.
    if (_isolateWriteHandle != null) {
      try {
        _writeBackend?.close(_isolateWriteHandle!);
      } catch (_) {}
      _isolateWriteHandle = null;
    }
    // Don't dispose _writeBackend (which calls hidExit) — the worker's
    // cleanup handles library teardown.
    _writeBackend = null;

    if (_commandPort != null) {
      _commandPort!.send(ShutdownCommand());
      // Wait for worker to stop, with timeout.
      await _stoppedCompleter?.future.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {},
      );
    }
    isolate?.kill(priority: Isolate.beforeNextEvent);
    _commandPort = null;
    _eventPort?.close();
    _eventPort = null;
    _stoppedCompleter = null;
  }

  // ── Sync cleanup ───────────────────────────────────────────────────────

  void _closeSync() {
    _reading = false;
    _cleanupSync();
  }

  void _cleanupSync() {
    final readHandle = _readHandle;
    final writeHandle = _writeHandle;
    _readHandle = null;
    _writeHandle = null;
    if (readHandle != null) {
      try {
        _backend!.close(readHandle);
      } catch (_) {}
    }
    if (writeHandle != null && writeHandle != readHandle) {
      try {
        _backend!.close(writeHandle);
      } catch (_) {}
    }
  }

  // ── Button interpretation ──────────────────────────────────────────────

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
  PendantState _interpretButtons(PendantState raw) {
    final hasFn =
        raw.button1 == PendantButton.fn || raw.button2 == PendantButton.fn;
    if (!hasFn) {
      if (fnInverted) {
        return raw;
      }
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

    final partner = raw.button1 == PendantButton.fn
        ? raw.button2
        : raw.button1;

    if (partner == PendantButton.none) {
      return PendantState(
        button1: PendantButton.fn,
        button2: PendantButton.none,
        axis: raw.axis,
        feed: raw.feed,
        jogDelta: raw.jogDelta,
      );
    }

    PendantButton interpreted;
    if (partner.isDualLabel) {
      if (fnInverted) {
        interpreted = partner.macroEquivalent!;
      } else {
        interpreted = partner;
      }
    } else {
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
}
