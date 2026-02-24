/// Combined CLI example: discovers a pendant, monitors input events in a
/// fixed-position terminal box, and drives display updates at 125 Hz to
/// test throughput. All three axes increment continuously so you can see
/// the LCD refresh rate.
///
/// The ANSI display includes a 4-line LCD mockup matching the physical
/// WHB04B layout, plus a hex dump of the protocol payload for debugging.
///
/// Known issue: feed rate and spindle speed values are encoded correctly
/// (verified against LinuxCNC, Candle, and pedropaulovc/whb04b-6
/// implementations) but display as 0 on some hardware revisions. The
/// protocol bytes are non-zero on the wire; the device firmware ignores
/// them. Axis coordinates and mode flags work fine on the same units.
///
/// Uses raw ANSI escapes — no dart_console dependency.
///
/// Usage: dart run example/example.dart
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

const _w = 60; // inner content width

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
String _hex2(int v) => v.toRadixString(16).toUpperCase().padLeft(2, '0');

// ── Jog selector labels ──────────────────────────────────────────────────────

const _stepLabels = {
  JogSelector.position0: '0.001',
  JogSelector.position1: ' 0.01',
  JogSelector.position2: '  0.1',
  JogSelector.position3: '  1.0',
  JogSelector.position4: '  1.0',
  JogSelector.position5: '  1.0',
  JogSelector.position6: ' Lead',
};

const _continuousLabels = {
  JogSelector.position0: '   2%',
  JogSelector.position1: '   5%',
  JogSelector.position2: '  10%',
  JogSelector.position3: '  30%',
  JogSelector.position4: '  60%',
  JogSelector.position5: ' 100%',
  JogSelector.position6: ' Lead',
};

// ── LCD line-1 display modes ─────────────────────────────────────────────────

/// The WHB04B LCD line 1 shows one value at a time. The mode switches
/// based on the last relevant button press or the jog selector.
enum _Line1Mode { step, continuous, feed, spindle }

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
    jogSelector: JogSelector.position0,
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
  var axis2Value = 0.0;
  var axis3Value = 0.0;
  var feedRate = 0;
  var spindleSpeed = 0;
  var line1Mode = _Line1Mode.step;
  DisplayUpdate? lastSentUpdate;

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

    final axisBuf = StringBuffer(' Axis:   ');
    for (final a in PendantAxis.values) {
      final label = a.name.toUpperCase();
      if (lastState.axis == a) {
        axisBuf.write('[$label]');
      } else {
        axisBuf.write(' $label ');
      }
    }
    lines.add(_pad(axisBuf.toString()));

    final jogLabels = conn.motionMode == MotionMode.step
        ? _stepLabels
        : _continuousLabels;
    final jogBuf = StringBuffer(' Jog:    ');
    for (final e in jogLabels.entries) {
      if (lastState.jogSelector == e.key) {
        jogBuf.write('[${e.value}]');
      } else {
        jogBuf.write(' ${e.value} ');
      }
    }
    lines.add(_pad(jogBuf.toString()));

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

    // -- LCD mockup (4 lines matching WHB04B physical display) --
    lines.add(_pad(' -- LCD Output --'));
    final String line1;
    switch (line1Mode) {
      case _Line1Mode.feed:
        line1 = 'F:$feedRate';
      case _Line1Mode.spindle:
        line1 = 'S:$spindleSpeed';
      case _Line1Mode.step:
        final sv = lastState.jogSelector.stepValue;
        line1 = sv != null ? 'STP:${sv.toStringAsFixed(3)}' : 'STP:Lead';
      case _Line1Mode.continuous:
        final cp = lastState.jogSelector.continuousPercent;
        line1 = cp != null ? 'CON:$cp%' : 'CON:Lead';
    }
    lines.add(_pad('   $line1'));

    final abcGroup = const {PendantAxis.a, PendantAxis.b, PendantAxis.c};
    final useAbc = abcGroup.contains(lastState.axis);
    final labels = useAbc ? ['A', 'B', 'C'] : ['X', 'Y', 'Z'];
    final axes = useAbc
        ? [PendantAxis.a, PendantAxis.b, PendantAxis.c]
        : [PendantAxis.x, PendantAxis.y, PendantAxis.z];
    final values = [axis1Value, axis2Value, axis3Value];
    for (var i = 0; i < 3; i++) {
      final marker = lastState.axis == axes[i] ? '*' : ' ';
      final coord = values[i].toStringAsFixed(4).padLeft(12);
      lines.add(_pad('  $marker${labels[i]}1: $coord'));
    }
    // -- Protocol hex dump (21-byte display payload) --
    if (lastSentUpdate != null) {
      final p = encodeDisplayPayload(
        DisplayUpdate(
          axis1: lastSentUpdate!.axis1,
          axis2: lastSentUpdate!.axis2,
          axis3: lastSentUpdate!.axis3,
          feedRate: lastSentUpdate!.feedRate,
          spindleSpeed: lastSentUpdate!.spindleSpeed,
          mode: conn.motionMode,
          resetFlag: lastSentUpdate!.resetFlag,
          coordinateSpace: lastSentUpdate!.coordinateSpace,
        ),
      );
      String h(int i) => _hex2(p[i]);
      lines.add(
        _pad(
          '  hdr: ${h(0)} ${h(1)} ${h(2)}'
          '  flags: ${h(3)}',
        ),
      );
      lines.add(
        _pad(
          '  ax1: ${h(4)} ${h(5)} ${h(6)} ${h(7)}'
          '  ax2: ${h(8)} ${h(9)} ${h(10)} ${h(11)}',
        ),
      );
      lines.add(
        _pad(
          '  ax3: ${h(12)} ${h(13)} ${h(14)} ${h(15)}'
          '  feed: ${h(16)} ${h(17)}'
          '  spin: ${h(18)} ${h(19)}',
        ),
      );
    } else {
      lines.add(_pad('  (no payload yet)'));
      lines.add(_pad(''));
      lines.add(_pad(''));
    }
    lines.add(_pad(''));

    // -- Stats --
    lines.add(_pad(' Input:   $inputPackets pkts  $inputPps/s'));
    lines.add(
      _pad(
        ' Display: $displayWindowCount sent  $displayUps/s  tick $displayTick',
      ),
    );
    final r = pendant.readDevice;
    final w = pendant.writeDevice;
    lines.add(
      _pad(
        ' Read:  VID:${r.vendorId.toRadixString(16).toUpperCase().padLeft(4, '0')}'
        ' PID:${r.productId.toRadixString(16).toUpperCase().padLeft(4, '0')}'
        ' page:${_hex(r.usagePage)} usage:${_hex(r.usage)}'
        ' iface:${r.interfaceNumber}',
      ),
    );
    lines.add(
      _pad(
        ' Write: VID:${w.vendorId.toRadixString(16).toUpperCase().padLeft(4, '0')}'
        ' PID:${w.productId.toRadixString(16).toUpperCase().padLeft(4, '0')}'
        ' page:${_hex(w.usagePage)} usage:${_hex(w.usage)}'
        ' iface:${w.interfaceNumber}',
      ),
    );
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
    axis2Value += 0.002;
    if (axis2Value > 9999.0) axis2Value = 0.0;
    axis3Value += 0.003;
    if (axis3Value > 9999.0) axis3Value = 0.0;
    final update = DisplayUpdate(
      axis1: axis1Value,
      axis2: axis2Value,
      axis3: axis3Value,
      feedRate: feedRate,
      spindleSpeed: spindleSpeed,
      coordinateSpace: CoordinateSpace.workpiece,
    );
    lastSentUpdate = update;
    if (conn.isOpen) conn.updateDisplay(update);
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

      // Handle feed/spindle buttons.
      for (final btn in [state.button1, state.button2]) {
        switch (btn) {
          case PendantButton.feedPlus:
            feedRate = (feedRate + 100).clamp(0, 99999);
            line1Mode = _Line1Mode.feed;
          case PendantButton.feedMinus:
            feedRate = (feedRate - 100).clamp(0, 99999);
            line1Mode = _Line1Mode.feed;
          case PendantButton.spindlePlus:
            spindleSpeed = (spindleSpeed + 1000).clamp(0, 99999);
            line1Mode = _Line1Mode.spindle;
          case PendantButton.spindleMinus:
            spindleSpeed = (spindleSpeed - 1000).clamp(0, 99999);
            line1Mode = _Line1Mode.spindle;
          case PendantButton.step:
            line1Mode = _Line1Mode.step;
          case PendantButton.continuous:
            line1Mode = _Line1Mode.continuous;
          default:
            break;
        }
      }

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
