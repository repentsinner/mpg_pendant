/// USB Vendor ID for XHC/KTURT.LTD pendant dongles.
const int pendantVendorId = 0x10CE;

/// USB Product ID for xHB04B-family pendants (LHB04B and WHB04B variants).
const int pendantProductId = 0xEB93;

/// HID interface number for input reports and feature reports.
const int pendantInterfaceNumber = 0;

/// Input report header byte.
const int inputReportHeader = 0x04;

/// Display feature report ID.
const int displayReportId = 0x06;

/// Display payload header bytes.
const List<int> displayHeader = [0xFE, 0xFD, 0xFE];

/// Input packet length in bytes.
const int inputPacketLength = 8;

/// Display feature report length (report ID + 7 data bytes).
const int displayReportLength = 8;

/// Number of display feature reports per update.
const int displayReportCount = 3;

/// Total display payload bytes (across all reports, excluding report IDs).
const int displayPayloadLength = 21;
