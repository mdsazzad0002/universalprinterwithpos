import 'package:flutter/material.dart';

import 'app_services.dart';
import 'ui/home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = await AppServices.create();
  runApp(UniversalPrintApp(services: services));
}

class UniversalPrintApp extends StatelessWidget {
  const UniversalPrintApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF1565C0);
    return AppScope(
      services: services,
      child: MaterialApp(
        title: 'Universal Print',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: seed),
        darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
        home: const HomeShell(),
      ),
    );
  }
}
