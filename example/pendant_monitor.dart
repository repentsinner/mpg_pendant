/// Simple CLI example that discovers a pendant, connects, and prints events.
///
/// Usage: dart run example/pendant_monitor.dart
library;

import 'dart:io';

import 'package:mpg_pendant/mpg_pendant.dart';

void main() async {
  final backend = HidapiBackend();
  final discovery = PendantDiscovery(backend);

  print('Searching for WHB04B pendant...');
  final pendants = discovery.findPendants();

  if (pendants.isEmpty) {
    print('No pendant found. Is the USB dongle connected?');
    exit(1);
  }

  print('Found ${pendants.length} pendant(s):');
  for (final p in pendants) {
    print('  $p');
  }

  final conn = PendantConnection(backend, pendants.first);
  print('\nConnecting to ${pendants.first.path}...');

  final stream = conn.open();
  print('Connected. Sending display reset...');
  conn.sendResetSequence();

  // Send some test coordinates to the display.
  conn.updateDisplay(const DisplayUpdate(
    axis1: 0.0,
    axis2: 0.0,
    axis3: 0.0,
    feedRate: 1000,
    spindleSpeed: 0,
    mode: MotionMode.step,
    coordinateSpace: CoordinateSpace.workpiece,
  ));

  print('Listening for events (Ctrl+C to quit):\n');

  await for (final state in stream) {
    // Only print when something interesting happens.
    if (state.button1 != PendantButton.none || state.jogDelta != 0) {
      final parts = <String>[];
      if (state.button1 != PendantButton.none) {
        parts.add('btn1: ${state.button1.name}');
      }
      if (state.button2 != PendantButton.none) {
        parts.add('btn2: ${state.button2.name}');
      }
      if (state.jogDelta != 0) {
        parts.add('jog: ${state.jogDelta > 0 ? "+${state.jogDelta}" : "${state.jogDelta}"}');
      }
      parts.add('axis: ${state.axis.name}');
      parts.add('feed: ${state.feed.name}');
      print(parts.join(' | '));
    }
  }

  print('\nDisconnected.');
}
