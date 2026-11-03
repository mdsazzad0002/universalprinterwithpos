import 'package:flutter/widgets.dart';

import 'data/database.dart';
import 'services/android_host.dart';
import 'services/client_store.dart';
import 'services/desktop_background.dart';
import 'services/local_api_server.dart';
import 'services/os_printer_sync.dart';
import 'services/print_service.dart';
import 'services/printer_store.dart';
import 'services/support_store.dart';
import 'services/system_printer.dart';
import 'services/theme_store.dart';

class AppServices {
  AppServices._(
    this.printers,
    this.clients,
    this.printService,
    this.apiServer,
    this.host,
    this.theme,
    this.support,
    this.systemPrinter,
    this.osPrinters,
    this.desktop,
  );

  final PrinterStore printers;
  final ClientStore clients;
  final PrintService printService;
  final LocalApiServer apiServer;
  final AndroidHost host;
  final ThemeStore theme;
  final SupportStore support;
  final SystemPrinter systemPrinter;
  final OsPrinterSync osPrinters;
  final DesktopBackground desktop;

  static Future<AppServices> create({List<String> args = const []}) async {
    final db = await openAppDatabase();
    final printers = PrinterStore(PrinterRepository(db));
    await printers.load();
    final clients = ClientStore(ClientRepository(db), RouteRepository(db), printers);
    await clients.load();
    printers.onDeleted = clients.onPrinterDeleted;
    final printService = PrintService(jobs: JobRepository(db), printers: printers, clients: clients);
    await printService.init();
    final settings = SettingsRepository(db);
    final apiServer = LocalApiServer(
      settings: settings,
      printService: printService,
      printers: printers,
      clients: clients,
    );
    await apiServer.init();
    // Driverless IPP printer: lets the OS (Windows / Linux / macOS / other
    // phones) print to the app's printers with its built-in drivers.
    final systemPrinter = SystemPrinter(settings: settings, printService: printService, printers: printers);
    await systemPrinter.init();
    // Every printer added in the app is added to the OS printer list too.
    final osPrinters = OsPrinterSync(settings: settings, printers: printers, system: systemPrinter);
    await osPrinters.init();
    final desktop = DesktopBackground(settings: settings, args: args);
    await desktop.init();
    final host = AndroidHost(printService: printService, api: apiServer, printers: printers, system: systemPrinter);
    await host.init();
    final theme = ThemeStore(settings);
    await theme.load();
    final support = SupportStore(settings);
    await support.load();
    return AppServices._(printers, clients, printService, apiServer, host, theme, support, systemPrinter, osPrinters, desktop);
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
