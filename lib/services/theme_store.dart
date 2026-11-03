import 'package:flutter/material.dart';

import '../data/database.dart';

/// Light / dark / follow-the-system choice, kept across restarts.
class ThemeStore extends ChangeNotifier {
  ThemeStore(this._settings);

  final SettingsRepository _settings;

  ThemeMode mode = ThemeMode.system;

  Future<void> load() async {
    final saved = await _settings.get('theme_mode');
    mode = ThemeMode.values.firstWhere((m) => m.name == saved, orElse: () => ThemeMode.system);
  }

  Future<void> setMode(ThemeMode value) async {
    if (value == mode) return;
    mode = value;
    notifyListeners();
    await _settings.set('theme_mode', value.name);
  }
}
