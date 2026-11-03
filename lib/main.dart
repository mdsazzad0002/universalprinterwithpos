import 'package:flutter/material.dart';

import 'app_services.dart';
import 'ui/home_shell.dart';
import 'ui/theme.dart';

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
    return AppScope(
      services: services,
      child: ListenableBuilder(
        listenable: services.theme,
        builder: (context, _) => MaterialApp(
          title: 'Universal Print',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: services.theme.mode,
          home: const HomeShell(),
        ),
      ),
    );
  }
}
