import 'package:flutter/widgets.dart';

import 'data/database.dart';
import 'services/client_store.dart';
import 'services/local_api_server.dart';
import 'services/print_service.dart';
import 'services/printer_store.dart';

class AppServices {
  AppServices._(this.printers, this.clients, this.printService, this.apiServer);

  final PrinterStore printers;
  final ClientStore clients;
  final PrintService printService;
  final LocalApiServer apiServer;

  static Future<AppServices> create() async {
    final db = await openAppDatabase();
    final printers = PrinterStore(PrinterRepository(db));
    await printers.load();
    final clients = ClientStore(ClientRepository(db), RouteRepository(db), printers);
    await clients.load();
    printers.onDeleted = clients.onPrinterDeleted;
    final printService = PrintService(jobs: JobRepository(db), printers: printers, clients: clients);
    await printService.init();
    final apiServer = LocalApiServer(
      settings: SettingsRepository(db),
      printService: printService,
      printers: printers,
      clients: clients,
    );
    await apiServer.init();
    return AppServices._(printers, clients, printService, apiServer);
  }
}

class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.services, required super.child});

  final AppServices services;

  static AppServices of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.services;

  @override
  bool updateShouldNotify(AppScope oldWidget) => services != oldWidget.services;
}
