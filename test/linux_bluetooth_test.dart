@TestOn('linux')
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_print/core/connection/linux_bluetooth.dart';
import 'package:universal_print/core/connection/printer_connection.dart';

void main() {
  // Without an adapter this hits the adapter check; with one it exercises the
  // real FFI connect, which fails for this fake address. Either way the
  // result must be a readable error, not a crash.
  test('RFCOMM write reports a clear error instead of crashing', () async {
    await expectLater(
      LinuxBluetooth.write('00:11:22:33:44:55', Uint8List.fromList([0x1B, 0x40])),
      throwsA(isA<PrinterConnectionException>().having((e) => e.message, 'message', isNotEmpty)),
    );
  });

  test('invalid address is rejected', () async {
    await expectLater(
      LinuxBluetooth.write('nope', Uint8List(1)),
      throwsA(isA<PrinterConnectionException>().having((e) => e.message, 'message', contains('Invalid'))),
    );
  });
}
