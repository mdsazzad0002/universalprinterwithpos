import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:universal_print/core/connection/printer_connection.dart';
import 'package:universal_print/core/escpos/esc_pos_builder.dart';
import 'package:universal_print/core/escpos/mono_bitmap.dart';
import 'package:universal_print/core/escpos/rasterizer.dart';
import 'package:universal_print/core/ipp/ipp_message.dart';
import 'package:universal_print/core/raster/page_raster.dart';
import 'package:universal_print/data/database.dart';
import 'package:universal_print/data/models/print_job.dart';
import 'package:universal_print/data/models/printer.dart';
import 'package:universal_print/services/client_store.dart';
import 'package:universal_print/services/os_driver_setup.dart';
import 'package:universal_print/services/os_printer_setup.dart';
import 'package:universal_print/services/os_printer_sync.dart';
import 'package:universal_print/services/print_service.dart';
import 'package:universal_print/services/printer_store.dart';
import 'package:universal_print/services/system_printer.dart';

/// PWG raster ("RaS2") with one sgray_8 page per entry of [pages].
Uint8List pwgRaster(List<GrayPage> pages, {int dpi = 203}) {
  final b = BytesBuilder()..add(ascii.encode('RaS2'));
  for (final p in pages) {
    final h = ByteData(1796);
    h.setUint32(276, dpi);
    h.setUint32(280, dpi);
    h.setUint32(372, p.width);
    h.setUint32(376, p.height);
    h.setUint32(384, 8);
    h.setUint32(388, 8);
    h.setUint32(392, p.width);
    h.setUint32(396, 0);
    h.setUint32(400, 18); // sGray
    b.add(h.buffer.asUint8List());
    b.add(_compress(p, 1));
  }
  return b.toBytes();
}

/// Apple raster ("UNIRAST") with one sRGB 24-bit page per entry.
Uint8List urfRaster(List<GrayPage> pages) {
  final b = BytesBuilder()
    ..add(ascii.encode('UNIRAST'))
    ..addByte(0);
  b.add((ByteData(4)..setUint32(0, pages.length)).buffer.asUint8List());
  for (final p in pages) {
    final h = ByteData(32)
      ..setUint8(0, 24)
      ..setUint8(1, 1) // sRGB
      ..setUint32(12, p.width)
      ..setUint32(16, p.height)
      ..setUint32(20, 300);
    b.add(h.buffer.asUint8List());
    final rgb = GrayPage(p.width * 3, p.height, Uint8List(p.width * 3 * p.height));
    for (var i = 0; i < p.pixels.length; i++) {
      rgb.pixels.fillRange(i * 3, i * 3 + 3, p.pixels[i]);
    }
    b.add(_compress(p, 3, rgb: rgb));
  }
  return b.toBytes();
}

/// Mixes all three run types: repeated lines, repeated pixels, literals.
Uint8List _compress(GrayPage p, int unit, {GrayPage? rgb}) {
  final src = rgb ?? p;
  final lineBytes = p.width * unit;
  final out = BytesBuilder();
  var y = 0;
  while (y < p.height) {
    final line = src.pixels.sublist(y * lineBytes, (y + 1) * lineBytes);
    var repeat = 0;
    while (y + repeat + 1 < p.height &&
        repeat < 255 &&
        listEquals(src.pixels.sublist((y + repeat + 1) * lineBytes, (y + repeat + 2) * lineBytes), line)) {
      repeat++;
    }
    out.addByte(repeat);
    var x = 0;
    while (x < p.width) {
      var same = 1;
      while (x + same < p.width && same < 128 && _px(line, x + same, unit) == _px(line, x, unit)) {
        same++;
      }
      if (same > 1) {
        out.addByte(same - 1);
        out.add(line.sublist(x * unit, (x + 1) * unit));
        x += same;
      } else {
        var n = 1;
        while (x + n < p.width && n < 128 && _px(line, x + n, unit) != _px(line, x + n - 1, unit)) {
          n++;
        }
        out.addByte(257 - n);
        out.add(line.sublist(x * unit, (x + n) * unit));
        x += n;
      }
    }
    y += repeat + 1;
  }
  return out.toBytes();
}

String _px(Uint8List line, int x, int unit) => line.sublist(x * unit, (x + 1) * unit).join(',');

bool listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// White page with a black bar at the top and a gray bar below it.
GrayPage samplePage(int width, int height) {
  final px = Uint8List(width * height)..fillRange(0, width * height, 255);
  for (var y = 10; y < 30; y++) {
    px.fillRange(y * width + width ~/ 4, y * width + width * 3 ~/ 4, 0);
  }
  return GrayPage(width, height, px);
}

class _Rasterizer implements Rasterizer {
  @override
  Future<MonoBitmap> renderText(
    String text, {
    required int width,
    double fontSize = 24,
    bool bold = false,
    PosAlign align = PosAlign.left,
  }) async => MonoBitmap(8, 1, Uint8List(1));
  @override
  Future<MonoBitmap> renderRow(String left, String right, {required int width, double fontSize = 24, bool bold = false}) async =>
      MonoBitmap(8, 1, Uint8List(1));
  @override
  Future<MonoBitmap> decodeImage(Uint8List encoded, {required int maxWidth}) async => MonoBitmap(8, 1, Uint8List(1));
}

class _Connection implements PrinterConnection {
  _Connection(this.data);
  final List<Uint8List> data;
  @override
  Future<void> send(Uint8List bytes) async => data.add(bytes);
}

IppMessage ippRequest(
  int op,
  String printerUri, {
  List<IppAttribute> extra = const [],
  List<IppAttribute> job = const [],
  Uint8List? data,
}) => IppMessage(
  code: op,
  requestId: 7,
  groups: [
    IppGroup(IppTag.operationGroup, [
      IppAttribute.charset('attributes-charset', ['utf-8']),
      IppAttribute.language('attributes-natural-language', ['en']),
      IppAttribute.uri('printer-uri', [printerUri]),
      IppAttribute.nameValue('requesting-user-name', 'tester'),
      ...extra,
    ]),
    if (job.isNotEmpty) IppGroup(IppTag.jobGroup, job),
  ],
  data: data,
);

void main() {
  group('raster', () {
    test('PWG raster decodes and scales to the paper width', () {
      final page = samplePage(1000, 300);
      final pages = RasterDecoder.decode(pwgRaster([page, page]), targetWidth: 500);
      expect(pages, hasLength(2));
      expect(pages[0].width, 500);
      expect(pages[0].height, 150);
      // Bar rows 10..30 → 5..15; columns 250..750 → 125..375.
      expect(pages[0].pixels[10 * 500 + 250], 0);
      expect(pages[0].pixels[10 * 500 + 50], 255);
      expect(pages[0].pixels[100 * 500 + 250], 255);
    });

    test('Apple raster (URF, sRGB) decodes', () {
      final page = samplePage(300, 120);
      final pages = RasterDecoder.decode(urfRaster([page]), targetWidth: 600);
      expect(pages.single.width, 600);
      expect(pages.single.height, 240);
      expect(pages.single.pixels[40 * 600 + 300], 0);
      expect(pages.single.pixels[200 * 600 + 300], 255);
    });

    test('fill-to-end-of-line run (128) is blank paper', () {
      final b = BytesBuilder()..add(ascii.encode('RaS2'));
      final h = ByteData(1796)
        ..setUint32(372, 16)
        ..setUint32(376, 1)
        ..setUint32(384, 8)
        ..setUint32(388, 8)
        ..setUint32(392, 16)
        ..setUint32(400, 18);
      b.add(h.buffer.asUint8List());
      b.add([0, 3, 0, 128]); // 4 black pixels, then blank
      final page = RasterDecoder.decode(b.toBytes(), targetWidth: 16).single;
      expect(page.pixels.sublist(0, 4), [0, 0, 0, 0]);
      expect(page.pixels.sublist(4).every((v) => v == 255), isTrue);
    });

    test('truncated and unknown documents are rejected', () {
      final good = pwgRaster([samplePage(64, 64)]);
      expect(
        () => RasterDecoder.decode(good.sublist(0, good.length - 5), targetWidth: 64),
        throwsA(isA<RasterFormatException>()),
      );
      expect(
        () => RasterDecoder.decode(Uint8List.fromList(utf8.encode('%PDF-1.4')), targetWidth: 64),
        throwsA(isA<RasterFormatException>()),
      );
    });

    test('text stays sharp, photos are dithered, bottom is trimmed', () {
      final page = samplePage(64, 200);
      expect(page.hasPhotoContent, isFalse);
      final mono = page.toMono();
      expect(mono.isBlack(32, 15), isTrue);
      expect(mono.isBlack(2, 15), isFalse);
      final trimmed = trimBottom(mono);
      expect(trimmed.height, 30 + 8);

      final gray = GrayPage(64, 64, Uint8List(64 * 64)..fillRange(0, 64 * 64, 128));
      expect(gray.hasPhotoContent, isTrue);
      final dithered = gray.toMono();
      var black = 0;
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          if (dithered.isBlack(x, y)) black++;
        }
      }
      expect(black, inInclusiveRange(64 * 64 * 0.4, 64 * 64 * 0.6));
    });

    test('mono PNG is a valid 1-bit grayscale PNG', () {
      final mono = samplePage(40, 40).toMono();
      final png = encodeMonoPng(mono);
      expect(png.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      final bd = ByteData.sublistView(png);
      expect(String.fromCharCodes(png.sublist(12, 16)), 'IHDR');
      expect(bd.getUint32(16), 40);
      expect(bd.getUint32(20), 40);
      expect(png[24], 1); // bit depth
      final idatLen = bd.getUint32(33);
      expect(String.fromCharCodes(png.sublist(37, 41)), 'IDAT');
      final raw = ZLibCodec().decode(png.sublist(41, 41 + idatLen));
      expect(raw.length, 40 * (5 + 1));
      // Row 15, pixel 20 is black → bit 0 in PNG.
      expect(raw[15 * 6 + 1 + 2] & 0x80 >> 4, 0);
    });
  });

  group('IPP codec', () {
    test('round-trips attributes, collections and data', () {
      final msg = IppMessage(
        code: IppOp.printJob,
        requestId: 42,
        groups: [
          IppGroup(IppTag.operationGroup, [
            IppAttribute.charset('attributes-charset', ['utf-8']),
            IppAttribute.keyword('requested-attributes', ['all', 'media-col-database']),
          ]),
          IppGroup(IppTag.jobGroup, [
            IppAttribute.integer('copies', [3]),
            IppAttribute.boolean('flag', true),
            IppAttribute.resolution('printer-resolution', [const IppResolution(203, 203)]),
            IppAttribute.range('copies-supported', 1, 20),
            IppAttribute.collection('media-col', [
              IppCollection([
                IppAttribute.collection('media-size', [
                  IppCollection([
                    IppAttribute.integer('x-dimension', [8000]),
                    IppAttribute.integer('y-dimension', [29700]),
                  ]),
                ]),
                IppAttribute.keyword('media-type', ['continuous']),
              ]),
            ]),
          ]),
        ],
        data: Uint8List.fromList([1, 2, 3]),
      );
      final back = IppMessage.decode(msg.encode());
      expect(back.code, IppOp.printJob);
      expect(back.requestId, 42);
      expect(back.operation('requested-attributes')!.values, ['all', 'media-col-database']);
      expect(back.job('copies')!.integer, 3);
      expect(back.job('flag')!.value, true);
      expect((back.job('printer-resolution')!.value as IppResolution).x, 203);
      expect((back.job('copies-supported')!.value as IppRange).upper, 20);
      final col = back.job('media-col')!.value as IppCollection;
      final size = col['media-size']!.value as IppCollection;
      expect(size['x-dimension']!.integer, 8000);
      expect(col['media-type']!.string, 'continuous');
      expect(back.data, [1, 2, 3]);
    });
  });

  test('CUPS queue names are safe', () {
    expect(OsPrinterSetup.queueName('Cash desk 80mm!'), 'UniversalPrint_Cash_desk_80mm');
    expect(OsPrinterSetup.queueName('বাংলা'), 'UniversalPrint');
    expect(OsPrinterSetup.windowsCommand("Bob's", 'http://x'), "Add-Printer -Name 'Bob''s' -IppURL 'http://x'");
  });

  test('reads CUPS printers from lpstat', () {
    final list = OsPrinterSetup.parseCups(
      devices:
          'device for -9X00: usb://LABEL/-9X00?serial=Printer\n'
          'device for TD-401H: ///dev/null\n'
          'device for UniversalPrint_Cash: ipp://127.0.0.1:8631/ipp/print/abc\n',
      defaultDest: 'system default destination: TD-401H\n',
      status:
          'printer -9X00 disabled since Tue Nov  3 19:38:47 2026 -\n'
          '\tUnplugged or turned off\n'
          'printer TD-401H is idle.  enabled since Tue Nov  3 17:09:44 2026\n',
    );
    expect(list.map((p) => p.name), ['-9X00', 'TD-401H', 'UniversalPrint_Cash']);
    expect(list[0].enabled, isFalse);
    expect(list[0].status, 'Disabled · Unplugged or turned off');
    expect(list[0].device, 'usb://LABEL/-9X00?serial=Printer');
    expect(list[1].isDefault, isTrue);
    expect(list[1].status, 'Idle');
    expect(list[2].isUniversalPrint, isTrue);
    expect(list[0].isUniversalPrint, isFalse);
    expect(OsPrinterSetup.parseCups(devices: '', defaultDest: 'no system default destination', status: ''), isEmpty);
  });

  test('reads Windows printers from Win32_Printer JSON', () {
    final list = OsPrinterSetup.parseWindows(
      '[{"Name":"Microsoft Print to PDF","DriverName":"Microsoft Print To PDF","PortName":"PORTPROMPT:",'
      '"Default":true,"WorkOffline":false,"PrinterStatus":3},'
      '{"Name":"Universal Print - Cash","DriverName":"Microsoft IPP Class Driver",'
      '"PortName":"http://127.0.0.1:8631/ipp/print/abc","Default":false,"WorkOffline":true,"PrinterStatus":7}]',
    );
    expect(list, hasLength(2));
    expect(list[0].isDefault, isTrue);
    expect(list[0].status, 'Idle');
    expect(list[1].isUniversalPrint, isTrue);
    expect(list[1].enabled, isFalse);
    expect(OsPrinterSetup.parseWindows('{"Name":"Only"}').single.name, 'Only');
    expect(OsPrinterSetup.parseWindows(''), isEmpty);
  });

  group('OS printer sync', () {
    Printer printer(String id, String name) =>
        Printer(id: id, name: name, connectionType: ConnectionType.network, address: '10.0.0.9', createdAt: DateTime(2026));
    String name(Printer p) => OsPrinterSetup.queueName(p.name);
    String uri(Printer p) => 'ipp://127.0.0.1:8631${SystemPrinter.queuePath(p)}';
    InstalledPrinter os(String name, String device) => InstalledPrinter(name: name, device: device);

    test('adds new printers, keeps current ones, leaves other printers alone', () {
      final a = printer('a', 'Cash'), b = printer('b', 'Kitchen');
      final plan = OsPrinterSync.planSync(
        shared: [a, b],
        installed: [os('UniversalPrint_Cash', 'ipp://127.0.0.1:8631/ipp/print/a'), os('HP_LaserJet', 'usb://HP/LaserJet')],
        expectedName: name,
        expectedUri: uri,
      );
      expect(plan.add, [b]);
      expect(plan.remove, isEmpty);
    });

    test('removes deleted printers and re-adds renamed or moved ones', () {
      final a = printer('a', 'Front desk');
      final plan = OsPrinterSync.planSync(
        shared: [a],
        installed: [
          os('UniversalPrint_Cash', 'ipp://127.0.0.1:8631/ipp/print/a'), // renamed
          os('UniversalPrint_Old', 'ipp://127.0.0.1:8631/ipp/print/gone'), // deleted
          os('UniversalPrint_Phone', 'ipp://192.168.1.5:8631/ipp/print/x'), // another device
        ],
        expectedName: name,
        expectedUri: uri,
      );
      expect(plan.add, [a]);
      expect(plan.remove.map((i) => i.name), ['UniversalPrint_Cash', 'UniversalPrint_Old']);

      final moved = OsPrinterSync.planSync(
        shared: [a],
        installed: [os('UniversalPrint_Front_desk', 'ipp://127.0.0.1:9999/ipp/print/a')],
        expectedName: name,
        expectedUri: uri,
      );
      expect(moved.add, [a]);
      expect(moved.remove.single.name, 'UniversalPrint_Front_desk');
    });
  });

  group('OS drivers', () {
    test('reads driver packages from dpkg -S', () {
      expect(
        OsDriverSetup.parseDpkgOwners(
          'hplip, cups-filters, printer-driver-brlaser: /usr/lib/cups/filter\n'
          'libfoo:amd64, cups: /usr/share/ppd\n'
          "dpkg-query: no path found matching pattern /usr/local/share/ppd\n",
        ),
        ['cups', 'cups-filters', 'hplip', 'libfoo', 'printer-driver-brlaser'],
      );
    });

    test('reads what apt would remove', () {
      expect(OsDriverSetup.parseAptSimulation('Reading package lists...\nRemv ubuntu-desktop [1.539]\nRemv hplip [3.24.4]\n'), [
        'ubuntu-desktop',
        'hplip',
      ]);
    });

    test('reads Windows drivers and marks the built-in ones', () {
      final list = OsDriverSetup.parseWindowsDrivers(
        '[{"Name":"Microsoft IPP Class Driver","Manufacturer":"Microsoft","Environment":"Windows x64",'
        '"Inf":"C:\\\\Windows\\\\INF\\\\ntprint.inf","UsedBy":["Universal Print - Cash"]},'
        '{"Name":"XP-80C","Manufacturer":"Xprinter","Environment":"Windows x64","Inf":"C:\\\\x\\\\xp80.inf","UsedBy":[]}]',
      );
      expect(list.map((d) => d.isSystem), [true, false]);
      expect(list[0].usedBy, ['Universal Print - Cash']);
      expect(list[1].detail, 'Xprinter · Windows x64');
      expect(OsDriverSetup.parseWindowsDrivers('{"Name":"One","UsedBy":"P1"}').single.usedBy, ['P1']);
    });
  });

  group('IPP printer', () {
    late Database db;
    late PrinterStore printers;
    late PrintService service;
    late SystemPrinter system;
    final sent = <Uint8List>[];

    setUp(() async {
      sqfliteFfiInit();
      db = await openAppDatabase(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
      printers = PrinterStore(PrinterRepository(db));
      final clients = ClientStore(ClientRepository(db), RouteRepository(db), printers);
      await printers.save(
        Printer(
          id: 'cashier',
          name: 'Cashier',
          connectionType: ConnectionType.network,
          address: '10.0.0.1',
          paperWidth: 80,
          isDefault: true,
          createdAt: DateTime(2026),
        ),
      );
      await printers.save(
        Printer(
          id: 'label',
          name: 'Labels',
          connectionType: ConnectionType.usb,
          address: '1:2',
          paperWidth: 50,
          protocol: PrinterProtocol.tspl,
          labelHeight: 30,
          createdAt: DateTime(2026),
        ),
      );
      await printers.save(
        Printer(
          id: 'office',
          name: 'Office',
          connectionType: ConnectionType.network,
          address: '10.0.0.9',
          protocol: PrinterProtocol.ipp,
          createdAt: DateTime(2026),
        ),
      );
      service = PrintService(
        jobs: JobRepository(db),
        printers: printers,
        clients: clients,
        rasterizer: _Rasterizer(),
        connectionFor: (_) => _Connection(sent),
      );
      await service.init();
      final settings = SettingsRepository(db);
      await settings.set('sys_enabled', 'true');
      await settings.set('sys_port', '0');
      await settings.set('sys_lan', 'false');
      system = SystemPrinter(settings: settings, printService: service, printers: printers, advertiser: NoAdvertiser());
      await system.init();
      sent.clear();
    });

    tearDown(() async {
      await system.stop();
      await service.idle;
      await db.close();
    });

    /// Raw HTTP so `Expect: 100-continue` is exercised like CUPS does it.
    Future<IppMessage> post(String path, IppMessage msg, {bool expectContinue = true}) async {
      final body = msg.encode();
      final socket = await Socket.connect('127.0.0.1', system.boundPort!);
      final incoming = StreamIterator(socket);
      final buf = BytesBuilder();
      Future<String> readHead() async {
        while (true) {
          final bytes = buf.toBytes();
          final text = latin1.decode(bytes);
          final i = text.indexOf('\r\n\r\n');
          if (i >= 0) {
            buf.clear();
            buf.add(bytes.sublist(i + 4));
            return text.substring(0, i);
          }
          if (!await incoming.moveNext()) throw StateError('closed');
          buf.add(incoming.current);
        }
      }

      socket.write(
        'POST $path HTTP/1.1\r\nHost: 127.0.0.1:${system.boundPort}\r\n'
        'Content-Type: application/ipp\r\nContent-Length: ${body.length}\r\n'
        '${expectContinue ? 'Expect: 100-continue\r\n' : ''}\r\n',
      );
      await socket.flush();
      if (expectContinue) {
        final head = await readHead();
        expect(head, startsWith('HTTP/1.1 100'));
      }
      socket.add(body);
      await socket.flush();
      final head = await readHead();
      expect(head, startsWith('HTTP/1.1 200'));
      final length = int.parse(RegExp(r'Content-Length: (\d+)').firstMatch(head)!.group(1)!);
      while (buf.length < length) {
        if (!await incoming.moveNext()) break;
        buf.add(incoming.current);
      }
      await socket.close();
      socket.destroy();
      return IppMessage.decode(buf.toBytes().sublist(0, length));
    }

    String uri(String path) => 'ipp://127.0.0.1:${system.boundPort}$path';

    test('Get-Printer-Attributes describes the default queue', () async {
      final r = await post('/ipp/print', ippRequest(IppOp.getPrinterAttributes, uri('/ipp/print')));
      expect(r.code, IppStatus.ok);
      final p = r.group(IppTag.printerGroup)!;
      expect(p['printer-name']!.string, 'Cashier');
      expect(p['document-format-supported']!.values, containsAll(['image/pwg-raster', 'image/urf']));
      expect(p['media-default']!.string, 'om_80mm-roll_80x297mm');
      expect(p['printer-uri-supported']!.string, uri('/ipp/print'));
      final col = p['media-col-default']!.value as IppCollection;
      expect(((col['media-size']!.value as IppCollection)['x-dimension'])!.integer, 8000);
    });

    test('requested-attributes filters the reply', () async {
      final r = await post(
        '/ipp/print',
        ippRequest(
          IppOp.getPrinterAttributes,
          uri('/ipp/print'),
          extra: [
            IppAttribute.keyword('requested-attributes', ['printer-state', 'media-supported']),
          ],
        ),
      );
      expect(r.group(IppTag.printerGroup)!.attributes.map((a) => a.name), ['media-supported', 'printer-state']);
    });

    test('A4 IPP printers and unknown queues are not shared', () async {
      final r = await post('/ipp/print/office', ippRequest(IppOp.getPrinterAttributes, uri('/ipp/print/office')));
      expect(r.code, IppStatus.notFound);
      expect(system.sharedPrinters.map((p) => p.id), ['cashier', 'label']);
    });

    test('Print-Job with PWG raster prints a receipt', () async {
      final doc = pwgRaster([samplePage(640, 2000), samplePage(640, 400)]);
      final r = await post(
        '/ipp/print/cashier',
        ippRequest(
          IppOp.printJob,
          uri('/ipp/print/cashier'),
          extra: [
            IppAttribute.mime('document-format', ['image/pwg-raster']),
            IppAttribute.nameValue('job-name', 'Invoice 7'),
          ],
          job: [
            IppAttribute.integer('copies', [2]),
          ],
          data: doc,
        ),
      );
      expect(r.code, IppStatus.ok);
      final jobId = r.job('job-id')!.integer!;
      await service.idle;

      final job = service.recentJobs.first;
      expect(job.source, 'system');
      expect(job.printerId, 'cashier');
      expect(job.copies, 2);
      expect(job.status, JobStatus.completed);
      final elements = job.payload['elements'] as List;
      expect(elements, hasLength(2));
      expect(sent, hasLength(1));

      final status = await post(
        '/ipp/print/cashier',
        ippRequest(
          IppOp.getJobAttributes,
          uri('/ipp/print/cashier'),
          extra: [
            IppAttribute.integer('job-id', [jobId]),
          ],
        ),
      );
      expect(status.job('job-state')!.integer, 9);
      expect(status.job('job-name')!.string, 'Invoice 7');
    });

    test('Create-Job + Send-Document with Apple raster, labels print one per page', () async {
      final created = await post('/ipp/print/label', ippRequest(IppOp.createJob, uri('/ipp/print/label')));
      expect(created.code, IppStatus.ok);
      final id = created.job('job-id')!.integer!;
      expect(created.job('job-state')!.integer, 4);

      final r = await post(
        '/ipp/print/label',
        ippRequest(
          IppOp.sendDocument,
          uri('/ipp/print/label'),
          extra: [
            IppAttribute.integer('job-id', [id]),
            IppAttribute.mime('document-format', ['image/urf']),
            IppAttribute.boolean('last-document', true),
          ],
          data: urfRaster([samplePage(590, 354), samplePage(590, 354)]),
        ),
        expectContinue: false,
      );
      expect(r.code, IppStatus.ok);
      await service.idle;
      expect(service.recentJobs.where((j) => j.printerId == 'label'), hasLength(2));
    });

    test('raw ESC/POS and plain text pass through', () async {
      final raw = await post(
        '/ipp/print',
        ippRequest(
          IppOp.printJob,
          uri('/ipp/print'),
          extra: [
            IppAttribute.mime('document-format', ['application/vnd.cups-raw']),
          ],
          data: Uint8List.fromList([0x1B, 0x40, 0x41, 0x0A]),
        ),
      );
      expect(raw.code, IppStatus.ok);
      await service.idle;
      // The renderer prefixes its printer init; the job bytes follow untouched.
      expect(sent.last.sublist(sent.last.length - 4), [0x1B, 0x40, 0x41, 0x0A]);

      final text = await post(
        '/ipp/print',
        ippRequest(
          IppOp.printJob,
          uri('/ipp/print'),
          extra: [
            IppAttribute.mime('document-format', ['text/plain']),
          ],
          data: Uint8List.fromList(utf8.encode('Hello\r\nWorld')),
        ),
      );
      expect(text.code, IppStatus.ok);
      await service.idle;
      expect(service.recentJobs.first.payload['content'], 'Hello\nWorld');
    });

    test('PDF and unknown formats are refused', () async {
      final pdf = await post(
        '/ipp/print',
        ippRequest(IppOp.printJob, uri('/ipp/print'), data: Uint8List.fromList(utf8.encode('%PDF-1.7 ...'))),
      );
      expect(pdf.code, IppStatus.documentFormatNotSupported);
      final word = await post(
        '/ipp/print',
        ippRequest(
          IppOp.validateJob,
          uri('/ipp/print'),
          extra: [
            IppAttribute.mime('document-format', ['application/msword']),
          ],
        ),
      );
      expect(word.code, IppStatus.documentFormatNotSupported);
    });

    test('submitPages (Android print framework) trims and queues', () async {
      final ids = await system.submitPages(printers.byId('cashier')!, [samplePage(576, 1500)], jobName: 'Chrome page');
      await service.idle;
      final job = await service.find(ids.single);
      expect(job!.status, JobStatus.completed);
      expect(job.payload['job_name'], 'Chrome page');
      expect(await system.waitForJobs(ids), isNull);
    });

    test('"open cash drawer with every print" kicks the drawer on system jobs', () async {
      final kick = [0x1B, 0x70, 0x00, 0x19, 0xFA];
      bool kicked(Uint8List b) {
        for (var i = 0; i + kick.length <= b.length; i++) {
          if (Iterable<int>.generate(kick.length).every((k) => b[i + k] == kick[k])) return true;
        }
        return false;
      }

      await system.submitPages(printers.byId('cashier')!, [samplePage(576, 100)]);
      await service.idle;
      expect(kicked(sent.last), isFalse);

      await system.configure(openDrawer: true);
      expect(system.isRunning, isTrue);
      final ids = await system.submitPages(printers.byId('cashier')!, [samplePage(576, 100)]);
      await service.idle;
      expect((await service.find(ids.single))!.payload['open_drawer'], isTrue);
      expect(kicked(sent.last), isTrue);

      // Label printers have no drawer; the option is ignored, not an error.
      final label = await system.submitPages(printers.byId('label')!, [samplePage(400, 240)]);
      await service.idle;
      expect((await service.find(label.single))!.status, JobStatus.completed);
    });

    test('RAW port 9100 is off unless enabled', () async {
      expect(system.isRawRunning, isFalse);
    });
  });
}
