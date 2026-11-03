import 'package:flutter_test/flutter_test.dart';
import 'package:universal_print/services/support_store.dart';

void main() {
  test('unset fields from the API are empty', () {
    final info = SupportInfo.fromJson({
      'name': null, 'whatsapp': null, 'whatsapp_url': null, 'phone': null,
      'email': null, 'address': null, 'website': null,
      'socials': {'facebook': null, 'twitter': null},
    });
    expect(info.isEmpty, isTrue);
  });

  test('filled fields and socials are kept', () {
    final info = SupportInfo.fromJson({
      'name': 'BD Soft', 'whatsapp': '8801700000000', 'whatsapp_url': 'https://wa.me/8801700000000',
      'phone': '01700000000', 'email': ' info@example.com ', 'address': '', 'website': 'example.com',
      'socials': {'facebook': 'https://facebook.com/x', 'youtube': null},
    });
    expect(info.isEmpty, isFalse);
    expect(info.email, 'info@example.com');
    expect(info.address, isNull);
    expect(info.socials, {'facebook': 'https://facebook.com/x'});
  });
}
