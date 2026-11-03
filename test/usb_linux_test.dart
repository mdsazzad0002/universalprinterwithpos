@TestOn('linux')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_print/core/connection/printer_connection.dart';
import 'package:universal_print/core/connection/usb_printers.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('usb_test');
    // Fake sysfs: usbmisc/lp0/device -> <usb device>/1-1:1.0
    final usbDevice = await Directory('${tmp.path}/devices/1-1').create(recursive: true);
    final iface = await Directory('${usbDevice.path}/1-1:1.0').create();
    await File('${usbDevice.path}/idVendor').writeAsString('0416\n');
    await File('${usbDevice.path}/idProduct').writeAsString('5011\n');
    await File('${usbDevice.path}/manufacturer').writeAsString('Winbond\n');
    await File('${usbDevice.path}/product').writeAsString('POS-80\n');
    await Directory('${tmp.path}/usbmisc/lp0').create(recursive: true);
    await Link('${tmp.path}/usbmisc/lp0/device').create(iface.path);
    await Directory('${tmp.path}/dev').create();
    await File('${tmp.path}/dev/lp0').create();
    UsbPrinters.sysClass = '${tmp.path}/usbmisc';
    UsbPrinters.devDir = '${tmp.path}/dev';
  });

  tearDown(() => tmp.delete(recursive: true));

  test('lists usblp printers by vendor:product', () async {
    final devices = await UsbPrinters.list();
    expect(devices.single.address, '0416:5011');
    expect(devices.single.name, 'Winbond POS-80');
  });

  test('writes raw bytes to the matching /dev node', () async {
    await UsbPrinters.write('0416:5011', Uint8List.fromList([0x1B, 0x40, 0x41]));
    await UsbPrinters.write('0416:5011', Uint8List.fromList([0x0A]));
    expect(await File('${tmp.path}/dev/lp0').readAsBytes(), [0x1B, 0x40, 0x41, 0x0A]);
  });

  test('works on a real character device (no fsync)', () async {
    // /dev/null is a char device like /dev/usb/lp0 and rejects fsync with EINVAL.
    await File('${tmp.path}/dev/lp0').delete();
    await Link('${tmp.path}/dev/lp0').create('/dev/null');
    await UsbPrinters.write('0416:5011', Uint8List.fromList([0x1B, 0x40]));
  });

  test('unplugged printer gives a clear error', () {
    expect(
      UsbPrinters.write('dead:beef', Uint8List(1)),
      throwsA(isA<PrinterConnectionException>().having((e) => e.message, 'message', contains('not connected'))),
    );
  });
}
