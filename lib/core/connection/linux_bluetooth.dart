import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:bluez/bluez.dart';
import 'package:ffi/ffi.dart';

import 'bluetooth_bridge.dart';
import 'printer_connection.dart';

/// Bluetooth Classic printing on Linux.
///
/// Paired devices come from BlueZ over D-Bus; data goes over a raw RFCOMM
/// socket opened with FFI (Dart sockets have no AF_BLUETOOTH). Nearly all
/// SPP printers listen on RFCOMM channel 1.
class LinuxBluetooth {
  static const defaultChannel = 1;

  static Future<T> _withClient<T>(Future<T> Function(BlueZClient) body) async {
    final client = BlueZClient();
    try {
      await client.connect();
      return await body(client);
    } catch (e) {
      if (e is PrinterConnectionException) rethrow;
      throw PrinterConnectionException(
        'Bluetooth service is not available. Start it with: sudo systemctl start bluetooth ($e)',
      );
    } finally {
      await client.close();
    }
  }

  static Future<bool> isEnabled() => _withClient((c) async => c.adapters.any((a) => a.powered));

  static Future<List<BluetoothDevice>> bondedDevices() => _withClient((c) async {
    if (c.adapters.isEmpty) throw PrinterConnectionException('No Bluetooth adapter found on this computer');
    return [
      for (final d in c.devices.where((d) => d.paired))
        BluetoothDevice(
          name: d.alias.isNotEmpty ? d.alias : d.address,
          address: d.address,
          isPrinter: d.icon == 'printer' || (d.deviceClass >> 8 & 0x1F) == 0x06,
        ),
    ];
  });

  static Future<void> openSettings() async {
    for (final cmd in [
      ['gnome-control-center', 'bluetooth'],
      ['blueman-manager'],
      ['systemsettings', 'kcm_bluetooth'],
    ]) {
      try {
        await Process.start(cmd.first, cmd.sublist(1), mode: ProcessStartMode.detached);
        return;
      } on ProcessException {
        continue;
      }
    }
  }

  /// Connects, writes and closes in a background isolate, so a slow
  /// Bluetooth connect never freezes the UI.
  static Future<void> write(String address, Uint8List data, {int channel = defaultChannel}) async {
    if (!RegExp(r'^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$').hasMatch(address)) {
      throw PrinterConnectionException('Invalid Bluetooth address $address');
    }
    final adapters = Directory('/sys/class/bluetooth');
    if (!adapters.existsSync() || adapters.listSync().isEmpty) {
      throw PrinterConnectionException('No Bluetooth adapter found on this computer');
    }
    final error = await Isolate.run(() => _rfcommWrite(address, channel, data));
    if (error != null) throw PrinterConnectionException(error);
  }
}

// --- libc via FFI -------------------------------------------------------------

const _afBluetooth = 31;
const _sockStream = 1;
const _btprotoRfcomm = 3;

final _libc = DynamicLibrary.open('libc.so.6');
final _socket = _libc.lookupFunction<Int32 Function(Int32, Int32, Int32), int Function(int, int, int)>('socket');
final _connect = _libc.lookupFunction<
    Int32 Function(Int32, Pointer<Uint8>, Uint32),
    int Function(int, Pointer<Uint8>, int)>('connect');
final _write = _libc.lookupFunction<
    IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
    int Function(int, Pointer<Uint8>, int)>('write');
final _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
final _errnoLocation =
    _libc.lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>('__errno_location');

String _describe(int errno, String address) => switch (errno) {
  111 => 'Printer $address refused the connection (wrong RFCOMM channel?)',
  112 || 113 => 'Printer $address is off or out of range',
  16 => 'Printer $address is busy (connected to another device?)',
  13 || 1 => 'No permission to use Bluetooth',
  110 => 'Timed out connecting to $address',
  _ => 'Bluetooth error $errno talking to $address',
};

/// Returns null on success or an error message. Runs inside an isolate.
String? _rfcommWrite(String address, int channel, Uint8List data) {
  final parts = address.split(':');
  if (parts.length != 6) return 'Invalid Bluetooth address $address';

  final fd = _socket(_afBluetooth, _sockStream, _btprotoRfcomm);
  if (fd < 0) return 'Bluetooth is not supported here (errno ${_errnoLocation().value})';

  // struct sockaddr_rc { u16 family; u8 bdaddr[6] (little endian); u8 channel; } = 10 bytes
  final addr = calloc<Uint8>(10);
  final buf = calloc<Uint8>(data.length);
  try {
    addr[0] = _afBluetooth & 0xFF;
    addr[1] = _afBluetooth >> 8;
    for (var i = 0; i < 6; i++) {
      addr[2 + i] = int.parse(parts[5 - i], radix: 16);
    }
    addr[8] = channel;
    if (_connect(fd, addr, 10) != 0) return _describe(_errnoLocation().value, address);

    buf.asTypedList(data.length).setAll(0, data);
    var offset = 0;
    while (offset < data.length) {
      final n = _write(fd, buf + offset, data.length - offset);
      if (n <= 0) return 'Connection to $address lost while printing';
      offset += n;
    }
    // Give the printer's small buffer time to take the last bytes before close.
    sleep(const Duration(milliseconds: 300));
    return null;
  } finally {
    _close(fd);
    calloc.free(addr);
    calloc.free(buf);
  }
}
