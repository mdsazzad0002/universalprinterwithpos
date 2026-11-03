import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'models/client.dart';
import 'models/print_job.dart';
import 'models/printer.dart';

/// [factory] and [path] are overridable for tests (in-memory FFI database).
Future<Database> openAppDatabase({DatabaseFactory? factory, String? path}) async {
  factory ??= databaseFactory;
  return factory.openDatabase(
    path ?? p.join(await factory.getDatabasesPath(), 'universal_print.db'),
    options: OpenDatabaseOptions(
      version: 2,
      onCreate: (db, _) async {
        await _createV1(db);
        await _migrateV2(db);
      },
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) await _migrateV2(db);
      },
    ),
  );
}

Future<void> _createV1(Database db) async {
  await db.execute('''
    CREATE TABLE printers (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      connection_type TEXT NOT NULL,
      address TEXT NOT NULL,
      port INTEGER,
      paper_width INTEGER NOT NULL DEFAULT 58,
      protocol TEXT NOT NULL DEFAULT 'escpos',
      auto_cut INTEGER NOT NULL DEFAULT 1,
      is_default INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL
    )''');
  await db.execute('''
    CREATE TABLE print_jobs (
      id TEXT PRIMARY KEY,
      printer_id TEXT NOT NULL,
      printer_name TEXT NOT NULL,
      source TEXT NOT NULL,
      document_type TEXT NOT NULL,
      payload TEXT NOT NULL,
      copies INTEGER NOT NULL DEFAULT 1,
      reference TEXT,
      status TEXT NOT NULL,
      error TEXT,
      attempts INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )''');
  await db.execute('CREATE INDEX idx_jobs_created ON print_jobs(created_at)');
  await db.execute('CREATE INDEX idx_jobs_reference ON print_jobs(reference)');
  await db.execute('CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT)');
}

/// v2: paired software, print routes, and job routing info.
Future<void> _migrateV2(Database db) async {
  await db.execute('''
    CREATE TABLE api_clients (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      token TEXT NOT NULL UNIQUE,
      created_at TEXT NOT NULL,
      last_seen_at TEXT
    )''');
  await db.execute('''
    CREATE TABLE print_routes (
      client_id TEXT NOT NULL,
      key TEXT NOT NULL,
      name TEXT NOT NULL,
      printer_id TEXT,
      paper_width INTEGER,
      copies INTEGER NOT NULL DEFAULT 1,
      updated_at TEXT NOT NULL,
      PRIMARY KEY (client_id, key)
    )''');
  await db.execute('ALTER TABLE print_jobs ADD COLUMN client_id TEXT');
  await db.execute('ALTER TABLE print_jobs ADD COLUMN route TEXT');
  await db.execute('ALTER TABLE print_jobs ADD COLUMN paper_width INTEGER');
}

final _random = Random.secure();

/// Short sortable id, e.g. `PRN-m9x2k1-a7f3`.
String newId(String prefix) {
  final time = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  final rand = _random.nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');
  return '$prefix-$time-$rand';
}

String newToken() =>
    List.generate(32, (_) => _random.nextInt(16).toRadixString(16)).join();

class PrinterRepository {
  PrinterRepository(this._db);

  final Database _db;

  Future<List<Printer>> all() async {
    final rows = await _db.query('printers', orderBy: 'is_default DESC, name');
    return rows.map(Printer.fromRow).toList();
  }

  Future<void> save(Printer printer) => _db.transaction((txn) async {
    if (printer.isDefault) {
      await txn.update('printers', {'is_default': 0});
    }
    await txn.insert('printers', printer.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
  });

  Future<void> delete(String id) => _db.delete('printers', where: 'id = ?', whereArgs: [id]);
}

class JobRepository {
  JobRepository(this._db);

  final Database _db;

  Future<void> save(PrintJob job) =>
      _db.insert('print_jobs', job.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);

  Future<PrintJob?> find(String id) async {
    final rows = await _db.query('print_jobs', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : PrintJob.fromRow(rows.first);
  }

  Future<PrintJob?> findByReference(String reference) async {
    final rows = await _db.query(
      'print_jobs',
      where: 'reference = ? AND status != ?',
      whereArgs: [reference, JobStatus.cancelled.name],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : PrintJob.fromRow(rows.first);
  }

  Future<List<PrintJob>> recent({int limit = 100}) async {
    final rows = await _db.query('print_jobs', orderBy: 'created_at DESC', limit: limit);
    return rows.map(PrintJob.fromRow).toList();
  }

  /// Jobs left unfinished by a crash or app kill. They are failed rather than
  /// resumed, so a receipt is never printed twice without the user knowing.
  Future<void> failInterrupted() => _db.update(
    'print_jobs',
    {'status': JobStatus.failed.name, 'error': 'Interrupted (app was closed)'},
    where: 'status IN (?, ?, ?)',
    whereArgs: [JobStatus.pending.name, JobStatus.processing.name, JobStatus.printing.name],
  );
}

class SettingsRepository {
  SettingsRepository(this._db);

  final Database _db;

  Future<String?> get(String key) async {
    final rows = await _db.query('app_settings', where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> set(String key, String value) => _db.insert(
    'app_settings',
    {'key': key, 'value': value},
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}

class ClientRepository {
  ClientRepository(this._db);

  final Database _db;

  Future<List<ApiClient>> all() async {
    final rows = await _db.query('api_clients', orderBy: 'name');
    return rows.map(ApiClient.fromRow).toList();
  }

  Future<void> save(ApiClient client) =>
      _db.insert('api_clients', client.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> touch(String id) => _db.update(
    'api_clients',
    {'last_seen_at': DateTime.now().toIso8601String()},
    where: 'id = ?',
    whereArgs: [id],
  );

  Future<void> delete(String id) => _db.transaction((txn) async {
    await txn.delete('api_clients', where: 'id = ?', whereArgs: [id]);
    await txn.delete('print_routes', where: 'client_id = ?', whereArgs: [id]);
  });
}

class RouteRepository {
  RouteRepository(this._db);

  final Database _db;

  Future<List<PrintRoute>> all() async {
    final rows = await _db.query('print_routes', orderBy: 'client_id, name');
    return rows.map(PrintRoute.fromRow).toList();
  }

  Future<void> save(PrintRoute route) =>
      _db.insert('print_routes', route.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> delete(String clientId, String key) =>
      _db.delete('print_routes', where: 'client_id = ? AND key = ?', whereArgs: [clientId, key]);

  /// Routes pointing at a deleted printer become unassigned.
  Future<void> unassignPrinter(String printerId) =>
      _db.update('print_routes', {'printer_id': null}, where: 'printer_id = ?', whereArgs: [printerId]);
}
