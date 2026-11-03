import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/database.dart';

/// Windows / Linux: Universal Print keeps running in the background. Closing
/// the window only hides it (see the native runners), the app starts hidden
/// at login, and opening it again shows the running instance.
class DesktopBackground extends ChangeNotifier {
  DesktopBackground({required this._settings, List<String> args = const []}) : startedHidden = args.contains(backgroundArg);

  final SettingsRepository _settings;

  /// Argument the login entry starts the app with: no window until opened.
  static const backgroundArg = '--background';

  static bool get isSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux) && !Platform.environment.containsKey('FLUTTER_TEST');

  final bool startedHidden;

  /// Starts (hidden) when the user logs in.
  bool startAtLogin = false;
  String? lastError;

  Future<void> init() async {
    if (!isSupported) return;
    // On by default: the first launch of a release build adds the login
    // entry (a debug build would register its temporary build folder).
    final saved = await _settings.get('start_at_login');
    final wanted = saved == null ? !kDebugMode : saved == 'true';
    if (wanted) {
      await _apply(true);
    } else {
      startAtLogin = await _isRegistered();
    }
    notifyListeners();
  }

  Future<void> setStartAtLogin(bool enabled) async {
    await _settings.set('start_at_login', '$enabled');
    await _apply(enabled);
    notifyListeners();
  }

  /// Really exits: stops the print API and the system printer.
  Never quit() => exit(0);

  Future<void> _apply(bool enabled) async {
    try {
      Platform.isWindows ? await _windows(enabled) : await _linux(enabled);
      lastError = null;
    } catch (e) {
      lastError = 'Could not change start at login: $e';
    }
    startAtLogin = await _isRegistered();
  }

  static String get _exe => Platform.resolvedExecutable;

  // --- Linux: XDG autostart entry -------------------------------------------

  static File get _desktopFile {
    final config = Platform.environment['XDG_CONFIG_HOME'] ?? '${Platform.environment['HOME']}/.config';
    return File('$config/autostart/universal-print.desktop');
  }

  static String desktopEntry(String exe) =>
      '''
[Desktop Entry]
Type=Application
Name=Universal Print
Comment=Print server for POS and other software
Exec="${exe.replaceAll('"', r'\"')}" $backgroundArg
Terminal=false
X-GNOME-Autostart-enabled=true
''';

  Future<void> _linux(bool enabled) async {
    final f = _desktopFile;
    if (enabled) {
      await f.parent.create(recursive: true);
      await f.writeAsString(desktopEntry(_exe));
    } else if (await f.exists()) {
      await f.delete();
    }
  }

  // --- Windows: HKCU Run key ------------------------------------------------

  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _runValue = 'UniversalPrint';

  Future<void> _windows(bool enabled) async {
    final args = enabled
        ? ['add', _runKey, '/v', _runValue, '/t', 'REG_SZ', '/d', '"$_exe" $backgroundArg', '/f']
        : ['delete', _runKey, '/v', _runValue, '/f'];
    final r = await Process.run('reg', args);
    // Deleting a value that is not there is fine.
    if (r.exitCode != 0 && enabled) throw '${r.stderr}'.trim();
  }

  Future<bool> _isRegistered() async {
    try {
      if (Platform.isLinux) {
        final f = _desktopFile;
        return await f.exists() && (await f.readAsString()).contains(_exe);
      }
      final r = await Process.run('reg', ['query', _runKey, '/v', _runValue]);
      return r.exitCode == 0 && '${r.stdout}'.contains(_exe);
    } catch (_) {
      return false;
    }
  }
}
