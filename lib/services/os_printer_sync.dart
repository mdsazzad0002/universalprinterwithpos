import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/database.dart';
import '../data/models/printer.dart';
import 'os_printer_setup.dart';
import 'printer_store.dart';
import 'system_printer.dart';

/// What [OsPrinterSync] has to change in the operating system.
typedef SyncPlan = ({List<Printer> add, List<InstalledPrinter> remove});

/// Keeps the operating system's printer list in step with the app: a
/// printer added in the app is added to Windows / Linux / macOS (pointing at
/// the app's driverless IPP queue), and removed again when it is deleted or
/// renamed. Android does this through its print service instead.
class OsPrinterSync extends ChangeNotifier {
  OsPrinterSync({required this._settings, required this._printers, required this._system});

  final SettingsRepository _settings;
  final PrinterStore _printers;
  final SystemPrinter _system;

  /// Never in `flutter test`: it would change this computer's printers.
  static bool get isSupported => OsPrinterSetup.canManageInstalled && !Platform.environment.containsKey('FLUTTER_TEST');

  /// Add / remove OS printers automatically.
  bool enabled = true;

  /// Result of the last sync that changed something, or its error.
  String? lastMessage;
  bool lastFailed = false;
  bool get isSyncing => _running != null;

  Timer? _debounce;
  Future<void>? _running;
  bool _again = false;
  String _lastKey = '';

  Future<void> init() async {
    if (!isSupported) return;
    enabled = (await _settings.get('os_auto_add')) != 'false';
    _printers.addListener(_onChanged);
    _system.addListener(_onChanged);
    _onChanged();
  }

  Future<void> configure({required bool enabled}) async {
    this.enabled = enabled;
    await _settings.set('os_auto_add', '$enabled');
    _lastKey = '';
    notifyListeners();
    if (enabled) await syncNow();
  }

  /// Printers or the IPP server changed: sync once things settle. Ignores
  /// changes that do not affect the OS (e.g. the server's error text).
  void _onChanged() {
    if (!enabled || !_system.isRunning) return;
    final key = [_system.boundPort, for (final p in _system.sharedPrinters) '${p.id}:${p.name}'].join('|');
    if (key == _lastKey) return;
    _lastKey = key;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 1), () => unawaited(syncNow()));
  }

  /// Runs a sync now; a call during a running sync runs one more afterwards.
  Future<void> syncNow() async {
    if (!isSupported || !enabled || !_system.isRunning) return;
    if (_running != null) {
      _again = true;
      return _running;
    }
    final run = _sync();
    _running = run;
    notifyListeners();
    try {
      await run;
    } finally {
      _running = null;
      notifyListeners();
    }
    if (_again) {
      _again = false;
      await syncNow();
    }
  }

  Future<void> _sync() async {
    final List<InstalledPrinter> installed;
    try {
      installed = await OsPrinterSetup.listInstalled();
    } on OsPrinterException catch (e) {
      _report(e.message, failed: true);
      return;
    }
    final plan = planSync(
      shared: _system.sharedPrinters,
      installed: installed,
      expectedName: expectedName,
      expectedUri: expectedUri,
    );
    if (plan.add.isEmpty && plan.remove.isEmpty) return;
    final done = <String>[];
    final failed = <String>[];
    for (final old in plan.remove) {
      final r = await OsPrinterSetup.removeInstalled(old);
      (r.ok ? done : failed).add(r.message);
    }
    for (final p in plan.add) {
      final r = Platform.isWindows
          ? await OsPrinterSetup.addToWindows(expectedName(p), expectedUri(p))
          : await OsPrinterSetup.addToLinux(expectedName(p), expectedUri(p));
      (r.ok ? done : failed).add(r.message);
    }
    _report([...failed, ...done].join('\n'), failed: failed.isNotEmpty);
  }

  void _report(String message, {required bool failed}) {
    lastMessage = message;
    lastFailed = failed;
    notifyListeners();
  }

  /// OS printer name for [p].
  static String expectedName(Printer p) =>
      Platform.isWindows ? OsPrinterSetup.windowsName(p.name) : OsPrinterSetup.queueName(p.name);

  /// Address the OS printer for [p] prints to.
  String expectedUri(Printer p) => _system.localUri(p, scheme: Platform.isWindows ? 'http' : 'ipp');

  /// Which OS printers to add and remove so every one of [shared] has an
  /// up-to-date OS printer, and no OS printer of this app is left over.
  /// OS printers that are not this app's are never touched.
  static SyncPlan planSync({
    required List<Printer> shared,
    required List<InstalledPrinter> installed,
    required String Function(Printer) expectedName,
    required String Function(Printer) expectedUri,
  }) {
    // Only this device's queues: a Universal Print on another device of the
    // network (ipp://192.168.x.x/...) is someone else's.
    bool local(InstalledPrinter i) {
      final d = i.device ?? '';
      return !d.contains(SystemPrinterPaths.basePath) || d.contains('://127.0.0.1') || d.contains('://localhost');
    }

    final ours = installed.where((i) => i.isUniversalPrint && local(i)).toList();
    final keep = <InstalledPrinter>{};
    final add = <Printer>[];
    for (final p in shared) {
      final name = expectedName(p);
      final uri = expectedUri(p);
      final path = SystemPrinter.queuePath(p);
      final matches = ours.where((i) => i.name == name || (i.device?.endsWith(path) ?? false)).toList();
      // Up to date: right name, and pointing at this printer's queue on the
      // current port (Windows may show a port name instead of the URL).
      final current = matches.where((i) {
        if (i.name != name) return false;
        final device = i.device ?? '';
        return !device.contains(SystemPrinterPaths.basePath) || device == uri;
      }).firstOrNull;
      if (current != null) {
        keep.add(current);
      } else {
        add.add(p);
      }
    }
    return (
      add: add,
      remove: [
        for (final i in ours)
          if (!keep.contains(i)) i,
      ],
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _printers.removeListener(_onChanged);
    _system.removeListener(_onChanged);
    super.dispose();
  }
}
