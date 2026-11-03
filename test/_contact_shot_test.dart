import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_print/app_services.dart';
import 'package:universal_print/services/support_store.dart';
import 'package:universal_print/ui/menu_screen.dart';
import 'package:universal_print/ui/theme.dart';

const fonts = '/home/bdsoft/flutter/bin/cache/artifacts/material_fonts';
final out = Platform.environment['SHOT_OUT']!;

Future<void> load(String family, List<String> files) async {
  final l = FontLoader(family);
  for (final f in files) {
    l.addFont(Future.value(ByteData.sublistView(File('$fonts/$f').readAsBytesSync())));
  }
  await l.load();
}

void main() {
  testWidgets('contact shots', (tester) async {
    late AppServices s;
    await tester.runAsync(() async {
      await load('Roboto', ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']);
      await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
      s = await AppServices.create();
      await Future<void>.delayed(const Duration(seconds: 3)); // live API answer
    });
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(800, 2600);
    final key = GlobalKey();
    Future<void> shot(String name) async {
      await tester.pumpWidget(RepaintBoundary(
        key: key,
        child: AppScope(services: s, child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(Brightness.light), home: const MenuScreen())),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() async {
        final img = await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage(pixelRatio: 1);
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File('$out/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }
    // ignore: avoid_print
    print('LIVE error=${s.support.error} empty=${s.support.info?.isEmpty}');
    await shot('live');
    s.support.info = SupportInfo.fromJson({
      'whatsapp': '8801700000000', 'whatsapp_url': 'https://wa.me/8801590084779', 'phone': '8801590084779',
      'email': 'dev@dengrweb.com', 'address': 'House#13, Lean-12, Block-C, Section 6, Mirpur 6, Dhaka 1216', 'website': 'dengrweb.com',
      'socials': {'facebook': 'https://www.facebook.com/BangladeshSoftwareTech', 'youtube': 'https://www.youtube.com/@likesoftbd', 'linkedin': 'https://www.linkedin.com/company/d-engr-web/'},
    });
    await shot('sample');
    await tester.runAsync(() => s.apiServer.configure(enabled: false));
  });
}
