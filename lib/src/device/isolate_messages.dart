import 'dart:isolate';
import 'dart:typed_data';

/// Startup payload sent to the worker isolate via [Isolate.spawn].
class WorkerStartup {
  const WorkerStartup({
    required this.sendPort,
    required this.readDevicePath,
    required this.writeDevicePath,
    this.readTimeoutMs = 100,
  });

  /// Port for sending [WorkerEvent]s back to the main isolate.
  final SendPort sendPort;

  /// HID device path for input reads.
  final String readDevicePath;

  /// HID device path for feature report writes.
  final String writeDevicePath;

  /// Read timeout in milliseconds for the polling loop.
  final int readTimeoutMs;
}

/// Commands sent from the main isolate to the worker.
sealed class WorkerCommand {}

/// Encode display reports on the main isolate, send raw bytes to the worker.
class WriteDisplayCommand extends WorkerCommand {
  WriteDisplayCommand(this.reports);

  /// Pre-encoded feature report buffers ready for [sendFeatureReport].
  final List<Uint8List> reports;
}

/// Request a clean shutdown of the worker isolate.
class ShutdownCommand extends WorkerCommand {}

/// Events sent from the worker isolate to the main isolate.
sealed class WorkerEvent {}

/// Worker has opened devices and is ready to receive commands.
class WorkerReady extends WorkerEvent {
  WorkerReady(this.commandPort);

  /// Port for sending [WorkerCommand]s to the worker.
  final SendPort commandPort;
}

/// A raw input packet read from the device.
class InputPacketEvent extends WorkerEvent {
  InputPacketEvent(this.data);

  /// Raw 8-byte HID input report.
  final Uint8List data;
}

/// A non-fatal error occurred in the worker.
class WorkerError extends WorkerEvent {
  WorkerError(this.message);
  final String message;
}

/// Worker has stopped and cleaned up all resources.
class WorkerStopped extends WorkerEvent {}
