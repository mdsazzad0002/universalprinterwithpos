import 'package:flutter/services.dart';

import 'printer_connection.dart';

class BluetoothDevice {
  const BluetoothDevice({required this.name, required this.address, required this.isPrinter});

  final String name;
  final String address;

  /// Device advertises the "imaging" class. Many cheap printers do not, so
  /// this is only used for sorting.
  final bool isPrinter;
}

/// Dart side of `BluetoothBridge.kt`.
class BluetoothBridge {
  static const _channel = MethodChannel('com.bdsoft.universal_print/bluetooth');

  static Future<bool> isEnabled() async =>
      await _channel.invokeMethod<bool>('isEnabled') ?? false;

  static Future<bool> requestPermission() async =>
      await _channel.invokeMethod<bool>('requestPermission') ?? false;

  static Future<List<BluetoothDevice>> bondedDevices() async {
    final list = await _channel.invokeListMethod<Map>('bondedDevices') ?? const [];
    final devices = [
      for (final d in list)
        BluetoothDevice(
          name: (d['name'] as String?) ?? 'Unknown',
          address: d['address'] as String,
          isPrinter: d['isPrinter'] == true,
        ),
    ];
    devices.sort((a, b) {
      if (a.isPrinter != b.isPrinter) return a.isPrinter ? -1 : 1;
      return a.name.compareTo(b.name);
    });
    return devices;
  }

  static Future<void> write(String address, Uint8List data) async {
    try {
      await _channel.invokeMethod('write', {'address': address, 'data': data});
    } on PlatformException catch (e) {
      throw PrinterConnectionException(e.message ?? e.code);
    }
  }

  static Future<void> disconnect(String address) =>
      _channel.invokeMethod('disconnect', {'address': address});

  static Future<void> openSettings() => _channel.invokeMethod('openSettings');
}
