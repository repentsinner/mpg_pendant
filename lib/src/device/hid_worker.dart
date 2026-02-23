import 'dart:isolate';

import '../protocol/constants.dart';
import 'hid_backend.dart';
import 'hidapi_hid_backend.dart';
import 'isolate_messages.dart';

/// Entry point for the HID worker isolate.
///
/// Creates its own [HidapiHidBackend], opens device handles, and runs a
/// tight read loop with a short timeout. All communication with the main
/// isolate happens through [SendPort]/[ReceivePort] using only
/// isolate-safe types.
void hidWorkerEntryPoint(WorkerStartup startup) {
  final mainPort = startup.sendPort;
  HidapiHidBackend? backend;
  HidDeviceHandle? readHandle;
  HidDeviceHandle? writeHandle;

  void cleanup() {
    if (readHandle != null) {
      try {
        backend?.close(readHandle!);
      } catch (_) {}
    }
    if (writeHandle != null && writeHandle != readHandle) {
      try {
        backend?.close(writeHandle!);
      } catch (_) {}
    }
    readHandle = null;
    writeHandle = null;
    backend?.dispose();
    backend = null;
  }

  try {
    backend = HidapiHidBackend();
    readHandle = backend!.open(startup.readDevicePath);
    if (startup.writeDevicePath != startup.readDevicePath) {
      writeHandle = backend!.open(startup.writeDevicePath);
    } else {
      writeHandle = readHandle;
    }
  } catch (e) {
    cleanup();
    mainPort.send(WorkerError('Failed to open devices: $e'));
    mainPort.send(WorkerStopped());
    return;
  }

  final commandPort = ReceivePort();
  mainPort.send(WorkerReady(commandPort.sendPort));

  var running = true;
  final readTimeout = Duration(milliseconds: startup.readTimeoutMs);

  commandPort.listen((message) {
    if (message is ShutdownCommand) {
      running = false;
      commandPort.close();
    } else if (message is WriteDisplayCommand) {
      try {
        for (final report in message.reports) {
          backend!.sendFeatureReport(writeHandle!, report);
        }
      } catch (e) {
        mainPort.send(WorkerError('Display write failed: $e'));
      }
    }
  });

  // Read loop — blocks on hid_read_timeout, then yields to let the
  // command port listener drain pending writes/shutdown before the
  // next read.  The blocking read IS the yield: the event loop runs
  // while the synchronous FFI call waits for USB data.
  //
  // We still need an explicit yield after the read returns so that
  // commands queued during the read get processed before we block
  // again.
  Future<void>(() async {
    while (running) {
      try {
        final data = backend!.read(
          readHandle!,
          inputPacketLength,
          timeout: readTimeout,
        );
        if (data.isNotEmpty) {
          mainPort.send(InputPacketEvent(data));
        }
      } catch (e) {
        if (running) {
          mainPort.send(WorkerError('Read error: $e'));
          running = false;
        }
        break;
      }
      // Yield to drain pending commands (display writes, shutdown).
      await Future<void>.delayed(Duration.zero);
    }
    cleanup();
    mainPort.send(WorkerStopped());
  });
}
