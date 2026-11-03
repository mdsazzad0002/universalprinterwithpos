import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/raster/page_raster.dart';
import 'local_api_server.dart';
import 'print_service.dart';
import 'printer_store.dart';
import 'system_printer.dart';

/// Android-only glue (see `HostBridge.kt`): the background service, battery
/// settings, and print jobs sent by other apps through an Intent.
/// Does nothing on other platforms.
class AndroidHost extends ChangeNotifier {
  AndroidHost({required this._printService, required this._api, required this._printers, required this._system});

  final PrintService _printService;
  final LocalApiServer _api;
  final PrinterStore _printers;
  final SystemPrinter _system;

  static const _channel = MethodChannel('com.bdsoft.universal_print/host');

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  /// Keeps the API and queue running with the app closed.
  bool backgroundEnabled = false;

  /// Exempt from Doze, so the API answers with the screen off.
  bool batteryUnrestricted = false;

  final _notifiedPairings = <String>{};
  String? _lastStatus;

  Future<void> init() async {
    if (!isSupported) return;
    _channel.setMethodCallHandler(_onCall);
    await refresh();
    _api.addListener(_onChanged);
    _printService.addListener(_onChanged);
    _onChanged();
    // Releases print requests that arrived while the app was starting.
    await _channel.invokeMethod('ready');
    // Background is on by default; Android 13+ needs this permission to show
    // its notification. Not awaited: the dialog must not hold up printing,
    // and a refusal is fine (the service still runs).
    if (backgroundEnabled) unawaited(_askNotificationPermission());
  }

  Future<void> _askNotificationPermission() async {
    if (await _channel.invokeMethod<bool>('hasNotificationPermission') == false) {
      await _channel.invokeMethod<bool>('requestNotificationPermission');
    }
  }

  Future<void> refresh() async {
    if (!isSupported) return;
    backgroundEnabled = await _channel.invokeMethod<bool>('getBackground') ?? false;
    batteryUnrestricted = await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations') ?? false;
    notifyListeners();
  }

  Future<void> setBackground(bool enabled) async {
    // Android 13+ hides the service notification without this permission;
    // the service still runs, so a refusal is not an error.
    if (enabled) await _channel.invokeMethod<bool>('requestNotificationPermission');
    backgroundEnabled = await _channel.invokeMethod<bool>('setBackground', {'enabled': enabled}) ?? false;
    notifyListeners();
  }

  /// Settings → Printing, where the Universal Print service is turned on.
  Future<void> openPrintSettings() => _channel.invokeMethod('openPrintSettings');

  /// Opens the system dialog; call [refresh] when the app resumes.
  Future<void> requestBatteryUnrestricted() => _channel.invokeMethod('requestIgnoreBatteryOptimizations');

  void _onChanged() {
    final status = _api.isRunning
        ? 'Print API on port ${_api.port}${_api.allowLan ? ' (Wi-Fi)' : ''} · ${_activeJobs()}'
        : (_api.lastError ?? 'Print API stopped');
    if (status != _lastStatus) {
      _lastStatus = status;
      _channel.invokeMethod('updateStatus', {'text': status});
    }
    for (final p in _api.pendingPairings) {
      if (_notifiedPairings.add(p.id)) {
        _channel.invokeMethod('notifyPairing', {'name': p.clientName, 'code': p.code});
      }
    }
  }

  String _activeJobs() {
    final active = _printService.recentJobs.where((j) => j.status.isActive).length;
    return active == 0 ? 'idle' : '$active printing';
  }

  Future<Object?> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'systemPrinters':
        return {
          'success': true,
          'printers': [for (final p in _printers.printers) systemPrinterInfo(p)],
        };
      case 'submitSystemPages':
        return _submitSystemPages(Map<String, Object?>.from(call.arguments as Map));
      case 'submitIntent':
        break;
      default:
        throw MissingPluginException(call.method);
    }
    final args = Map<String, Object?>.from(call.arguments as Map);
    // Other apps on this phone count as local, like loopback HTTP.
    final clientId = _api.resolveClient(args['token'] as String?, local: true);
    if (clientId == null) {
      return {
        'success': false,
        'error': args['token'] == null ? 'This app requires an API token (extra "token")' : 'Invalid API token',
        'code': 'unauthorized',
      };
    }
    try {
      final payload = jsonDecode(args['payload'] as String);
      if (payload is! Map) throw const FormatException('"payload" must be a JSON object');
      final request = Map<String, dynamic>.from(payload);
      final result = args['drawer'] == true
          ? await _printService.openDrawer(request, source: 'intent', clientId: clientId)
          : await _printService.submit(request, source: 'intent', clientId: clientId);
      return {'success': true, 'duplicate': result.duplicate, ...result.job.toApiJson()};
    } on PrintRequestException catch (e) {
      return {'success': false, 'error': e.message, 'code': 'invalid_request'};
    } on FormatException catch (e) {
      return {'success': false, 'error': e.message, 'code': 'invalid_request'};
    }
  }

  /// A document printed from another app through Android's print dialog
  /// (`UniversalPrintService.kt`): pages already rendered at the printer's
  /// width. Waits until the printer is done, so Android shows the real result.
  Future<Map<String, Object?>> _submitSystemPages(Map<String, Object?> args) async {
    final printer = _printers.byId(args['printer_id'] as String? ?? '');
    if (printer == null) return {'success': false, 'error': 'Printer not found'};
    try {
      final pages = <GrayPage>[];
      for (final png in (args['pages'] as List).cast<Uint8List>()) {
        pages.add(await _decode(png));
      }
      final ids = await _system.submitPages(
        printer,
        pages,
        copies: (args['copies'] as int?) ?? 1,
        jobName: args['job_name'] as String?,
        source: 'system',
      );
      final error = await _system.waitForJobs(ids);
      return error == null ? {'success': true, 'job_ids': ids} : {'success': false, 'error': error};
    } on PrintRequestException catch (e) {
      return {'success': false, 'error': e.message};
    }
  }

  static Future<GrayPage> _decode(Uint8List png) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(png);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    try {
      final rgba = await frame.image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      return GrayPage.fromRgba(rgba!.buffer.asUint8List(), frame.image.width, frame.image.height);
    } finally {
      frame.image.dispose();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
  }
}
