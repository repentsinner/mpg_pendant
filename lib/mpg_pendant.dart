/// Cross-platform USB HID driver for XHC WHB04B-family CNC pendants.
library;

// Protocol layer — pure Dart, no I/O.
export 'src/protocol/constants.dart';
export 'src/protocol/display_encoder.dart'
    show
        encodeCoordinate,
        encodeDisplayPayload,
        encodeDisplayUpdate,
        encodeFlags;
export 'src/protocol/input_packet.dart' show decodeInputPacket;
export 'src/protocol/models.dart';

// Device layer — HID I/O abstraction.
export 'src/device/hid_backend.dart';
export 'src/device/hidapi_hid_backend.dart';
export 'src/device/pendant_connection.dart';
export 'src/device/pendant_discovery.dart';
