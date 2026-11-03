import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'local_api_server.dart';
import 'print_service.dart';

/// Android-only glue (see `HostBridge.kt`): the background service, battery
/// settings, and print jobs sent by other apps through an Intent.
/// Does nothing on other platforms.
class AndroidHost extends ChangeNotifier {
  AndroidHost({required this._printService, required this._api});

  final PrintService _printService;
  final LocalApiServer _api;

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
    if (call.method != 'submitIntent') throw MissingPluginException(call.method);
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
      final result = await _printService.submit(
        Map<String, dynamic>.from(payload),
        source: 'intent',
        clientId: clientId,
      );
      return {'success': true, 'duplicate': result.duplicate, ...result.job.toApiJson()};
    } on PrintRequestException catch (e) {
      return {'success': false, 'error': e.message, 'code': 'invalid_request'};
    } on FormatException catch (e) {
      return {'success': false, 'error': e.message, 'code': 'invalid_request'};
    }
  }
}
