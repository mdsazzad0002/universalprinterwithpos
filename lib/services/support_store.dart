import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/database.dart';

/// Contact details of the app vendor, from the public website API. The last
/// good answer is kept so they still show offline.
class SupportStore extends ChangeNotifier {
  SupportStore(this._settings);

  static final endpoint = Uri.parse('https://bdsoftcms.dengrweb.com/api/contact');
  static const _cacheKey = 'support_contact';

  final SettingsRepository _settings;

  SupportInfo? info;
  bool loading = false;
  String? error;

  Future<void> load() async {
    final cached = await _settings.get(_cacheKey);
    if (cached != null) {
      try {
        info = SupportInfo.fromJson(jsonDecode(cached) as Map<String, dynamic>);
      } catch (_) {}
    }
    refresh();
  }

  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    error = null;
    notifyListeners();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(endpoint);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(const Duration(seconds: 10));
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) throw HttpException('HTTP ${response.statusCode}');
      final data = (jsonDecode(body) as Map<String, dynamic>)['data'] as Map<String, dynamic>;
      info = SupportInfo.fromJson(data);
      await _settings.set(_cacheKey, jsonEncode(data));
    } catch (e) {
      error = 'Could not load contact details';
    } finally {
      client.close(force: true);
      loading = false;
      notifyListeners();
    }
  }
}

class SupportInfo {
  const SupportInfo({
    this.name,
    this.whatsappUrl,
    this.whatsapp,
    this.phone,
    this.email,
    this.address,
    this.website,
    this.socials = const {},
  });

  factory SupportInfo.fromJson(Map<String, dynamic> j) {
    String? s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    final socials = j['socials'];
    return SupportInfo(
      name: s(j['name']),
      whatsapp: s(j['whatsapp']),
      whatsappUrl: s(j['whatsapp_url']),
      phone: s(j['phone']),
      email: s(j['email']),
      address: s(j['address']),
      website: s(j['website']),
      socials: {
        if (socials is Map)
          for (final e in socials.entries)
            if (s(e.value) != null) '${e.key}': s(e.value)!,
      },
    );
  }

  final String? name;
  final String? whatsapp;
  final String? whatsappUrl;
  final String? phone;
  final String? email;
  final String? address;
  final String? website;

  /// facebook, twitter, instagram, youtube, linkedin → URL; empty ones left out.
  final Map<String, String> socials;

  bool get isEmpty =>
      whatsappUrl == null && phone == null && email == null && address == null && website == null && socials.isEmpty;
}
