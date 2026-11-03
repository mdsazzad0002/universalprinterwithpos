import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'printer_connection.dart';

/// A printer installed in Windows (USB, Bluetooth or any other port).
class WindowsPrinter {
  const WindowsPrinter({required this.name, required this.port, required this.driver});

  final String name;

  /// `USB001`, `COM5:`, `IP_192.168.1.50` ...
  final String port;
  final String driver;
}

/// A serial port; Bluetooth SPP printers get one when paired in Windows.
class WindowsSerialPort {
  const WindowsSerialPort({required this.port, required this.device});

  /// `COM5`
  final String port;

  /// Kernel device, e.g. `\Device\BthModem0` for Bluetooth.
  final String device;

  bool get isBluetooth => device.toLowerCase().contains('bth');
}

/// Windows printing through Win32 (FFI, no plugin):
/// - installed printers get the bytes through the spooler as a RAW job, so
///   ESC/POS and TSPL reach the printer untouched by the driver;
/// - Bluetooth printers are written through their virtual COM port.
///
/// Writes run in a separate isolate because the Win32 calls block.
class WindowsPrinting {
  static const _enumFlags = _printerEnumLocal | _printerEnumConnections;

  static List<WindowsPrinter> installedPrinters() => using((arena) {
    final needed = arena<Uint32>();
    final count = arena<Uint32>();
    _enumPrinters(_enumFlags, nullptr, 2, nullptr, 0, needed, count);
    if (needed.value == 0) return const [];
    final buffer = arena<Uint8>(needed.value);
    if (_enumPrinters(_enumFlags, nullptr, 2, buffer, needed.value, needed, count) == 0) {
      throw PrinterConnectionException('Cannot list Windows printers (error ${_getLastError()})');
    }
    final infos = buffer.cast<_PrinterInfo2>();
    return [
      for (var i = 0; i < count.value; i++)
        WindowsPrinter(
          name: _str(infos[i].pPrinterName),
          port: _str(infos[i].pPortName),
          driver: _str(infos[i].pDriverName),
        ),
    ];
  });

  static Future<void> writeRaw(String printerName, Uint8List data) =>
      Isolate.run(() => _writeRaw(printerName, data));

  static List<WindowsSerialPort> serialPorts() => using((arena) {
    final key = arena<IntPtr>();
    final path = r'HARDWARE\DEVICEMAP\SERIALCOMM'.toNativeUtf16(allocator: arena);
    // The key only exists while at least one serial port is present.
    if (_regOpenKeyEx(_hkeyLocalMachine, path, 0, _keyRead, key) != 0) return const [];
    final ports = <WindowsSerialPort>[];
    try {
      final name = arena<Uint16>(256).cast<Utf16>();
      final data = arena<Uint8>(512);
      final nameLen = arena<Uint32>();
      final dataLen = arena<Uint32>();
      for (var i = 0;; i++) {
        nameLen.value = 256;
        dataLen.value = 512;
        if (_regEnumValue(key.value, i, name, nameLen, nullptr, nullptr, data, dataLen) != 0) break;
        ports.add(WindowsSerialPort(port: data.cast<Utf16>().toDartString(), device: name.toDartString()));
      }
    } finally {
      _regCloseKey(key.value);
    }
    return ports;
  });

  static Future<void> writeSerial(String port, Uint8List data) => Isolate.run(() => _writeSerial(port, data));

  static void _writeRaw(String printerName, Uint8List data) => using((arena) {
    final handle = arena<IntPtr>();
    if (_openPrinter(printerName.toNativeUtf16(allocator: arena), handle, nullptr) == 0) {
      throw PrinterConnectionException('Windows printer "$printerName" not found (error ${_getLastError()})');
    }
    final h = handle.value;
    try {
      final doc = arena<_DocInfo1>()
        ..ref.pDocName = 'Universal Print'.toNativeUtf16(allocator: arena)
        ..ref.pOutputFile = nullptr
        ..ref.pDatatype = 'RAW'.toNativeUtf16(allocator: arena);
      if (_startDocPrinter(h, 1, doc) == 0) {
        throw PrinterConnectionException('Printer "$printerName" refused the job (error ${_getLastError()})');
      }
      try {
        _startPagePrinter(h);
        final buf = arena<Uint8>(data.length)..asTypedList(data.length).setAll(0, data);
        final written = arena<Uint32>();
        if (_writePrinter(h, buf, data.length, written) == 0 || written.value != data.length) {
          throw PrinterConnectionException('Sending to "$printerName" failed (error ${_getLastError()})');
        }
        _endPagePrinter(h);
      } finally {
        _endDocPrinter(h);
      }
    } finally {
      _closePrinter(h);
    }
  });

  static void _writeSerial(String port, Uint8List data) => using((arena) {
    // The `\\.\COM10` form is required for ports above COM9.
    final h = _createFile('\\\\.\\$port'.toNativeUtf16(allocator: arena), _genericWrite, 0, nullptr, _openExisting, 0, 0);
    if (h == _invalidHandle) {
      final error = _getLastError();
      throw PrinterConnectionException(switch (error) {
        2 => '$port not found. Is the printer still paired?',
        5 => '$port is in use by another program',
        _ => 'Cannot open $port (error $error). Is the printer switched on?',
      });
    }
    try {
      final timeouts = arena<_CommTimeouts>()..ref.writeTotalTimeoutConstant = 30000;
      _setCommTimeouts(h, timeouts);
      final buf = arena<Uint8>(data.length)..asTypedList(data.length).setAll(0, data);
      final written = arena<Uint32>();
      if (_writeFile(h, buf, data.length, written, nullptr) == 0 || written.value != data.length) {
        throw PrinterConnectionException('Sending to $port failed (error ${_getLastError()})');
      }
    } finally {
      _closeHandle(h);
    }
  });

  static String _str(Pointer<Utf16> p) => p == nullptr ? '' : p.toDartString();
}

// --- Win32 -----------------------------------------------------------------

const _printerEnumLocal = 0x2;
const _printerEnumConnections = 0x4;
const _genericWrite = 0x40000000;
const _openExisting = 3;
const _invalidHandle = -1;
const _keyRead = 0x20019;
final _hkeyLocalMachine = 0x80000002.toSigned(32);

final class _DocInfo1 extends Struct {
  external Pointer<Utf16> pDocName;
  external Pointer<Utf16> pOutputFile;
  external Pointer<Utf16> pDatatype;
}

final class _PrinterInfo2 extends Struct {
  external Pointer<Utf16> pServerName;
  external Pointer<Utf16> pPrinterName;
  external Pointer<Utf16> pShareName;
  external Pointer<Utf16> pPortName;
  external Pointer<Utf16> pDriverName;
  external Pointer<Utf16> pComment;
  external Pointer<Utf16> pLocation;
  external Pointer<Void> pDevMode;
  external Pointer<Utf16> pSepFile;
  external Pointer<Utf16> pPrintProcessor;
  external Pointer<Utf16> pDatatype;
  external Pointer<Utf16> pParameters;
  external Pointer<Void> pSecurityDescriptor;
  @Uint32()
  external int attributes;
  @Uint32()
  external int priority;
  @Uint32()
  external int defaultPriority;
  @Uint32()
  external int startTime;
  @Uint32()
  external int untilTime;
  @Uint32()
  external int status;
  @Uint32()
  external int cJobs;
  @Uint32()
  external int averagePPM;
}

final class _CommTimeouts extends Struct {
  @Uint32()
  external int readIntervalTimeout;
  @Uint32()
  external int readTotalTimeoutMultiplier;
  @Uint32()
  external int readTotalTimeoutConstant;
  @Uint32()
  external int writeTotalTimeoutMultiplier;
  @Uint32()
  external int writeTotalTimeoutConstant;
}

final _winspool = DynamicLibrary.open('winspool.drv');
final _kernel32 = DynamicLibrary.open('kernel32.dll');
final _advapi32 = DynamicLibrary.open('advapi32.dll');

final _getLastError = _kernel32.lookupFunction<Uint32 Function(), int Function()>('GetLastError');

final _enumPrinters = _winspool.lookupFunction<
    Int32 Function(Uint32, Pointer<Utf16>, Uint32, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Uint32>),
    int Function(int, Pointer<Utf16>, int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Uint32>)>('EnumPrintersW');
final _openPrinter = _winspool.lookupFunction<
    Int32 Function(Pointer<Utf16>, Pointer<IntPtr>, Pointer<Void>),
    int Function(Pointer<Utf16>, Pointer<IntPtr>, Pointer<Void>)>('OpenPrinterW');
final _closePrinter = _winspool.lookupFunction<Int32 Function(IntPtr), int Function(int)>('ClosePrinter');
final _startDocPrinter = _winspool.lookupFunction<
    Uint32 Function(IntPtr, Uint32, Pointer<_DocInfo1>),
    int Function(int, int, Pointer<_DocInfo1>)>('StartDocPrinterW');
final _endDocPrinter = _winspool.lookupFunction<Int32 Function(IntPtr), int Function(int)>('EndDocPrinter');
final _startPagePrinter = _winspool.lookupFunction<Int32 Function(IntPtr), int Function(int)>('StartPagePrinter');
final _endPagePrinter = _winspool.lookupFunction<Int32 Function(IntPtr), int Function(int)>('EndPagePrinter');
final _writePrinter = _winspool.lookupFunction<
    Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>),
    int Function(int, Pointer<Uint8>, int, Pointer<Uint32>)>('WritePrinter');

final _createFile = _kernel32.lookupFunction<
    IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32, Uint32, IntPtr),
    int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)>('CreateFileW');
final _writeFile = _kernel32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
    int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)>('WriteFile');
final _setCommTimeouts = _kernel32.lookupFunction<
    Int32 Function(IntPtr, Pointer<_CommTimeouts>),
    int Function(int, Pointer<_CommTimeouts>)>('SetCommTimeouts');
final _closeHandle = _kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

final _regOpenKeyEx = _advapi32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32, Pointer<IntPtr>),
    int Function(int, Pointer<Utf16>, int, int, Pointer<IntPtr>)>('RegOpenKeyExW');
final _regEnumValue = _advapi32.lookupFunction<
    Int32 Function(IntPtr, Uint32, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint8>,
        Pointer<Uint32>),
    int Function(int, int, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint8>,
        Pointer<Uint32>)>('RegEnumValueW');
final _regCloseKey = _advapi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('RegCloseKey');
