/// Combined CLI example: discovers a pendant, monitors input events in a
/// fixed-position terminal box, and sweeps display fields through their
/// ranges so you can observe what each protocol field does on the LCD.
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

// ── Sweep definition ─────────────────────────────────────────────────────────

class _Step {
  const _Step(this.label, this.update, {this.mode});
  final String label;
  final DisplayUpdate update;
  final MotionMode? mode;
}

const _base = DisplayUpdate(
  feedRate: 1000,
  spindleSpeed: 12000,
  coordinateSpace: CoordinateSpace.workpiece,
);

DisplayUpdate _with({
  double a1 = 0,
  double a2 = 0,
  double a3 = 0,
  int feed = 1000,
  int spindle = 12000,
  CoordinateSpace cs = CoordinateSpace.workpiece,
  bool reset = false,
}) =>
    DisplayUpdate(
      axis1: a1,
      axis2: a2,
      axis3: a3,
      feedRate: feed,
      spindleSpeed: spindle,
      coordinateSpace: cs,
      resetFlag: reset,
    );

List<_Step> _buildSweep() {
  final s = <_Step>[];
  void add(String l, DisplayUpdate u, {MotionMode? m}) =>
      s.add(_Step(l, u, mode: m));

  for (final v in [-999.0, -100.0, -1.0, 0.0, 0.001, 0.1, 1.0, 100.0, 999.0,
      12345.6789]) {
    add('axis1=$v', _with(a1: v));
  }
  for (final v in [-500.0, 0.0, 0.05, 250.0, 9999.9999]) {
    add('axis2=$v', _with(a2: v));
  }
  for (final v in [-500.0, 0.0, 0.05, 250.0, 9999.9999]) {
    add('axis3=$v', _with(a3: v));
  }
  for (final v in [0, 1, 100, 500, 1000, 5000, 10000, 30000, 65535]) {
    add('feed=$v', _with(feed: v));
  }
  for (final v in [0, 1, 100, 1000, 5000, 12000, 24000, 65535]) {
    add('spindle=$v', _with(spindle: v));
  }
  for (final m in MotionMode.values) {
    add('mode=${m.name}', _base, m: m);
  }
  for (final cs in CoordinateSpace.values) {
    add('space=${cs.name}', _with(cs: cs));
  }
  add('reset=true', _with(reset: true));
  add('reset=false', _with());

  return s;
}

// ── Feed selector labels ─────────────────────────────────────────────────────

const _feedLabel = {
  FeedSelector.step0001: '0.001',
  FeedSelector.step001: ' 0.01',
  FeedSelector.step01: '  0.1',
  FeedSelector.step1: '  1.0',
  FeedSelector.step5: '  5.0',
  FeedSelector.step10: ' 10.0',
  FeedSelector.lead: ' Lead',
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
  final conn = PendantConnection(backend, pendant);
  final stream = conn.open();
  conn.sendResetSequence();

  stdout.write(_hideCursor);

  // Input state.
  var lastState = const PendantState(
    button1: PendantButton.none,
    button2: PendantButton.none,
    axis: PendantAxis.off,
    feed: FeedSelector.step0001,
    jogDelta: 0,
  );
  var cumJog = 0;
  var packets = 0;
  var pps = 0;
  var windowCount = 0;

  // Sweep state.
  final sweep = _buildSweep();
  var si = 0;
  var sweepLabel = '(starting)';
  var sweepUpdate = _base;

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

    final feedBuf = StringBuffer(' Feed:   ');
    for (final e in _feedLabel.entries) {
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
    lines.add(_pad(' -- Display Output -----------------------'));
    lines.add(_pad(' Sweep: $sweepLabel'));
    lines.add(_pad(
      ' Ax1: ${sweepUpdate.axis1.toStringAsFixed(4).padLeft(12)}'
      '  Ax2: ${sweepUpdate.axis2.toStringAsFixed(4).padLeft(12)}',
    ));
    lines.add(_pad(
      ' Ax3: ${sweepUpdate.axis3.toStringAsFixed(4).padLeft(12)}',
    ));
    lines.add(_pad(
      ' Feed: ${sweepUpdate.feedRate.toString().padLeft(5)}'
      '    Spindle: ${sweepUpdate.spindleSpeed.toString().padLeft(5)}',
    ));
    lines.add(_pad(
      ' Mode: ${conn.motionMode.name.padRight(10)}'
      ' Space: ${sweepUpdate.coordinateSpace.name.padRight(9)}'
      ' Rst: ${sweepUpdate.resetFlag}',
    ));
    lines.add(_pad(''));

    // -- Stats --
    lines.add(_pad(' Pkts: $packets  Rate: $pps/s'));
    final path = pendant.readDevice.path;
    final maxP = _w - 8;
    final dp =
        path.length > maxP ? '${path.substring(0, maxP - 2)}..' : path;
    lines.add(_pad(' Path: $dp'));
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

  // Packets-per-second counter.
  Timer.periodic(const Duration(seconds: 1), (_) {
    pps = windowCount;
    windowCount = 0;
  });

  // Sweep timer.
  Timer.periodic(const Duration(milliseconds: 750), (_) {
    final step = sweep[si];
    sweepLabel = '[${si + 1}/${sweep.length}] ${step.label}';
    sweepUpdate = step.update;
    if (step.mode != null) conn.motionMode = step.mode!;
    conn.updateDisplay(step.update);
    si = (si + 1) % sweep.length;
    redraw();
  });

  // Graceful shutdown.
  late StreamSubscription<PendantState> sub;
  var exiting = false;

  Future<void> cleanup() async {
    if (exiting) return;
    exiting = true;
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
      packets++;
      windowCount++;
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
