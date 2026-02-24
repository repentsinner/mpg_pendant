/// Combined CLI example: discovers a pendant, monitors input events in a
/// fixed-position terminal box, and drives display updates at 125 Hz to
/// test throughput. Axis 1 increments continuously so you can see the
/// LCD refresh rate.
///
/// Uses raw ANSI escapes — no dart_console dependency.
///
/// Usage: dart run example/pendant_monitor.dart
library;

import 'dart:async';
import 'dart:io';

import 'package:mpg_pendant/mpg_pendant.dart';

// ── ANSI helpers ─────────────────────────────────────────────────────────────

const _esc = '\x1B';
const _hideCursor = '$_esc[?25l';
const _showCursor = '$_esc[?25h';
const _clearLine = '$_esc[2K';

/// Moves cursor up [n] lines.
String _moveUp(int n) => '$_esc[${n}A';

// ── Box drawing (ASCII only for reliable column math) ────────────────────────

const _w = 50; // inner content width

String _pad(String s) {
  final t = s.length > _w ? s.substring(0, _w) : s.padRight(_w);
  return '| $t |';
}

String _rule(String l, String r, [String? title]) {
  if (title != null) {
    return '$l-$title${'-' * (_w - title.length)}-$r';
  }
  return '$l${'-' * (_w + 2)}$r';
}

String _hex(int v) => '0x${v.toRadixString(16).toUpperCase()}';

// ── Feed selector labels ─────────────────────────────────────────────────────

const _stepLabels = {
  FeedSelector.position0: '0.001',
  FeedSelector.position1: ' 0.01',
  FeedSelector.position2: '  0.1',
  FeedSelector.position3: '  1.0',
  FeedSelector.position4: '  1.0',
  FeedSelector.position5: '  1.0',
  FeedSelector.position6: ' Lead',
};

const _continuousLabels = {
  FeedSelector.position0: '   2%',
  FeedSelector.position1: '   5%',
  FeedSelector.position2: '  10%',
  FeedSelector.position3: '  30%',
  FeedSelector.position4: '  60%',
  FeedSelector.position5: ' 100%',
  FeedSelector.position6: ' Lead',
};

// ── Main ─────────────────────────────────────────────────────────────────────

void main() async {
  final backend = HidapiHidBackend();
  final discovery = PendantDiscovery(backend);

  final pendants = discovery.findPendants();
  if (pendants.isEmpty) {
    stderr.writeln('No pendant found. Is the USB dongle connected?');
    exit(1);
  }

  final pendant = pendants.first;
  final conn = PendantConnection(pendant);
  final stream = await conn.open();
  conn.sendResetSequence();

  stdout.write(_hideCursor);

  // Input state.
  var lastState = const PendantState(
    button1: PendantButton.none,
    button2: PendantButton.none,
    axis: PendantAxis.off,
    feed: FeedSelector.position0,
    jogDelta: 0,
  );
  var cumJog = 0;
  var inputPackets = 0;
  var inputPps = 0;
  var inputWindowCount = 0;

  // Display output state.
  var displayTick = 0;
  var displayUps = 0;
  var displayWindowCount = 0;
  var axis1Value = 0.0;

  // Track total lines drawn so we can rewind cursor.
  var lineCount = 0;
  var firstDraw = true;

  void redraw() {
    final lines = <String>[];

    // -- Input section --
    lines.add(_rule('+', '+', ' WHB04B Pendant '));

    final b1 = lastState.button1 == PendantButton.none
        ? ''
        : lastState.button1.name;
    final b2 = lastState.button2 == PendantButton.none
        ? ''
        : lastState.button2.name;
    final btns = [b1, b2].where((s) => s.isNotEmpty).join(' + ');
    lines.add(_pad(' Buttons: ${btns.isEmpty ? '(none)' : btns}'));

    final axisBuf = StringBuffer(' Axis:    ');
    for (final a in PendantAxis.values) {
      final sel = lastState.axis == a ? '*' : '.';
      axisBuf.write('$sel${a.name.toUpperCase()} ');
    }
    lines.add(_pad(axisBuf.toString()));

    final feedLabels = conn.motionMode == MotionMode.step
        ? _stepLabels
        : _continuousLabels;
    final feedBuf = StringBuffer(' Feed:   ');
    for (final e in feedLabels.entries) {
      if (lastState.feed == e.key) {
        feedBuf.write('[${e.value}]');
      } else {
        feedBuf.write(' ${e.value} ');
      }
    }
    lines.add(_pad(feedBuf.toString()));

    String jogStr;
    if (lastState.jogDelta == 0) {
      jogStr = ' 0';
    } else if (lastState.jogDelta > 0) {
      jogStr = '+${lastState.jogDelta}';
    } else {
      jogStr = '${lastState.jogDelta}';
    }
    final cs = cumJog >= 0 ? '+$cumJog' : '$cumJog';
    lines.add(_pad(' Jog:     $jogStr   total: $cs'));
    lines.add(_pad(' Mode:    ${conn.motionMode.name}'));
    lines.add(_pad(''));

    // -- Display output section --
    lines.add(_pad(' -- Display Output (125 Hz target) ------'));
    lines.add(_pad(
      ' Ax1: ${axis1Value.toStringAsFixed(4).padLeft(12)}'
      '  (tick $displayTick)',
    ));
    lines.add(_pad(''));

    // -- Stats --
    lines.add(
      _pad(' Input:   $inputPackets pkts  $inputPps/s'),
    );
    lines.add(
      _pad(' Display: $displayWindowCount sent  $displayUps/s'),
    );
    final r = pendant.readDevice;
    final w = pendant.writeDevice;
    lines.add(_pad(
      ' Read:  VID:${r.vendorId.toRadixString(16).toUpperCase().padLeft(4, '0')}'
      ' PID:${r.productId.toRadixString(16).toUpperCase().padLeft(4, '0')}'
      ' page:${_hex(r.usagePage)} usage:${_hex(r.usage)}'
      ' iface:${r.interfaceNumber}',
    ));
    lines.add(_pad(
      ' Write: VID:${w.vendorId.toRadixString(16).toUpperCase().padLeft(4, '0')}'
      ' PID:${w.productId.toRadixString(16).toUpperCase().padLeft(4, '0')}'
      ' page:${_hex(w.usagePage)} usage:${_hex(w.usage)}'
      ' iface:${w.interfaceNumber}',
    ));
    lines.add(_rule('+', '+'));

    // Rewind cursor if not the first draw.
    if (!firstDraw && lineCount > 0) {
      stdout.write(_moveUp(lineCount));
    }

    // Write each line, clearing remnants.
    for (final l in lines) {
      stdout.write('$_clearLine\r$l\n');
    }

    lineCount = lines.length;
    firstDraw = false;
  }

  // Rates-per-second counter (1 Hz).
  final statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
    inputPps = inputWindowCount;
    inputWindowCount = 0;
    displayUps = displayWindowCount;
    displayWindowCount = 0;
    redraw();
  });

  // Display update at 125 Hz (8 ms interval).
  final displayTimer = Timer.periodic(const Duration(milliseconds: 8), (_) {
    displayTick++;
    displayWindowCount++;
    axis1Value += 0.001;
    if (axis1Value > 9999.0) axis1Value = 0.0;
    conn.updateDisplay(DisplayUpdate(
      axis1: axis1Value,
      feedRate: 1000,
      spindleSpeed: 12000,
      coordinateSpace: CoordinateSpace.workpiece,
    ));
  });

  // Graceful shutdown.
  late StreamSubscription<PendantState> sub;
  var exiting = false;

  Future<void> cleanup() async {
    if (exiting) return;
    exiting = true;
    displayTimer.cancel();
    statsTimer.cancel();
    await sub.cancel();
    await conn.close();
    stdout.write(_showCursor);
  }

  ProcessSignal.sigint.watch().listen((_) async {
    await cleanup();
    exit(0);
  });

  sub = stream.listen(
    (state) {
      inputPackets++;
      inputWindowCount++;
      cumJog += state.jogDelta;
      lastState = state;
      redraw();
    },
    onError: (Object e) async {
      await cleanup();
      stderr.writeln('\nDevice error: $e');
      exit(1);
    },
    onDone: () async {
      await cleanup();
      exit(0);
    },
  );
}
