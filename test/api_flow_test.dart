import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:universal_print/core/connection/printer_connection.dart';
import 'package:universal_print/core/escpos/esc_pos_builder.dart';
import 'package:universal_print/core/escpos/mono_bitmap.dart';
import 'package:universal_print/core/escpos/rasterizer.dart';
import 'package:universal_print/data/database.dart';
import 'package:universal_print/data/models/print_job.dart';
import 'package:universal_print/data/models/printer.dart';
import 'package:universal_print/services/client_store.dart';
import 'package:universal_print/services/local_api_server.dart';
import 'package:universal_print/services/print_service.dart';
import 'package:universal_print/services/printer_store.dart';

class _Rasterizer implements Rasterizer {
  MonoBitmap get _bmp => MonoBitmap(8, 1, Uint8List(1));
  @override
  Future<MonoBitmap> renderText(String text, {required int width, double fontSize = 24, bool bold = false, PosAlign align = PosAlign.left}) async => _bmp;
  @override
  Future<MonoBitmap> renderRow(String left, String right, {required int width, double fontSize = 24, bool bold = false}) async => _bmp;
  @override
  Future<MonoBitmap> decodeImage(Uint8List encoded, {required int maxWidth}) async => _bmp;
}

/// Records which printer received bytes.
class _Connection implements PrinterConnection {
  _Connection(this.printer, this.sent);
  final Printer printer;
  final List<String> sent;
  @override
  Future<void> send(Uint8List data) async => sent.add(printer.id);
}

void main() {
  late LocalApiServer api;
  late PrinterStore printers;
  late PrintService service;
  late ClientStore clients;
  late HttpClient http;
  late Uri base;
  late Database db;
  final sent = <String>[];

  Printer printer(String id, int width, {bool isDefault = false}) => Printer(
    id: id, name: id, connectionType: ConnectionType.network, address: '10.0.0.1',
    port: 9100, paperWidth: width, isDefault: isDefault, createdAt: DateTime(2026),
  );

  Future<(int, Map<String, dynamic>)> call(String method, String path, {String? token, Object? body}) async {
    final req = await http.openUrl(method, base.resolve(path));
    if (token != null) req.headers.set('Authorization', 'Bearer $token');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final text = await utf8.decodeStream(res);
    return (res.statusCode, jsonDecode(text) as Map<String, dynamic>);
  }

  setUp(() async {
    sqfliteFfiInit();
    db = await openAppDatabase(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    printers = PrinterStore(PrinterRepository(db));
    clients = ClientStore(ClientRepository(db), RouteRepository(db), printers);
    printers.onDeleted = clients.onPrinterDeleted;
    await printers.save(printer('cashier', 80, isDefault: true));
    await printers.save(printer('kitchen', 58));
    service = PrintService(
      jobs: JobRepository(db), printers: printers, clients: clients,
      rasterizer: _Rasterizer(), connectionFor: (p) => _Connection(p, sent),
    );
    await service.init();
    final settings = SettingsRepository(db);
    await settings.set('api_port', '0');
    api = LocalApiServer(settings: settings, printService: service, printers: printers, clients: clients);
    await api.init();
    http = HttpClient();
    base = Uri.parse('http://127.0.0.1:${api.boundPort}');
    sent.clear();
  });

  tearDown(() async {
    http.close(force: true);
    await api.stop();
    await service.idle;
    await db.close();
  });

  Future<String> pair() async {
    final (status, start) = await call('POST', '/api/pair', body: {'client_id': 'pos-1', 'client_name': 'My POS'});
    expect(status, 202);
    expect(start['code'], hasLength(6));
    expect(api.pendingPairings.single.code, start['code']);

    final (_, pending) = await call('GET', '/api/pair/${start['pairing_id']}');
    expect(pending['status'], 'pending');

    await api.approvePairing(start['pairing_id'] as String);
    final (_, done) = await call('GET', '/api/pair/${start['pairing_id']}');
    expect(done['status'], 'approved');
    expect(done['printers'], hasLength(2));
    // Token is only handed out once.
    final (gone, _) = await call('GET', '/api/pair/${start['pairing_id']}');
    expect(gone, 404);
    return done['token'] as String;
  }

  Future<PrintJob> waitDone(String id) async {
    for (var i = 0; i < 100; i++) {
      final job = (await service.find(id))!;
      if (!job.status.isActive) return job;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('job $id never finished');
  }

  test('profile created in the app prints with its token; clear keeps queue intact', () async {
    final profile = await clients.createProfile('Branch 2 POS');
    expect(profile.id, 'branch-2-pos');
    expect((await clients.createProfile('Branch 2 POS')).id, 'branch-2-pos-2');

    final (s1, job) = await call('POST', '/api/print', token: profile.token, body: {
      'document_type': 'text', 'content': 'hello',
    });
    expect(s1, 202);
    expect((await waitDone(job['job_id'] as String)).status, JobStatus.completed);
    expect((await call('GET', '/api/config', token: profile.token)).$2['client']['client_id'], 'branch-2-pos');

    expect(await service.clearFinished(), 1);
    expect(service.recentJobs, isEmpty);

    await clients.revoke(profile.id);
    expect((await call('GET', '/api/config', token: profile.token)).$1, 401);
  });

  test('pair, sync routes, print by route', () async {
    final token = await pair();

    final (s1, synced) = await call('PUT', '/api/routes', token: token, body: {
      'routes': [
        {'key': 'invoice', 'name': 'Customer invoice'},
        {'key': 'kitchen', 'name': 'Kitchen order', 'printer_id': 'kitchen'},
      ],
    });
    expect(s1, 200);
    expect(synced['unassigned'], ['invoice']);

    // Kitchen route → kitchen printer, laid out for its 58 mm paper.
    final (s2, job) = await call('POST', '/api/print', token: token, body: {
      'route': 'kitchen', 'document_type': 'text', 'content': 'Table 4\n2x Biriyani',
    });
    expect(s2, 202);
    expect(job['printer_id'], 'kitchen');
    expect(job['paper_width_mm'], 58);
    expect((await waitDone(job['job_id'] as String)).status, JobStatus.completed);

    // Unassigned route falls back to the default printer.
    final (_, inv) = await call('POST', '/api/print', token: token, body: {
      'route': 'invoice', 'document_type': 'text', 'content': 'hi', 'paper': {'width_mm': 58},
    });
    expect(inv['printer_id'], 'cashier');
    expect(inv['paper_width_mm'], 58);
    await waitDone(inv['job_id'] as String);
    expect(sent, ['kitchen', 'cashier']);

    // Config returns everything needed to sync.
    final (_, config) = await call('GET', '/api/config', token: token);
    expect(config['client']['client_id'], 'pos-1');
    expect((config['printers'] as List).first['paper']['chars_per_line'], 48);
    expect((config['routes'] as List).map((r) => r['key']), containsAll(['invoice', 'kitchen']));
  });

  test('validation and auth errors', () async {
    final token = await pair();
    // Default: same-device requests need no token, but a wrong one is rejected.
    expect((await call('GET', '/api/printers')).$1, 200);
    expect((await call('GET', '/api/printers', token: 'nope')).$1, 401);

    await api.configure(requireToken: true);
    expect((await call('GET', '/api/printers')).$1, 401);
    expect((await call('GET', '/api/printers', token: api.token)).$1, 200, reason: 'master token');
    expect((await call('GET', '/api/printers', token: token)).$1, 200, reason: 'client token');

    final (s, wide) = await call('POST', '/api/print', token: token, body: {
      'printer_id': 'kitchen', 'document_type': 'text', 'content': 'x', 'paper': {'width_mm': 80},
    });
    expect(s, 422);
    expect(wide['error'], contains('wider'));

    expect((await call('PUT', '/api/routes', token: token, body: {
      'routes': [{'key': 'Bad Key'}],
    })).$1, 422);
  });

  test('print without token or pairing on the same device', () async {
    final (_, ping) = await call('GET', '/api/ping');
    expect(ping['token_required'], isFalse);
    final (status, job) = await call('POST', '/api/print', body: {'route': 'invoice', 'document_type': 'text', 'content': 'hi'});
    expect(status, 202);
    expect(job['printer_id'], 'cashier');
    final (_, routes) = await call('GET', '/api/routes');
    expect((routes['routes'] as List).single['key'], 'invoice', reason: 'auto-registered under the manual client');
  });

  test('duplicate reference and batch', () async {
    final token = await pair();
    final body = {'document_type': 'text', 'content': 'x', 'reference': 'INV-9'};
    final (s1, first) = await call('POST', '/api/print', token: token, body: body);
    final (s2, second) = await call('POST', '/api/print', token: token, body: body);
    expect((s1, s2), (202, 200));
    expect(second['duplicate'], isTrue);
    expect(second['job_id'], first['job_id']);

    final (s3, batch) = await call('POST', '/api/print/batch', token: token, body: {
      'jobs': [
        {'printer_id': 'kitchen', 'document_type': 'text', 'content': 'k'},
        {'printer_id': 'missing', 'document_type': 'text', 'content': 'x'},
      ],
    });
    expect(s3, 207);
    expect(batch['success'], isFalse);
    expect((batch['results'] as List).map((r) => r['success']), [true, false]);
  });

  test('deleting a printer unassigns its routes', () async {
    final token = await pair();
    await call('PUT', '/api/routes', token: token, body: {
      'routes': [{'key': 'kitchen', 'printer_id': 'kitchen'}],
    });
    await printers.delete('kitchen');
    final (_, routes) = await call('GET', '/api/routes', token: token);
    expect((routes['routes'] as List).single['assigned'], isFalse);
  });
}
