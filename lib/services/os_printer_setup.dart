import 'dart:convert';
import 'dart:io';

/// Operating systems the system printer can be added to.
enum ClientOs {
  android('Android'),
  windows('Windows'),
  linux('Linux'),
  macos('macOS');

  const ClientOs(this.label);

  final String label;

  static ClientOs get current {
    if (Platform.isWindows) return windows;
    if (Platform.isLinux) return linux;
    if (Platform.isMacOS) return macos;
    return android;
  }
}

typedef SetupResult = ({bool ok, String message});

/// Adds the Universal Print IPP queue to the operating system's own printer
/// list, using only the built-in driverless drivers.
abstract final class OsPrinterSetup {
  /// CUPS queue names: letters, digits, `_` and `-`.
  static String queueName(String printerName) {
    final clean = printerName.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_').replaceAll(RegExp(r'_+'), '_');
    final trimmed = clean.replaceAll(RegExp(r'^_|_$'), '');
    return 'UniversalPrint${trimmed.isEmpty ? '' : '_$trimmed'}';
  }

  /// Windows printer display name.
  static String windowsName(String printerName) => 'Universal Print - $printerName';

  static String linuxCommand(String queue, String ippUri) =>
      "lpadmin -p $queue -E -v '$ippUri' -m everywhere -D 'Universal Print'";

  static String linuxDefaultCommand(String queue) => 'lpoptions -d $queue';

  static String macCommand(String queue, String ippUri) => "lpadmin -p $queue -E -v '$ippUri' -m everywhere -D 'Universal Print'";

  static String windowsCommand(String name, String httpUrl) =>
      "Add-Printer -Name '${psQuote(name)}' -IppURL '${psQuote(httpUrl)}'";

  static String windowsDefaultCommand(String name) =>
      "(New-Object -ComObject WScript.Network).SetDefaultPrinter('${psQuote(name)}')";

  static String psQuote(String s) => s.replaceAll("'", "''");

  /// Creates a CUPS `everywhere` queue (no PPD or vendor driver). Asks for
  /// the admin password through pkexec when the user may not run lpadmin.
  static Future<SetupResult> addToLinux(String queue, String ippUri, {bool makeDefault = false}) async {
    final args = ['-p', queue, '-E', '-v', ippUri, '-m', 'everywhere', '-D', 'Universal Print'];
    try {
      final r = await _lpadmin(args);
      if (r.exitCode != 0) {
        return (ok: false, message: clean('${r.stderr}${r.stdout}', 'lpadmin failed (${r.exitCode})'));
      }
      if (makeDefault) {
        final d = await Process.run('lpoptions', ['-d', queue]);
        if (d.exitCode != 0) {
          return (ok: true, message: 'Printer "$queue" added, but could not make it the default: ${clean('${d.stderr}', '')}');
        }
      }
      return (ok: true, message: 'Printer "$queue" added to Linux${makeDefault ? ' as the default printer' : ''}');
    } on ProcessException {
      return (ok: false, message: 'CUPS is not installed (sudo apt install cups)');
    }
  }

  /// Adds an IPP printer with the Microsoft IPP Class Driver (built into
  /// Windows 10 / 11). Retries elevated (UAC prompt) when access is denied.
  static Future<SetupResult> addToWindows(String name, String httpUrl, {bool makeDefault = false}) async {
    final add =
        "if (-not (Get-Printer -Name '${psQuote(name)}' -ErrorAction SilentlyContinue)) { ${windowsCommand(name, httpUrl)} }";
    try {
      final r = await powershellElevated(add);
      if (r.exitCode != 0) {
        return (ok: false, message: clean('${r.stderr}${r.stdout}', 'Add-Printer failed (${r.exitCode})'));
      }
      if (makeDefault) {
        final d = await powershell(windowsDefaultCommand(name));
        if (d.exitCode != 0) {
          return (ok: true, message: 'Printer added, but could not make it the default: ${clean('${d.stderr}', '')}');
        }
      }
      return (ok: true, message: '"$name" added to Windows${makeDefault ? ' as the default printer' : ''}');
    } on ProcessException {
      return (ok: false, message: 'PowerShell is not available');
    }
  }

  // ---------------------------------------------------------------------------
  // Printers already installed in the operating system.

  /// Can this OS list and remove its printers from the app? Android has no
  /// API for that: its print services own their printers.
  static bool get canManageInstalled => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// Every printer the operating system knows (CUPS queues or Windows
  /// printers), the default first.
  static Future<List<InstalledPrinter>> listInstalled() async {
    final list = Platform.isWindows ? await _listWindows() : await _listCups();
    list.sort((a, b) {
      if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  /// Removes [printer] from the operating system. Asks for the admin
  /// password (pkexec / UAC / macOS prompt) when needed.
  static Future<SetupResult> removeInstalled(InstalledPrinter printer) async {
    try {
      final ProcessResult r;
      if (Platform.isWindows) {
        r = await powershellElevated("Remove-Printer -Name '${psQuote(printer.name)}'");
      } else {
        r = await _lpadmin(['-x', printer.name]);
      }
      if (r.exitCode != 0) {
        return (ok: false, message: clean('${r.stderr}${r.stdout}', 'Could not remove "${printer.name}" (${r.exitCode})'));
      }
      return (ok: true, message: '"${printer.name}" removed from ${ClientOs.current.label}');
    } on ProcessException {
      return (ok: false, message: Platform.isWindows ? 'PowerShell is not available' : 'CUPS is not installed');
    }
  }

  static const _cEnv = {'LC_ALL': 'C', 'LANG': 'C'};

  static Future<List<InstalledPrinter>> _listCups() async {
    try {
      final results = await Future.wait([
        Process.run('lpstat', ['-v'], environment: _cEnv),
        Process.run('lpstat', ['-d'], environment: _cEnv),
        Process.run('lpstat', ['-p'], environment: _cEnv),
      ]);
      // lpstat exits non-zero when there are no printers at all.
      final list = parseCups(devices: '${results[0].stdout}', defaultDest: '${results[1].stdout}', status: '${results[2].stdout}');
      // Driver of each queue ("printer-make-and-model").
      return await Future.wait([
        for (final p in list)
          Process.run('lpoptions', ['-p', p.name], environment: _cEnv).then(
            (r) => p.withDriver(RegExp(r"printer-make-and-model='([^']*)'").firstMatch('${r.stdout}')?.group(1)),
            onError: (Object _) => p,
          ),
      ]);
    } on ProcessException {
      throw const OsPrinterException('CUPS is not installed (sudo apt install cups)');
    }
  }

  /// Parses the output of `lpstat -v`, `lpstat -d` and `lpstat -p` (C locale).
  static List<InstalledPrinter> parseCups({required String devices, required String defaultDest, required String status}) {
    final def = RegExp(r'system default destination:\s*(\S+)').firstMatch(defaultDest)?.group(1);
    final states = <String, ({bool enabled, String text})>{};
    String? last;
    for (final line in status.split('\n')) {
      final m = RegExp(r'^printer (\S+) (.*)$').firstMatch(line);
      if (m != null) {
        last = m.group(1)!;
        final rest = m.group(2)!;
        final text = rest.startsWith('is idle')
            ? 'Idle'
            : rest.startsWith('now printing')
            ? 'Printing'
            : rest.startsWith('disabled')
            ? 'Disabled'
            : rest.split('.').first;
        states[last] = (enabled: !rest.startsWith('disabled'), text: text);
      } else if (last != null && line.startsWith(RegExp(r'\s')) && line.trim().isNotEmpty) {
        // Indented reason, e.g. "Unplugged or turned off".
        final s = states[last]!;
        states[last] = (enabled: s.enabled, text: '${s.text} · ${line.trim()}');
      }
    }
    return [
      for (final m in RegExp(r'^device for (\S+?):\s*(.*)$', multiLine: true).allMatches(devices))
        InstalledPrinter(
          name: m.group(1)!,
          device: m.group(2)!.trim(),
          isDefault: m.group(1) == def,
          enabled: states[m.group(1)]?.enabled ?? true,
          status: states[m.group(1)]?.text,
        ),
    ];
  }

  static Future<List<InstalledPrinter>> _listWindows() async {
    const script =
        r'[Console]::OutputEncoding = [Text.Encoding]::UTF8; '
        r'$p = @(Get-CimInstance Win32_Printer | Select-Object Name,DriverName,PortName,Default,WorkOffline,PrinterStatus); '
        r'ConvertTo-Json -InputObject $p -Compress';
    final ProcessResult r;
    try {
      r = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ], stdoutEncoding: utf8);
    } on ProcessException {
      throw const OsPrinterException('PowerShell is not available');
    }
    if (r.exitCode != 0) {
      throw OsPrinterException(clean('${r.stderr}', 'Could not read the printer list (${r.exitCode})'));
    }
    return parseWindows('${r.stdout}');
  }

  /// Parses `Win32_Printer` rows as JSON (an array, or one object).
  static List<InstalledPrinter> parseWindows(String json) {
    final text = json.trim();
    if (text.isEmpty) return const [];
    final decoded = jsonDecode(text);
    final rows = decoded is List ? decoded : [decoded];
    return [
      for (final row in rows.whereType<Map>())
        if (row['Name'] is String)
          InstalledPrinter(
            name: row['Name'] as String,
            device: row['PortName'] as String?,
            driver: row['DriverName'] as String?,
            isDefault: row['Default'] == true,
            enabled: row['WorkOffline'] != true,
            status: row['WorkOffline'] == true ? 'Offline' : _winStatus(row['PrinterStatus']),
          ),
    ];
  }

  static String? _winStatus(Object? code) => switch (code) {
    3 => 'Idle',
    4 => 'Printing',
    5 => 'Warming up',
    6 => 'Stopped',
    7 => 'Offline',
    _ => null,
  };

  /// `lpadmin`, retried with the admin password prompt when not allowed.
  static Future<ProcessResult> _lpadmin(List<String> args) async {
    final r = await Process.run('lpadmin', args);
    if (r.exitCode == 0 || !_denied('${r.stderr}${r.stdout}')) return r;
    return asAdmin(['lpadmin', ...args]);
  }

  /// Runs [argv] as administrator: pkexec on Linux, the password dialog on
  /// macOS.
  static Future<ProcessResult> asAdmin(List<String> argv) {
    if (Platform.isMacOS) {
      final cmd = argv.map((a) => "'${a.replaceAll("'", r"'\''")}'").join(' ');
      final script = 'do shell script "${cmd.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}" with administrator privileges';
      return Process.run('osascript', ['-e', script]);
    }
    return Process.run('pkexec', argv, environment: const {'LC_ALL': 'C'});
  }

  /// Runs [command]; on "access denied" runs it again elevated (UAC prompt).
  static Future<ProcessResult> powershellElevated(String command) async {
    final r = await powershell(command);
    if (r.exitCode == 0 || !_denied('${r.stderr}${r.stdout}')) return r;
    // Start-Process -Verb RunAs shows the UAC prompt; the command goes in
    // base64 so no quoting can break it.
    final encoded = base64.encode(_utf16le('\$ErrorActionPreference = "Stop"; $command'));
    return powershell(
      "\$p = Start-Process powershell -Verb RunAs -Wait -PassThru -WindowStyle Hidden "
      "-ArgumentList '-NoProfile','-EncodedCommand','$encoded'; exit \$p.ExitCode",
    );
  }

  static Future<ProcessResult> powershell(String command) =>
      Process.run('powershell', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', command]);

  static List<int> _utf16le(String s) => [
    for (final c in s.codeUnits) ...[c & 0xFF, c >> 8],
  ];

  static bool _denied(String output) {
    final o = output.toLowerCase();
    return o.contains('forbidden') ||
        o.contains('not authorized') ||
        o.contains('access is denied') ||
        o.contains('access denied') ||
        o.contains('permission denied') ||
        o.contains('unauthorized');
  }

  static String clean(String output, String fallback) {
    final lines = output.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    return lines.isEmpty ? fallback : lines.take(3).join(' ');
  }
}

class OsPrinterException implements Exception {
  const OsPrinterException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A printer installed in the operating system (a CUPS queue or a Windows
/// printer), whoever added it.
class InstalledPrinter {
  const InstalledPrinter({
    required this.name,
    this.device,
    this.driver,
    this.status,
    this.isDefault = false,
    this.enabled = true,
  });

  final String name;

  /// Device URI (CUPS) or port name (Windows).
  final String? device;
  final String? driver;
  final String? status;
  final bool isDefault;
  final bool enabled;

  InstalledPrinter withDriver(String? driver) => driver == null || driver.isEmpty
      ? this
      : InstalledPrinter(name: name, device: device, driver: driver, status: status, isDefault: isDefault, enabled: enabled);

  /// Added by this app ("Add to Linux / Windows").
  bool get isUniversalPrint =>
      name.startsWith('UniversalPrint') ||
      name.startsWith('Universal Print') ||
      (device?.contains(SystemPrinterPaths.basePath) ?? false);
}

/// Kept here so this file does not import the IPP server.
abstract final class SystemPrinterPaths {
  static const basePath = '/ipp/print';
}
