import 'dart:io';

import 'package:flutter/services.dart';

import 'linux_bluetooth.dart';
import 'printer_connection.dart';
import 'windows_printing.dart';

class BluetoothDevice {
  const BluetoothDevice({required this.name, required this.address, required this.isPrinter});

  final String name;
  final String address;

  /// Device advertises the "imaging" class. Many cheap printers do not, so
  /// this is only used for sorting.
  final bool isPrinter;
}

/// Bluetooth Classic printers: `BluetoothBridge.kt` on Android, BlueZ +
/// RFCOMM ([LinuxBluetooth]) on Linux, the virtual COM port of the paired
/// printer on Windows ([WindowsPrinting]).
class BluetoothBridge {
  static const _channel = MethodChannel('com.bdsoft.universal_print/bluetooth');

  static bool get isSupported => Platform.isAndroid || Platform.isLinux || Platform.isWindows;

  static Future<bool> isEnabled() async {
    if (Platform.isLinux) return LinuxBluetooth.isEnabled();
    if (Platform.isWindows) return true; // a paired COM port is all we need
    return await _channel.invokeMethod<bool>('isEnabled') ?? false;
  }

  /// Runtime permission (Android 12+). Desktop needs none.
  static Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return true;
    return await _channel.invokeMethod<bool>('requestPermission') ?? false;
  }

  static Future<List<BluetoothDevice>> bondedDevices() async {
    final devices = Platform.isLinux
        ? await LinuxBluetooth.bondedDevices()
        : Platform.isWindows
        ? _windowsPorts()
        : await _androidBonded();
    devices.sort((a, b) {
      if (a.isPrinter != b.isPrinter) return a.isPrinter ? -1 : 1;
      return a.name.compareTo(b.name);
    });
    return devices;
  }

  static Future<List<BluetoothDevice>> _androidBonded() async {
    final list = await _channel.invokeListMethod<Map>('bondedDevices') ?? const [];
    return [
      for (final d in list)
        BluetoothDevice(
          name: (d['name'] as String?) ?? 'Unknown',
          address: d['address'] as String,
          isPrinter: d['isPrinter'] == true,
        ),
    ];
  }

  /// Windows does not expose the device name behind a COM port without
  /// SetupAPI; the port is what the user sees in Bluetooth settings anyway.
  static List<BluetoothDevice> _windowsPorts() => [
    for (final p in WindowsPrinting.serialPorts())
      BluetoothDevice(
        name: p.isBluetooth ? '${p.port} (Bluetooth)' : p.port,
        address: p.port,
        isPrinter: p.isBluetooth,
      ),
  ];

  /// [channel] is the RFCOMM channel, used on Linux only (Android finds it
  /// through the SPP service record).
  static Future<void> write(String address, Uint8List data, {int? channel}) async {
    if (Platform.isWindows) return WindowsPrinting.writeSerial(address, data);
    if (Platform.isLinux) {
      return LinuxBluetooth.write(address, data, channel: channel ?? LinuxBluetooth.defaultChannel);
    }
    try {
      await _channel.invokeMethod('write', {'address': address, 'data': data});
    } on PlatformException catch (e) {
      throw PrinterConnectionException(e.message ?? e.code);
    }
  }

  static Future<void> disconnect(String address) async {
    if (!Platform.isAndroid) return; // one connection per job
    await _channel.invokeMethod('disconnect', {'address': address});
  }

  static Future<void> openSettings() async {
    if (Platform.isLinux) return LinuxBluetooth.openSettings();
    if (Platform.isWindows) {
      await Process.run('explorer.exe', ['ms-settings:bluetooth']);
      return;
    }
    await _channel.invokeMethod('openSettings');
  }
}
