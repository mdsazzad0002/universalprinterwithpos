import 'dart:convert';
import 'dart:io';

import 'os_printer_setup.dart';

/// A printer driver installed in the operating system.
class InstalledDriver {
  const InstalledDriver({
    required this.id,
    required this.name,
    this.detail,
    this.usedBy = const [],
    this.isSystem = false,
    this.files = const [],
  });

  /// What [OsDriverSetup.remove] removes: Windows driver name, Linux
  /// package name, or a file path (driver files no package owns).
  final String id;
  final String name;

  /// Manufacturer, version, location.
  final String? detail;

  /// OS printers using it (Windows only; CUPS copies the driver into each
  /// printer, so removing the printer removes its copy).
  final List<String> usedBy;

  /// Part of the OS printing system: removing it breaks every printer.
  final bool isSystem;

  /// Loose driver files (no package) removed together.
  final List<String> files;

  bool get isPackage => files.isEmpty && !Platform.isWindows;
}

/// Lists and removes printer drivers: Windows printer drivers, Linux driver
/// packages (dpkg / apt) and driver files installed by hand, macOS vendor
/// drivers in /Library/Printers.
abstract final class OsDriverSetup {
  static bool get isSupported => OsPrinterSetup.canManageInstalled;

  static Future<List<InstalledDriver>> list() async {
    final List<InstalledDriver> all;
    if (Platform.isWindows) {
      all = await _listWindows();
    } else if (Platform.isMacOS) {
      all = await _listMac();
    } else {
      // Backends are left out of the loose files: cups-daemon creates usb,
      // socket, lpd… at install time, so no package owns them.
      all = [...await _listLinuxPackages(), ...await _listLooseFiles(_linuxDirs.where((d) => !d.endsWith('/backend')).toList())];
    }
    all.sort((a, b) {
      if (a.isSystem != b.isSystem) return a.isSystem ? 1 : -1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return all;
  }

  /// What else goes when [d] is removed (apt: packages that depend on it).
  /// Empty when nothing else is affected or it cannot be known.
  static Future<List<String>> alsoRemoved(InstalledDriver d) async {
    if (!d.isPackage) return const [];
    try {
      final r = await Process.run('apt-get', ['-s', 'remove', d.id], environment: _cEnv);
      return parseAptSimulation('${r.stdout}').where((p) => p != d.id).toList();
    } on ProcessException {
      return const [];
    }
  }

  static Future<SetupResult> remove(InstalledDriver d) async {
    try {
      final ProcessResult r;
      if (Platform.isWindows) {
        final name = OsPrinterSetup.psQuote(d.id);
        r = await OsPrinterSetup.powershellElevated(
          "Get-PrinterDriver -Name '$name' | Remove-PrinterDriver -RemoveFromDriverStore -ErrorAction Stop",
        );
      } else if (d.isPackage) {
        r = await OsPrinterSetup.asAdmin(['apt-get', 'remove', '-y', d.id]);
      } else {
        r = await OsPrinterSetup.asAdmin(['rm', '-rf', '--', ...d.files]);
      }
      if (r.exitCode != 0) {
        final out = '${r.stderr}${r.stdout}';
        final inUse = out.toLowerCase().contains('in use') || out.contains('0x80070bcb');
        return (
          ok: false,
          message: inUse
              ? '"${d.name}" is used by a printer: remove ${d.usedBy.isEmpty ? 'that printer' : d.usedBy.join(', ')} first'
              : OsPrinterSetup.clean(out, 'Could not remove "${d.name}" (${r.exitCode})'),
        );
      }
      return (ok: true, message: 'Driver "${d.name}" removed');
    } on ProcessException catch (e) {
      return (ok: false, message: '${e.executable} is not available');
    }
  }

  static const _cEnv = {'LC_ALL': 'C', 'LANG': 'C'};

  // --- Windows ---------------------------------------------------------------

  static Future<List<InstalledDriver>> _listWindows() async {
    const script =
        r'[Console]::OutputEncoding = [Text.Encoding]::UTF8; '
        r'$used = @{}; Get-CimInstance Win32_Printer | ForEach-Object { $used[$_.DriverName] += @($_.Name) }; '
        r'$d = @(Get-PrinterDriver | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Manufacturer = $_.Manufacturer; '
        r'Environment = $_.PrinterEnvironment; Inf = $_.InfPath; UsedBy = @($used[$_.Name] | Where-Object { $_ }) } }); '
        r'ConvertTo-Json -InputObject $d -Compress -Depth 3';
    final r = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ], stdoutEncoding: utf8);
    if (r.exitCode != 0) {
      throw OsPrinterException(OsPrinterSetup.clean('${r.stderr}', 'Could not read the driver list (${r.exitCode})'));
    }
    return parseWindowsDrivers('${r.stdout}');
  }

  static List<InstalledDriver> parseWindowsDrivers(String json) {
    final text = json.trim();
    if (text.isEmpty) return const [];
    final decoded = jsonDecode(text);
    final rows = decoded is List ? decoded : [decoded];
    return [
      for (final row in rows.whereType<Map>())
        if (row['Name'] is String)
          InstalledDriver(
            id: row['Name'] as String,
            name: row['Name'] as String,
            detail: [row['Manufacturer'], row['Environment']].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
            usedBy: [
              for (final u in (row['UsedBy'] is List ? row['UsedBy'] as List : [row['UsedBy']]))
                if (u is String) u,
            ],
            // Built into Windows (IPP Class Driver, Print to PDF, XPS…).
            isSystem:
                (row['Manufacturer'] as String? ?? '').startsWith('Microsoft') ||
                (row['Inf'] as String? ?? '').toLowerCase().contains(r'\ntprint.inf'),
          ),
    ];
  }

  // --- Linux -----------------------------------------------------------------

  /// Where CUPS finds drivers (filters, PPDs, PPD generators, backends).
  static const _linuxDirs = [
    '/usr/lib/cups/filter',
    '/usr/lib/cups/backend',
    '/usr/lib/cups/driver',
    '/usr/share/ppd',
    '/usr/share/cups/model',
    '/usr/share/cups/drv',
    '/usr/local/share/ppd',
  ];

  /// The printing system itself and common add-ons that are not drivers.
  static const _corePackages = {
    'cups',
    'cups-bsd',
    'cups-client',
    'cups-common',
    'cups-core-drivers',
    'cups-daemon',
    'cups-filters',
    'cups-filters-core-drivers',
    'cups-ipp-utils',
    'cups-ppdc',
    'cups-server-common',
    'cups-browsed',
    'libcupsfilters2',
    'libppd2',
    'ipp-usb',
    'smbclient',
    'bluez-cups',
    'system-config-printer',
  };

  static Future<List<InstalledDriver>> _listLinuxPackages() async {
    final ProcessResult r;
    try {
      r = await Process.run('dpkg', ['-S', ..._linuxDirs], environment: _cEnv);
    } on ProcessException {
      return const []; // not Debian / Ubuntu: only loose files are listed
    }
    final packages = parseDpkgOwners('${r.stdout}');
    if (packages.isEmpty) return const [];
    final versions = <String, String>{};
    try {
      final q = await Process.run('dpkg-query', ['-W', '-f', r'${Package}\t${Version}\n', ...packages], environment: _cEnv);
      for (final line in '${q.stdout}'.split('\n')) {
        final parts = line.split('\t');
        if (parts.length == 2) versions[parts[0]] = parts[1];
      }
    } on ProcessException {
      // versions are optional
    }
    return [
      for (final p in packages)
        InstalledDriver(id: p, name: p, detail: ['package', ?versions[p]].join(' '), isSystem: _corePackages.contains(p)),
    ];
  }

  /// Package names from `dpkg -S dir...` ("a, b: /dir" lines).
  static List<String> parseDpkgOwners(String output) {
    final names = <String>{};
    for (final line in output.split('\n')) {
      final i = line.lastIndexOf(': /');
      if (i <= 0) continue;
      for (final n in line.substring(0, i).split(',')) {
        final name = n.trim().split(':').first; // drop ":amd64"
        if (name.isNotEmpty && !name.startsWith('diversion')) names.add(name);
      }
    }
    return names.toList()..sort();
  }

  /// Packages `apt-get -s remove` would remove ("Remv name [version]").
  static List<String> parseAptSimulation(String output) => [
    for (final m in RegExp(r'^Remv (\S+)', multiLine: true).allMatches(output)) m.group(1)!,
  ];

  /// Driver files in [dirs] that no package owns: installed by a vendor
  /// script (install.sh) or by hand.
  static Future<List<InstalledDriver>> _listLooseFiles(List<String> dirs) async {
    final files = <String>[];
    for (final dir in dirs) {
      final d = Directory(dir);
      if (!await d.exists()) continue;
      try {
        await for (final e in d.list(followLinks: false)) {
          // An empty folder is no driver.
          if (e is Directory && await e.list().isEmpty) continue;
          files.add(e.path);
        }
      } on FileSystemException {
        continue;
      }
    }
    if (files.isEmpty) return const [];
    Set<String> owned;
    try {
      final r = await Process.run('dpkg', ['-S', ...files], environment: _cEnv);
      owned = {
        for (final line in '${r.stdout}'.split('\n'))
          if (line.lastIndexOf(': /') > 0) line.substring(line.lastIndexOf(': /') + 2).trim(),
      };
    } on ProcessException {
      try {
        // rpm: owned files print a package name, others "is not owned".
        owned = {};
        for (final f in files) {
          final r = await Process.run('rpm', ['-qf', f], environment: _cEnv);
          if (r.exitCode == 0) owned.add(f);
        }
      } on ProcessException {
        return const []; // no package manager to tell vendor files apart
      }
    }
    return [
      for (final f in files)
        if (!owned.contains(f))
          InstalledDriver(id: f, name: f.split('/').last, detail: 'File installed without a package · $f', files: [f]),
    ];
  }

  // --- macOS -----------------------------------------------------------------

  /// Everything under /Library/Printers is a vendor driver (Apple's own live
  /// in /System).
  static Future<List<InstalledDriver>> _listMac() async {
    final out = <InstalledDriver>[];
    final root = Directory('/Library/Printers');
    if (!await root.exists()) return out;
    await for (final e in root.list(followLinks: false)) {
      final name = e.path.split('/').last;
      if (name == 'PPDs' || name.startsWith('.')) continue;
      out.add(InstalledDriver(id: e.path, name: name, detail: e.path, files: [e.path]));
    }
    final ppds = Directory('/Library/Printers/PPDs/Contents/Resources');
    if (await ppds.exists()) {
      await for (final e in ppds.list(followLinks: false)) {
        final name = e.path.split('/').last.replaceAll(RegExp(r'\.gz$'), '').replaceAll(RegExp(r'\.ppd$'), '');
        out.add(InstalledDriver(id: e.path, name: name, detail: 'PPD · ${e.path}', files: [e.path]));
      }
    }
    return out;
  }
}
