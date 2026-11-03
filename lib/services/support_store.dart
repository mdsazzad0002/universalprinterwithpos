import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/database.dart';

/// The app vendor's contact details, helpline, products and services, from the
/// public website API. The last good answer is kept so they still show offline.
class SupportStore extends ChangeNotifier {
  SupportStore(this._settings);

  static final endpoint = Uri.parse('https://bdsofttechnology.com/api/organization');
  static const _cacheKey = 'support_organization';

  final SettingsRepository _settings;

  SupportInfo? info;
  List<OrgItem> products = const [];
  List<OrgItem> services = const [];
  bool loading = false;
  String? error;

  Future<void> load() async {
    final cached = await _settings.get(_cacheKey);
    if (cached != null) {
      try {
        _apply(jsonDecode(cached) as Map<String, dynamic>);
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
      _apply(data);
      await _settings.set(_cacheKey, jsonEncode(data));
    } catch (e) {
      error = 'Could not load details';
    } finally {
      client.close(force: true);
      loading = false;
      notifyListeners();
    }
  }

  void _apply(Map<String, dynamic> data) {
    List<OrgItem> items(Object? list) => [
      if (list is List)
        for (final e in list)
          if (e is Map<String, dynamic>) OrgItem.fromJson(e),
    ]..removeWhere((e) => e.title.isEmpty);
    info = SupportInfo.fromJson(data['contact'] as Map<String, dynamic>);
    products = items(data['products']);
    services = items(data['services']);
  }
}

class SupportInfo {
  const SupportInfo({
    this.name,
    this.about,
    this.whatsappUrl,
    this.whatsapp,
    this.phone,
    this.helpline,
    this.openingTime,
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
      about: s(j['about']),
      whatsapp: s(j['whatsapp']),
      whatsappUrl: s(j['whatsapp_url']),
      phone: s(j['phone']),
      helpline: s(j['helpline']),
      openingTime: s(j['opening_time']),
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
  final String? about;
  final String? whatsapp;
  final String? whatsappUrl;
  final String? phone;
  final String? helpline;
  final String? openingTime;
  final String? email;
  final String? address;
  final String? website;

  /// facebook, twitter, instagram, youtube, linkedin → URL; empty ones left out.
  final Map<String, String> socials;

  bool get isEmpty =>
      whatsappUrl == null && phone == null && helpline == null && email == null && address == null && website == null && socials.isEmpty;
}

/// A product or service listed on the vendor's website.
class OrgItem {
  const OrgItem({required this.title, this.category, this.description, this.imageUrl, this.url});

  factory OrgItem.fromJson(Map<String, dynamic> j) {
    String? s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
    return OrgItem(
      title: s(j['name']) ?? s(j['title']) ?? '',
      category: s(j['category']),
      description: s(j['description']),
      imageUrl: s(j['image_url']),
      url: s(j['url']),
    );
  }

  final String title;
  final String? category;
  final String? description;
  final String? imageUrl;

  /// Page on the website.
  final String? url;
}
