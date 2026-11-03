import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../data/models/printer.dart';
import 'bluetooth_bridge.dart';

/// Sends finished printer bytes to a device.
abstract class PrinterConnection {
  Future<void> send(Uint8List data);

  factory PrinterConnection.forPrinter(Printer printer) => switch (printer.connectionType) {
    ConnectionType.bluetooth => BluetoothConnection(printer.address),
    ConnectionType.network => NetworkConnection(printer.address, printer.port ?? 9100),
  };
}

/// Raw TCP printing (JetDirect / port 9100), used by almost every network
/// POS and label printer. One socket per job keeps it stateless.
class NetworkConnection implements PrinterConnection {
  NetworkConnection(this.host, this.port, {this.timeout = const Duration(seconds: 5)});

  final String host;
  final int port;
  final Duration timeout;

  @override
  Future<void> send(Uint8List data) async {
    final Socket socket;
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
    } on SocketException catch (e) {
      throw PrinterConnectionException('Cannot reach $host:$port (${e.osError?.message ?? e.message})');
    }
    try {
      socket.add(data);
      await socket.flush().timeout(const Duration(seconds: 30));
      // Graceful close so the printer gets every byte before the FIN.
      await socket.close().timeout(const Duration(seconds: 3), onTimeout: () => socket);
    } on TimeoutException {
      throw PrinterConnectionException('Timed out sending data to $host:$port');
    } on SocketException catch (e) {
      throw PrinterConnectionException('Connection to $host:$port lost (${e.message})');
    } finally {
      socket.destroy();
    }
  }
}

/// Bluetooth Classic SPP via the native bridge, which keeps the socket open
/// between jobs and reconnects when needed.
class BluetoothConnection implements PrinterConnection {
  BluetoothConnection(this.address);

  final String address;

  @override
  Future<void> send(Uint8List data) => BluetoothBridge.write(address, data);
}

class PrinterConnectionException implements Exception {
  PrinterConnectionException(this.message);

  final String message;

  @override
  String toString() => message;
}
