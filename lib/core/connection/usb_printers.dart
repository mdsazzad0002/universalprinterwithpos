import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'printer_connection.dart';
import 'windows_printing.dart';

class UsbDevice {
  const UsbDevice({required this.name, required this.address, required this.isPrinter, this.deviceId});

  final String name;

  /// `vendorId:productId` in hex, e.g. `0416:5011`. Stable across replugs,
  /// unlike `/dev/usb/lp0` or `/dev/bus/usb/001/004`. On Windows: the name
  /// of the installed printer.
  final String address;

  /// Device exposes the USB printer class (7). Vendor-specific POS printers
  /// may not, so this is only used for sorting.
  final bool isPrinter;

  /// IEEE 1284 device ID, e.g. `MFG:Label;CMD:TSPL;MDL:TD-401H(300dpi);`.
  final String? deviceId;

  /// Command set from the device ID, `tspl` / `zpl` / `escpos` / null when unknown.
  String? get protocolHint {
    final cmd = RegExp(r'(?:CMD|COMMAND SET):([^;]*)', caseSensitive: false)
        .firstMatch(deviceId ?? '')?.group(1)?.toUpperCase() ?? '';
    if (cmd.contains('TSPL') || cmd.contains('TSC')) return 'tspl';
    if (cmd.contains('ZPL')) return 'zpl';
    if (cmd.contains('ESC')) return 'escpos';
    return null;
  }

  /// Resolution, when the model name says it (`300dpi`).
  int? get dpiHint {
    final m = RegExp(r'(203|300|600)\s*dpi', caseSensitive: false).firstMatch('$deviceId $name');
    return m == null ? null : int.parse(m.group(1)!);
  }
}

/// USB printers: Android via `UsbBridge.kt` (USB Host API), Linux via the
/// kernel `usblp` driver (`/dev/usb/lp*`), Windows via installed printers
/// (spooler, RAW).
class UsbPrinters {
  static const _channel = MethodChannel('com.bdsoft.universal_print/usb');

  static bool get isSupported => Platform.isAndroid || Platform.isLinux || Platform.isWindows;

  static Future<List<UsbDevice>> list() async {
    final devices = Platform.isAndroid
        ? await _androidList()
        : Platform.isWindows
        ? _windowsList()
        : await _linuxList();
    devices.sort((a, b) {
      if (a.isPrinter != b.isPrinter) return a.isPrinter ? -1 : 1;
      return a.name.compareTo(b.name);
    });
    return devices;
  }

  /// Android asks the user once per device; Linux needs no runtime prompt.
  static Future<bool> requestPermission(String address) async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('requestPermission', {'address': address}) ?? false;
    } on PlatformException catch (e) {
      throw PrinterConnectionException(e.message ?? e.code);
    }
  }

  static Future<void> write(String address, Uint8List data) async {
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod('write', {'address': address, 'data': data});
      } on PlatformException catch (e) {
        throw PrinterConnectionException(e.message ?? e.code);
      }
      return;
    }
    if (Platform.isWindows) return WindowsPrinting.writeRaw(address, data);
    await _linuxWrite(address, data);
  }

  static Future<List<UsbDevice>> _androidList() async {
    final list = await _channel.invokeListMethod<Map>('listDevices') ?? const [];
    return [
      for (final d in list)
        UsbDevice(
          name: d['name'] as String,
          address: d['address'] as String,
          isPrinter: d['isPrinter'] == true,
          deviceId: d['deviceId'] as String?,
        ),
    ];
  }

  /// USB printers first; other installed printers (network, Bluetooth COM)
  /// are listed too since RAW printing works the same on any port.
  static List<UsbDevice> _windowsList() => [
    for (final p in WindowsPrinting.installedPrinters())
      if (!p.port.startsWith('PORTPROMPT') && !p.port.startsWith('nul'))
        UsbDevice(
          name: p.name,
          address: p.name,
          isPrinter: p.port.toUpperCase().startsWith('USB'),
          deviceId: 'MDL:${p.driver};',
        ),
  ];

  // --- Linux ---------------------------------------------------------------

  /// Overridable so tests can use a fake sysfs and device directory.
  @visibleForTesting
  static String sysClass = '/sys/class/usbmisc';
  @visibleForTesting
  static String devDir = '/dev/usb';

  /// Every usblp device, keyed by its /dev node.
  static Future<Map<String, UsbDevice>> _linuxDevices() async {
    final result = <String, UsbDevice>{};
    final dir = Directory(sysClass);
    if (!await dir.exists()) return result;
    await for (final entry in dir.list()) {
      final node = entry.path.split('/').last;
      if (!node.startsWith('lp')) continue;
      try {
        // .../usbmisc/lp0/device -> USB interface; its parent is the device.
        final iface = await Directory('${entry.path}/device').resolveSymbolicLinks();
        final usbDevice = Directory(iface).parent.path;
        String read(String f) {
          final file = File('$usbDevice/$f');
          return file.existsSync() ? file.readAsStringSync().trim() : '';
        }

        final vid = read('idVendor');
        final pid = read('idProduct');
        if (vid.isEmpty || pid.isEmpty) continue;
        final name = [read('manufacturer'), read('product')].where((s) => s.isNotEmpty).join(' ');
        final idFile = File('${entry.path}/device/ieee1284_id');
        final deviceId = idFile.existsSync() ? idFile.readAsStringSync().trim() : null;
        result['$devDir/$node'] = UsbDevice(
          name: name.isEmpty ? 'USB printer ($node)' : name,
          address: '$vid:$pid',
          isPrinter: true,
          deviceId: deviceId,
        );
      } on FileSystemException {
        continue;
      }
    }
    return result;
  }

  static Future<List<UsbDevice>> _linuxList() async => (await _linuxDevices()).values.toList();

  static Future<void> _linuxWrite(String address, Uint8List data) async {
    final devices = await _linuxDevices();
    final node = devices.entries.where((e) => e.value.address == address).map((e) => e.key).firstOrNull;
    if (node == null) {
      throw PrinterConnectionException('USB printer $address is not connected');
    }
    RandomAccessFile? file;
    try {
      file = await File(node).open(mode: FileMode.writeOnlyAppend);
      // write() on usblp blocks until the printer has taken the data. Do not
      // flush(): it calls fsync, which character devices reject with EINVAL.
      await file.writeFrom(data);
    } on FileSystemException catch (e) {
      final denied = e.osError?.errorCode == 13;
      throw PrinterConnectionException(denied
          ? 'No permission for $node. Run: sudo usermod -aG lp \$USER (then log out and in)'
          : 'USB write to $node failed: ${e.osError?.message ?? e.message}');
    } finally {
      await file?.close();
    }
  }
}
