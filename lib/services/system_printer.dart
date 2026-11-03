import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';

import '../core/ipp/ipp_message.dart';
import '../core/ipp/mini_http_server.dart';
import '../core/raster/page_raster.dart';
import '../data/database.dart';
import '../data/models/print_job.dart';
import '../data/models/printer.dart';
import 'print_service.dart';
import 'printer_store.dart';

/// Makes Universal Print a normal, driverless system printer:
///
/// * an IPP Everywhere / AirPrint printer (`ipp://<host>:8631/ipp/print`)
///   that Windows (Microsoft IPP Class Driver), Linux (CUPS `everywhere`),
///   macOS / iOS (AirPrint) and Android (Default Print Service) print to
///   without any vendor driver. Every receipt / label printer configured in
///   the app is one queue, `/ipp/print` is the default printer.
/// * optionally a RAW port (9100) for POS software that prints through the
///   "Generic / Text Only" driver or sends ESC/POS itself.
///
/// Pages arrive as PWG / Apple raster, are scaled to the paper width,
/// converted to black and white and go through the normal print queue.
/// Android's own print framework uses [submitPages] directly
/// (`UniversalPrintService.kt`).
class SystemPrinter extends ChangeNotifier {
  SystemPrinter({
    required this._settings,
    required this._printService,
    required this._printers,
    PrinterAdvertiser? advertiser,
  }) : _advertiser = advertiser ?? BonsoirAdvertiser();

  final SettingsRepository _settings;
  final PrintService _printService;
  final PrinterStore _printers;
  final PrinterAdvertiser _advertiser;

  static const defaultPort = 8631;
  static const rawPort = 9100;
  static const basePath = '/ipp/print';
  static const maxDocumentBytes = 64 * 1024 * 1024;
  static const _keepJobs = 50;

  /// IPP server on/off. On by default on computers (loopback only, unless
  /// [lanAccess]), so the OS printers of the app work.
  bool enabled = false;
  int port = defaultPort;

  /// Reachable from other devices (and advertised on the network). When
  /// false (the default) only this device can print to it (127.0.0.1).
  bool lanAccess = false;

  /// RAW (JetDirect) port 9100 → default printer.
  bool rawEnabled = false;

  /// Open the cash drawer with every system-printer job. Programs printing
  /// through a driver cannot say "paid in cash", so a receipt printer set to
  /// *Open on cash payments* would otherwise never open it from here. Off:
  /// the printer's own drawer setting applies.
  bool openDrawer = false;

  String? lastError;
  String? rawError;
  String? discoveryError;
  bool get discoveryActive => _advertiser.isActive;

  MiniHttpServer? _server;
  ServerSocket? _raw;
  String _uuidSeed = '';
  final _started = DateTime.now();
  final _jobs = <int, _IppJob>{};
  int _nextJobId = 1;
  String _advertised = '';

  bool get isRunning => _server != null;

  bool get isRawRunning => _raw != null;

  int? get boundPort => _server?.port;

  /// Printers that can be used as system printers. A4 / IPP printers are
  /// already driverless network printers and are not re-shared.
  List<Printer> get sharedPrinters => [
    for (final p in _printers.printers)
      if (!p.isDocument) p,
  ];

  Printer? get defaultShared {
    final d = _printers.defaultPrinter;
    return d != null && !d.isDocument ? d : (sharedPrinters.isEmpty ? null : sharedPrinters.first);
  }

  static String queuePath(Printer printer) => '$basePath/${printer.id}';

  /// What a client on this device uses.
  String localUri(Printer? printer, {String scheme = 'ipp'}) =>
      '$scheme://127.0.0.1:${boundPort ?? port}${printer == null ? basePath : queuePath(printer)}';

  String uriFor(String host, Printer? printer, {String scheme = 'ipp'}) =>
      '$scheme://$host:${boundPort ?? port}${printer == null ? basePath : queuePath(printer)}';

  Future<void> init() async {
    // On unless turned off: the OS printers added for the app print here.
    // Android prints through its print service and needs no server.
    final saved = await _settings.get('sys_enabled');
    enabled = saved == null ? !Platform.isAndroid : saved == 'true';
    port = int.tryParse(await _settings.get('sys_port') ?? '') ?? defaultPort;
    // Off unless turned on: anyone on the Wi-Fi could print otherwise.
    lanAccess = (await _settings.get('sys_lan')) == 'true';
    rawEnabled = (await _settings.get('sys_raw')) == 'true';
    openDrawer = (await _settings.get('sys_drawer')) == 'true';
    _uuidSeed = await _settings.get('sys_uuid') ?? '';
    if (_uuidSeed.isEmpty) {
      _uuidSeed = newToken();
      await _settings.set('sys_uuid', _uuidSeed);
    }
    _printers.addListener(_onPrintersChanged);
    if (enabled) await start();
  }

  Future<void> configure({bool? enabled, int? port, bool? lanAccess, bool? rawEnabled, bool? openDrawer}) async {
    if (openDrawer != null) {
      this.openDrawer = openDrawer;
      await _settings.set('sys_drawer', '$openDrawer');
      notifyListeners();
      if (enabled == null && port == null && lanAccess == null && rawEnabled == null) return;
    }
    if (enabled != null) {
      this.enabled = enabled;
      await _settings.set('sys_enabled', '$enabled');
    }
    if (port != null) {
      this.port = port;
      await _settings.set('sys_port', '$port');
    }
    if (lanAccess != null) {
      this.lanAccess = lanAccess;
      await _settings.set('sys_lan', '$lanAccess');
    }
    if (rawEnabled != null) {
      this.rawEnabled = rawEnabled;
      await _settings.set('sys_raw', '$rawEnabled');
    }
    this.enabled ? await start() : await stop();
  }

  Future<void> start() async {
    await stop();
    try {
      _server = await _bind((address) => MiniHttpServer.bind(address, port, _handle, maxBodyBytes: maxDocumentBytes));
      lastError = null;
    } on SocketException catch (e) {
      lastError = 'Cannot start on port $port: ${e.osError?.message ?? e.message}';
    }
    if (_server != null && rawEnabled) {
      try {
        final raw = await _bind((address) => ServerSocket.bind(address, rawPort, v6Only: false));
        raw.listen(_onRawClient);
        _raw = raw;
        rawError = null;
      } on SocketException catch (e) {
        rawError = 'Cannot open port $rawPort: ${e.osError?.message ?? e.message}';
      }
    }
    notifyListeners();
    await _advertise();
  }

  /// Dual-stack on all interfaces for LAN access (so "localhost" works
  /// whether it resolves to ::1 or 127.0.0.1), loopback otherwise.
  Future<T> _bind<T>(Future<T> Function(InternetAddress) bind) async {
    if (!lanAccess) return bind(InternetAddress.loopbackIPv4);
    try {
      return await bind(InternetAddress.anyIPv6);
    } on SocketException {
      return bind(InternetAddress.anyIPv4);
    }
  }

  Future<void> stop() async {
    final server = _server, raw = _raw;
    _server = null;
    _raw = null;
    await server?.close();
    await raw?.close();
    _advertised = '';
    await _advertiser.stop();
    notifyListeners();
  }

  void _onPrintersChanged() {
    if (isRunning) unawaited(_advertise());
  }

  Future<void> _advertise() async {
    final queues = !isRunning || !lanAccess ? const <Printer>[] : sharedPrinters;
    final def = defaultShared;
    final key = '${boundPort ?? port}|${queues.map((p) => '${p.id}:${p.name}:${p.paperWidth}:${p.id == def?.id}').join(',')}';
    if (key == _advertised) return;
    _advertised = key;
    await _advertiser.stop();
    if (queues.isEmpty) {
      discoveryError = null;
      notifyListeners();
      return;
    }
    try {
      final host = Platform.localHostname.split('.').first;
      await _advertiser.publish([
        for (final p in queues)
          AdvertisedPrinter(
            name: _serviceName('${p.name} @ $host'),
            port: boundPort ?? port,
            txt: _txtRecord(p, isDefault: p.id == def?.id),
          ),
      ]);
      discoveryError = null;
    } catch (e) {
      discoveryError = 'Network discovery unavailable ($e). Add the printer by its address instead.';
    }
    notifyListeners();
  }

  /// DNS-SD instance names are at most 63 bytes.
  static String _serviceName(String name) {
    var n = name;
    while (utf8.encode(n).length > 63) {
      n = n.substring(0, n.length - 1);
    }
    return n;
  }

  Map<String, String> _txtRecord(Printer p, {required bool isDefault}) => {
    'txtvers': '1',
    'qtotal': '1',
    'rp': queuePath(p).substring(1),
    'ty': 'Universal Print ${p.name}',
    'product': '(Universal Print)',
    'note': p.paperLabel,
    'adminurl': 'http://${Platform.localHostname}:${boundPort ?? port}/',
    'priority': isDefault ? '10' : '50',
    'pdl': 'application/octet-stream,image/pwg-raster,image/urf',
    'URF': _urf(p).join(','),
    'UUID': _uuid(p),
    'Color': 'F',
    'Duplex': 'F',
    'Copies': 'T',
    'kind': p.isLabel ? 'label' : 'receipt,roll',
    'PaperMax': '<legal-A4',
  };

  // ---------------------------------------------------------------- RAW 9100

  void _onRawClient(Socket socket) {
    final data = BytesBuilder(copy: false);
    Timer? idle;
    void finish() {
      idle?.cancel();
      socket.destroy();
      final bytes = data.takeBytes();
      if (bytes.isNotEmpty) unawaited(_submitRaw(bytes));
    }

    // Windows keeps the connection open until the whole job is sent;
    // some POS programs never close it, so silence also ends the job.
    void arm() {
      idle?.cancel();
      idle = Timer(const Duration(seconds: 3), finish);
    }

    arm();
    var done = false;
    socket.listen(
      (chunk) {
        if (data.length + chunk.length > maxDocumentBytes) return;
        data.add(chunk);
        arm();
      },
      onDone: () {
        if (done) return;
        done = true;
        finish();
      },
      onError: (_) {
        if (done) return;
        done = true;
        finish();
      },
      cancelOnError: true,
    );
  }

  Future<void> _submitRaw(Uint8List bytes) async {
    final printer = defaultShared;
    if (printer == null) {
      rawError = 'RAW job received but no receipt / label printer is set up';
      notifyListeners();
      return;
    }
    try {
      await _printService.submit({
        'printer_id': printer.id,
        'document_type': 'raw',
        'data': base64.encode(bytes),
        ..._drawer,
      }, source: 'system');
      if (rawError != null) {
        rawError = null;
        notifyListeners();
      }
    } on PrintRequestException catch (e) {
      rawError = e.message;
      notifyListeners();
    }
  }

  /// Added to every job; label printers ignore it (no drawer).
  Map<String, Object> get _drawer => openDrawer ? const {'open_drawer': true} : const {};

  // ----------------------------------------------------------- page pipeline

  /// Prints rendered pages (any width; scaled to the paper) on [printer].
  /// Receipts become one job, blank space at the bottom of every page is
  /// trimmed; labels print one label per page. Returns the job ids.
  Future<List<String>> submitPages(
    Printer printer,
    List<GrayPage> pages, {
    int copies = 1,
    String? jobName,
    String source = 'system',
  }) async {
    final dots = printer.geometry().dotsPerLine;
    final label = printer.isLabel;
    final pngs = await Isolate.run(() => renderPages(pages, dots: dots, trim: !label));
    return _submitPngs(printer, pngs, copies: copies, jobName: jobName, source: source);
  }

  /// Scaled, black/white, 1-bit PNG per page. Blank pages are dropped
  /// (unless every page is blank).
  static List<Uint8List> renderPages(List<GrayPage> pages, {required int dots, required bool trim}) {
    final out = <Uint8List>[];
    Uint8List? blank;
    for (final page in pages) {
      final mono = page.scaledToWidth(dots).toMono();
      if (trim) {
        final t = trimBottom(mono);
        if (t.height <= 8 + 1 && !t.data.any((b) => b != 0)) {
          blank ??= encodeMonoPng(t);
          continue;
        }
        out.add(encodeMonoPng(t));
      } else {
        out.add(encodeMonoPng(mono));
      }
    }
    if (out.isEmpty && blank != null) out.add(blank);
    return out;
  }

  Future<List<String>> _submitPngs(
    Printer printer,
    List<Uint8List> pngs, {
    required int copies,
    String? jobName,
    required String source,
  }) async {
    if (pngs.isEmpty) throw PrintRequestException('The document has no pages');
    Map<String, dynamic> payload(List<Uint8List> pages) => {
      'printer_id': printer.id,
      'document_type': 'elements',
      'job_name': ?jobName,
      'copies': copies.clamp(1, PrintService.maxCopies),
      ..._drawer,
      'elements': [
        for (final png in pages) {'type': 'image', 'base64': base64.encode(png), 'align': 'left'},
      ],
    };
    final ids = <String>[];
    if (printer.isLabel) {
      for (final png in pngs) {
        ids.add((await _printService.submit(payload([png]), source: source)).job.id);
      }
    } else {
      ids.add((await _printService.submit(payload(pngs), source: source)).job.id);
    }
    return ids;
  }

  /// Waits until every job in [ids] left the queue. Null when all printed,
  /// else the error.
  Future<String?> waitForJobs(List<String> ids, {Duration timeout = const Duration(minutes: 2)}) async {
    final end = DateTime.now().add(timeout);
    for (final id in ids) {
      while (true) {
        final job = await _printService.find(id);
        if (job == null) return 'Job disappeared';
        if (job.status == JobStatus.completed) break;
        if (job.status == JobStatus.failed) return job.error ?? 'Printing failed';
        if (job.status == JobStatus.cancelled) return 'Cancelled';
        if (DateTime.now().isAfter(end)) return 'Printer did not finish in time';
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    return null;
  }

  // -------------------------------------------------------------- IPP server

  Future<MiniResponse> _handle(MiniRequest req) async {
    if (req.method == 'GET' || req.method == 'HEAD') return _statusPage(req);
    if (req.method != 'POST') return MiniResponse.text(405, 'Method not allowed');
    if (!(req.headers['content-type'] ?? '').toLowerCase().startsWith('application/ipp')) {
      return MiniResponse.text(415, 'Expected application/ipp');
    }
    IppMessage request;
    try {
      request = IppMessage.decode(req.body);
    } on IppFormatException catch (e) {
      return MiniResponse.text(400, e.message);
    }
    final response = await handleIpp(request, path: req.path, host: req.host ?? '127.0.0.1');
    return MiniResponse(200, response.encode(), contentType: 'application/ipp');
  }

  /// Answers one IPP request sent to [path]. Public for tests.
  Future<IppMessage> handleIpp(IppMessage request, {required String path, required String host}) async {
    final groups = <IppGroup>[
      IppGroup(IppTag.operationGroup, [
        IppAttribute.charset('attributes-charset', ['utf-8']),
        IppAttribute.language('attributes-natural-language', ['en']),
      ]),
    ];
    IppMessage reply(int status, [String? message]) {
      if (message != null) groups.first.add(IppAttribute.text('status-message', message));
      return IppMessage(
        major: request.major > 2 ? 2 : request.major,
        minor: request.major > 2 ? 0 : request.minor,
        code: status,
        requestId: request.requestId,
        groups: groups,
      );
    }

    if (request.major < 1 || request.major > 2) return reply(IppStatus.versionNotSupported);

    // The printer-uri attribute names the queue; fall back to the HTTP path.
    final uriPath = Uri.tryParse(request.operation('printer-uri')?.string ?? '')?.path;
    final printer = _queue(uriPath != null && uriPath.startsWith(basePath) ? uriPath : path);
    if (printer == null) {
      return reply(IppStatus.notFound, sharedPrinters.isEmpty ? 'No receipt or label printer is set up' : 'No such printer queue');
    }
    final printerUri = uriFor(_uriHost(host), _isDefaultPath(uriPath ?? path) ? null : printer);

    try {
      switch (request.code) {
        case IppOp.getPrinterAttributes:
          final requested = request.operation('requested-attributes')?.values.whereType<String>().toSet();
          groups.add(IppGroup(IppTag.printerGroup, _filter(_printerAttributes(printer, printerUri, host), requested)));
          return reply(IppStatus.ok);

        case IppOp.validateJob:
          final format = request.operation('document-format')?.string ?? 'application/octet-stream';
          if (!_formats.contains(format)) return reply(IppStatus.documentFormatNotSupported, 'Unsupported format $format');
          return reply(IppStatus.ok);

        case IppOp.printJob || IppOp.createJob:
          final format = request.operation('document-format')?.string ?? 'application/octet-stream';
          if (!_formats.contains(format)) return reply(IppStatus.documentFormatNotSupported, 'Unsupported format $format');
          final job = _newJob(request, printer, printerUri, format);
          if (request.code == IppOp.printJob) {
            final error = await _process(job, request.data);
            if (error != null) return _jobReply(reply, groups, job, error.$1, error.$2);
          }
          return _jobReply(reply, groups, job, IppStatus.ok, null);

        case IppOp.sendDocument:
          final job = _findJob(request);
          if (job == null) return reply(IppStatus.notFound, 'No such job');
          if (job.state != _IppJob.held) return reply(IppStatus.notPossible, 'Job already has a document');
          final format = request.operation('document-format')?.string;
          if (format != null) {
            if (!_formats.contains(format)) return reply(IppStatus.documentFormatNotSupported, 'Unsupported format $format');
            job.format = format;
          }
          job.buffer.add(request.data);
          final last = request.operation('last-document')?.value != false;
          if (last) {
            final error = await _process(job, job.buffer.takeBytes());
            if (error != null) return _jobReply(reply, groups, job, error.$1, error.$2);
          }
          return _jobReply(reply, groups, job, IppStatus.ok, null);

        case IppOp.closeJob:
          final job = _findJob(request);
          if (job == null) return reply(IppStatus.notFound, 'No such job');
          if (job.state == _IppJob.held && job.buffer.length > 0) {
            final error = await _process(job, job.buffer.takeBytes());
            if (error != null) return _jobReply(reply, groups, job, error.$1, error.$2);
          }
          return _jobReply(reply, groups, job, IppStatus.ok, null);

        case IppOp.cancelJob:
          final job = _findJob(request);
          if (job == null) return reply(IppStatus.notFound, 'No such job');
          await _refresh(job);
          if (job.state >= _IppJob.canceled) return reply(IppStatus.notPossible, 'Job is already finished');
          for (final id in job.printJobIds) {
            await _printService.cancel(id);
          }
          job.state = _IppJob.canceled;
          return reply(IppStatus.ok);

        case IppOp.getJobAttributes:
          final job = _findJob(request);
          if (job == null) return reply(IppStatus.notFound, 'No such job');
          await _refresh(job);
          groups.add(IppGroup(IppTag.jobGroup, _jobAttributes(job)));
          return reply(IppStatus.ok);

        case IppOp.getJobs:
          final which = request.operation('which-jobs')?.string ?? 'not-completed';
          final limit = request.operation('limit')?.integer ?? 1000;
          final jobs = _jobs.values.where((j) => j.printerId == printer.id).toList().reversed;
          var n = 0;
          for (final job in jobs) {
            await _refresh(job);
            final done = job.state >= _IppJob.canceled;
            if ((which == 'completed') != done) continue;
            if (n++ >= limit) break;
            groups.add(IppGroup(IppTag.jobGroup, _jobAttributes(job)));
          }
          return reply(IppStatus.ok);

        case IppOp.identifyPrinter:
          return reply(IppStatus.ok);

        default:
          return reply(IppStatus.operationNotSupported);
      }
    } catch (e) {
      return reply(IppStatus.internalError, '$e');
    }
  }

  IppMessage _jobReply(
    IppMessage Function(int, [String?]) reply,
    List<IppGroup> groups,
    _IppJob job,
    int status,
    String? message,
  ) {
    groups.add(IppGroup(IppTag.jobGroup, [
      IppAttribute.integer('job-id', [job.id]),
      IppAttribute.uri('job-uri', [job.uri]),
      IppAttribute.enumeration('job-state', [job.state]),
      IppAttribute.keyword('job-state-reasons', [job.reason]),
    ]));
    return reply(status, message);
  }

  static const _formats = {
    'application/octet-stream',
    'image/pwg-raster',
    'image/urf',
    'application/vnd.cups-raw',
    'text/plain',
  };

  Printer? _queue(String path) {
    var p = path;
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    if (_isDefaultPath(p)) return defaultShared;
    if (!p.startsWith('$basePath/')) return null;
    final printer = _printers.byId(p.substring(basePath.length + 1));
    return printer == null || printer.isDocument ? null : printer;
  }

  static bool _isDefaultPath(String path) => path == basePath || path == '$basePath/' || path == '/' || path.isEmpty;

  static String _uriHost(String host) => host.isEmpty ? '127.0.0.1' : host;

  _IppJob _newJob(IppMessage request, Printer printer, String printerUri, String format) {
    final id = _nextJobId++;
    final copies = request.job('copies')?.integer ?? 1;
    final job = _IppJob(
      id: id,
      printerId: printer.id,
      printerUri: printerUri,
      uri: '$printerUri/jobs/$id',
      name: request.operation('job-name')?.string ?? 'Document',
      user: request.operation('requesting-user-name')?.string ?? 'anonymous',
      format: format,
      copies: copies.clamp(1, PrintService.maxCopies),
    );
    _jobs[id] = job;
    while (_jobs.length > _keepJobs) {
      _jobs.remove(_jobs.keys.first);
    }
    return job;
  }

  _IppJob? _findJob(IppMessage request) {
    var id = request.operation('job-id')?.integer;
    if (id == null) {
      final uri = request.operation('job-uri')?.string;
      if (uri != null) id = int.tryParse(uri.split('/').last);
    }
    return id == null ? null : _jobs[id];
  }

  /// Turns the document into print jobs. Null on success, else IPP status
  /// and message.
  Future<(int, String)?> _process(_IppJob job, Uint8List data) async {
    final printer = _printers.byId(job.printerId);
    if (printer == null) {
      job.abort('Printer was deleted');
      return (IppStatus.notFound, 'Printer was deleted');
    }
    try {
      job.state = _IppJob.processing;
      final kind = _sniff(job.format, data);
      switch (kind) {
        case _DocKind.raster:
          final dots = printer.geometry().dotsPerLine;
          final label = printer.isLabel;
          final pngs = await Isolate.run(
            () => renderPages(RasterDecoder.decode(data, targetWidth: dots), dots: dots, trim: !label),
          );
          job.printJobIds.addAll(await _submitPngs(printer, pngs, copies: job.copies, jobName: job.name, source: 'system'));
        case _DocKind.text:
          final r = await _printService.submit({
            'printer_id': printer.id,
            'document_type': 'text',
            'content': utf8.decode(data, allowMalformed: true).replaceAll('\r\n', '\n').replaceAll('\f', '\n'),
            'copies': job.copies,
            ..._drawer,
          }, source: 'system');
          job.printJobIds.add(r.job.id);
        case _DocKind.raw:
          final r = await _printService.submit({
            'printer_id': printer.id,
            'document_type': 'raw',
            'data': base64.encode(data),
            'copies': job.copies,
            ..._drawer,
          }, source: 'system');
          job.printJobIds.add(r.job.id);
        case _DocKind.pdf:
          job.abort('PDF is not supported');
          return (IppStatus.documentFormatNotSupported, 'Send PWG or Apple raster, not PDF');
        case _DocKind.empty:
          job.abort('Empty document');
          return (IppStatus.badRequest, 'The document is empty');
      }
      job.state = _IppJob.pending;
      return null;
    } on RasterFormatException catch (e) {
      job.abort(e.message);
      return (IppStatus.badRequest, e.message);
    } on PrintRequestException catch (e) {
      job.abort(e.message);
      return (IppStatus.notPossible, e.message);
    }
  }

  static _DocKind _sniff(String format, Uint8List data) {
    if (data.isEmpty) return _DocKind.empty;
    if (RasterDecoder.isPwg(data) || RasterDecoder.isUrf(data)) return _DocKind.raster;
    if (RasterDecoder.isPdf(data)) return _DocKind.pdf;
    return format == 'text/plain' ? _DocKind.text : _DocKind.raw;
  }

  Future<void> _refresh(_IppJob job) async {
    if (job.printJobIds.isEmpty || job.state >= _IppJob.canceled) return;
    var allDone = true;
    for (final id in job.printJobIds) {
      final pj = await _printService.find(id);
      switch (pj?.status) {
        case null || JobStatus.failed:
          job.abort(pj?.error ?? 'Job lost');
          return;
        case JobStatus.cancelled:
          job.state = _IppJob.canceled;
          return;
        case JobStatus.completed:
          break;
        case JobStatus.processing || JobStatus.printing:
          job.state = _IppJob.processing;
          allDone = false;
        case JobStatus.pending:
          allDone = false;
      }
    }
    if (allDone) {
      job.state = _IppJob.completed;
      job.completedAt ??= DateTime.now();
    }
  }

  int get _upTime => max(1, DateTime.now().difference(_started).inSeconds);

  List<IppAttribute> _jobAttributes(_IppJob j) => [
    IppAttribute.integer('job-id', [j.id]),
    IppAttribute.uri('job-uri', [j.uri]),
    IppAttribute.uri('job-printer-uri', [j.printerUri]),
    IppAttribute.nameValue('job-name', j.name),
    IppAttribute.nameValue('job-originating-user-name', j.user),
    IppAttribute.enumeration('job-state', [j.state]),
    IppAttribute.keyword('job-state-reasons', [j.reason]),
    if (j.error != null) IppAttribute.text('job-state-message', j.error!),
    IppAttribute.mime('document-format', [j.format]),
    IppAttribute.integer('copies', [j.copies]),
    IppAttribute.integer('job-printer-up-time', [_upTime]),
    IppAttribute.integer('time-at-creation', [max(1, j.createdAt.difference(_started).inSeconds)]),
    j.completedAt == null
        ? IppAttribute.noValue('time-at-completed')
        : IppAttribute.integer('time-at-completed', [max(1, j.completedAt!.difference(_started).inSeconds)]),
  ];

  static List<IppAttribute> _filter(List<IppAttribute> all, Set<String>? requested) {
    if (requested == null || requested.isEmpty || requested.contains('all')) return all;
    if (requested.contains('printer-description') || requested.contains('job-template')) return all;
    return [
      for (final a in all)
        if (requested.contains(a.name)) a,
    ];
  }

  static int _dpi(Printer p) => p.geometry().dpi;

  static List<int> _resolutions(Printer p) => {_dpi(p), 300}.toList();

  static List<String> _urf(Printer p) => [
    'V1.4',
    'W8',
    'SRGB24',
    'CP1',
    'IS1',
    'MT1-3-7',
    'RS${_resolutions(p).join('-')}',
  ];

  String _uuid(Printer p) {
    var h = 0xcbf29ce484222325;
    final out = StringBuffer();
    for (var round = 0; out.length < 32; round++) {
      for (final c in '$_uuidSeed:${p.id}:$round'.codeUnits) {
        h = (h ^ c) * 0x100000001b3 & 0x7FFFFFFFFFFFFFFF;
      }
      out.write(h.toRadixString(16).padLeft(16, '0'));
    }
    final s = out.toString().substring(0, 32);
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-4${s.substring(13, 16)}-a${s.substring(17, 20)}-${s.substring(20, 32)}';
  }

  /// Media the client may lay pages out on. Receipts: the roll (default),
  /// plus A4 / Letter for apps that insist; those are scaled to the roll.
  static List<({String name, int x, int y})> _media(Printer p) {
    final w = p.paperWidth;
    if (p.isLabel) {
      final h = p.labelHeight ?? p.paperWidth;
      return [(name: 'om_${w}x$h-label_${w}x${h}mm', x: w * 100, y: h * 100)];
    }
    return [
      (name: 'om_${w}mm-roll_${w}x297mm', x: w * 100, y: 29700),
      (name: 'iso_a4_210x297mm', x: 21000, y: 29700),
      (name: 'na_letter_8.5x11in', x: 21590, y: 27940),
    ];
  }

  List<IppAttribute> _printerAttributes(Printer p, String printerUri, String host) {
    final media = _media(p);
    final resolutions = [for (final r in _resolutions(p)) IppResolution(r, r)];
    final mediaType = p.isLabel ? 'labels' : 'continuous';
    IppCollection size(({String name, int x, int y}) m) => IppCollection([
      IppAttribute.integer('x-dimension', [m.x]),
      IppAttribute.integer('y-dimension', [m.y]),
    ]);
    IppCollection col(({String name, int x, int y}) m) => IppCollection([
      IppAttribute.collection('media-size', [size(m)]),
      IppAttribute.integer('media-bottom-margin', [0]),
      IppAttribute.integer('media-left-margin', [0]),
      IppAttribute.integer('media-right-margin', [0]),
      IppAttribute.integer('media-top-margin', [0]),
      IppAttribute.keyword('media-source', ['main']),
      IppAttribute.keyword('media-type', [mediaType]),
    ]);
    final active = _printService.recentJobs.where((j) => j.printerId == p.id && j.status.isActive).length;
    final model = p.isLabel ? 'Label printer' : 'Receipt printer';
    return [
      IppAttribute.charset('charset-configured', ['utf-8']),
      IppAttribute.charset('charset-supported', ['utf-8', 'us-ascii']),
      IppAttribute.boolean('color-supported', false),
      IppAttribute.keyword('compression-supported', ['none']),
      IppAttribute.integer('copies-default', [1]),
      IppAttribute.range('copies-supported', 1, PrintService.maxCopies),
      IppAttribute.mime('document-format-default', ['application/octet-stream']),
      IppAttribute.mime('document-format-supported', _formats.toList()),
      IppAttribute.language('generated-natural-language-supported', ['en']),
      IppAttribute.keyword('identify-actions-supported', ['display']),
      IppAttribute.keyword('ipp-features-supported', ['ipp-everywhere']),
      IppAttribute.keyword('ipp-versions-supported', ['1.1', '2.0']),
      IppAttribute.keyword('job-creation-attributes-supported', [
        'copies',
        'media',
        'media-col',
        'orientation-requested',
        'output-bin',
        'print-color-mode',
        'print-quality',
        'print-scaling',
        'printer-resolution',
        'sides',
      ]),
      IppAttribute.integer('media-bottom-margin-supported', [0]),
      IppAttribute.collection('media-col-database', [for (final m in media) col(m)]),
      IppAttribute.collection('media-col-default', [col(media.first)]),
      IppAttribute.collection('media-col-ready', [col(media.first)]),
      IppAttribute.keyword('media-col-supported', [
        'media-bottom-margin',
        'media-left-margin',
        'media-right-margin',
        'media-size',
        'media-source',
        'media-top-margin',
        'media-type',
      ]),
      IppAttribute.keyword('media-default', [media.first.name]),
      IppAttribute.integer('media-left-margin-supported', [0]),
      IppAttribute.keyword('media-ready', [media.first.name]),
      IppAttribute.integer('media-right-margin-supported', [0]),
      IppAttribute.collection('media-size-supported', [for (final m in media) size(m)]),
      IppAttribute.keyword('media-source-supported', ['main']),
      IppAttribute.keyword('media-supported', [for (final m in media) m.name]),
      IppAttribute.integer('media-top-margin-supported', [0]),
      IppAttribute.keyword('media-type-supported', [mediaType]),
      IppAttribute.boolean('multiple-document-jobs-supported', false),
      IppAttribute.integer('multiple-operation-time-out', [60]),
      IppAttribute.language('natural-language-configured', ['en']),
      IppAttribute.enumeration('operations-supported', const [
        IppOp.printJob,
        IppOp.validateJob,
        IppOp.createJob,
        IppOp.sendDocument,
        IppOp.cancelJob,
        IppOp.getJobAttributes,
        IppOp.getJobs,
        IppOp.getPrinterAttributes,
        IppOp.closeJob,
        IppOp.identifyPrinter,
      ]),
      IppAttribute.enumeration('orientation-requested-default', [3]),
      IppAttribute.enumeration('orientation-requested-supported', [3, 4]),
      IppAttribute.keyword('output-bin-default', ['face-up']),
      IppAttribute.keyword('output-bin-supported', ['face-up']),
      IppAttribute.keyword('pdl-override-supported', ['attempted']),
      IppAttribute.keyword('print-color-mode-default', ['monochrome']),
      IppAttribute.keyword('print-color-mode-supported', ['auto', 'monochrome']),
      IppAttribute.enumeration('print-quality-default', [4]),
      IppAttribute.enumeration('print-quality-supported', [3, 4, 5]),
      IppAttribute.keyword('print-scaling-default', ['fit']),
      IppAttribute.keyword('print-scaling-supported', ['auto', 'fit', 'fill', 'none']),
      IppAttribute.text('printer-device-id', 'MFG:Universal Print;MDL:$model ${p.paperWidth}mm;CMD:PWGRaster,URF;'),
      IppAttribute.text('printer-info', 'Universal Print ${p.name}'),
      IppAttribute.boolean('printer-is-accepting-jobs', true),
      IppAttribute.keyword('printer-kind', p.isLabel ? ['label'] : ['receipt', 'roll']),
      IppAttribute.text('printer-location', p.connectionType.label),
      IppAttribute.text('printer-make-and-model', 'Universal Print $model'),
      IppAttribute.uri('printer-more-info', ['http://$host:${boundPort ?? port}/']),
      IppAttribute.nameValue('printer-name', p.name),
      IppAttribute.resolution('printer-resolution-default', [resolutions.first]),
      IppAttribute.resolution('printer-resolution-supported', resolutions),
      IppAttribute.enumeration('printer-state', [active > 0 ? 4 : 3]),
      IppAttribute.text('printer-state-message', active > 0 ? 'Printing' : 'Ready'),
      IppAttribute.keyword('printer-state-reasons', ['none']),
      IppAttribute.integer('printer-up-time', [_upTime]),
      IppAttribute.uri('printer-uri-supported', [printerUri]),
      IppAttribute.uri('printer-uuid', ['urn:uuid:${_uuid(p)}']),
      IppAttribute.resolution('pwg-raster-document-resolution-supported', resolutions),
      IppAttribute.keyword('pwg-raster-document-sheet-back', ['normal']),
      IppAttribute.keyword('pwg-raster-document-type-supported', ['black_1', 'sgray_8', 'srgb_8']),
      IppAttribute.integer('queued-job-count', [active]),
      IppAttribute.keyword('sides-default', ['one-sided']),
      IppAttribute.keyword('sides-supported', ['one-sided']),
      IppAttribute.keyword('uri-authentication-supported', ['none']),
      IppAttribute.keyword('uri-security-supported', ['none']),
      IppAttribute.keyword('urf-supported', _urf(p)),
      IppAttribute.keyword('which-jobs-supported', ['completed', 'not-completed']),
    ];
  }

  MiniResponse _statusPage(MiniRequest req) {
    final host = req.host ?? '127.0.0.1';
    const esc = HtmlEscape();
    final rows = StringBuffer();
    for (final p in sharedPrinters) {
      rows.write('<tr><td>${esc.convert(p.name)}${p.id == defaultShared?.id ? ' <b>(default)</b>' : ''}</td>'
          '<td>${esc.convert(p.paperLabel)}</td><td><code>${esc.convert(uriFor(host, p))}</code></td></tr>');
    }
    final html = '''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Universal Print</title><style>body{font-family:system-ui,sans-serif;margin:24px;color:#222}
td,th{padding:6px 10px;border-bottom:1px solid #ddd;text-align:left}code{font-size:13px}</style></head><body>
<h1>Universal Print</h1><p>Driverless printer (IPP Everywhere / AirPrint). Default queue:
<code>${esc.convert(uriFor(host, null))}</code></p>
<table><tr><th>Printer</th><th>Paper</th><th>IPP address</th></tr>$rows</table></body></html>''';
    return MiniResponse.text(200, html, contentType: 'text/html; charset=utf-8');
  }

  @override
  void dispose() {
    _printers.removeListener(_onPrintersChanged);
    unawaited(stop());
    super.dispose();
  }
}

enum _DocKind { raster, text, raw, pdf, empty }

class _IppJob {
  _IppJob({
    required this.id,
    required this.printerId,
    required this.printerUri,
    required this.uri,
    required this.name,
    required this.user,
    required this.format,
    required this.copies,
  }) : createdAt = DateTime.now();

  static const pending = 3;
  static const held = 4;
  static const processing = 5;
  static const canceled = 7;
  static const aborted = 8;
  static const completed = 9;

  final int id;
  final String printerId;
  final String printerUri;
  final String uri;
  final String name;
  final String user;
  String format;
  final int copies;
  final DateTime createdAt;
  DateTime? completedAt;

  /// Until the document arrives (Create-Job → Send-Document) the job is held.
  int state = held;
  String? error;
  final buffer = BytesBuilder(copy: false);
  final printJobIds = <String>[];

  String get reason => switch (state) {
    held => 'job-incoming',
    processing => 'job-printing',
    canceled => 'job-canceled-by-user',
    aborted => 'aborted-by-system',
    completed => 'job-completed-successfully',
    _ => 'none',
  };

  void abort(String message) {
    state = aborted;
    error = message;
    completedAt = DateTime.now();
  }
}

// ------------------------------------------------------------- mDNS / DNS-SD

class AdvertisedPrinter {
  const AdvertisedPrinter({required this.name, required this.port, required this.txt});

  final String name;
  final int port;
  final Map<String, String> txt;
}

/// Announces the IPP queues on the local network (`_ipp._tcp`), so Windows,
/// macOS, Linux and Android list them in "Add printer" automatically.
abstract class PrinterAdvertiser {
  bool get isActive;

  Future<void> publish(List<AdvertisedPrinter> printers);

  Future<void> stop();
}

class BonsoirAdvertiser implements PrinterAdvertiser {
  final _broadcasts = <BonsoirBroadcast>[];

  @override
  bool get isActive => _broadcasts.isNotEmpty;

  @override
  Future<void> publish(List<AdvertisedPrinter> printers) async {
    await stop();
    for (final p in printers) {
      final b = BonsoirBroadcast(
        service: BonsoirService.ignoreNorms(name: p.name, type: '_ipp._tcp', port: p.port, attributes: p.txt),
      );
      await b.initialize();
      await b.start();
      _broadcasts.add(b);
    }
  }

  @override
  Future<void> stop() async {
    final all = _broadcasts.toList();
    _broadcasts.clear();
    for (final b in all) {
      try {
        await b.stop();
      } catch (_) {
        // Already gone.
      }
    }
  }
}

/// For tests and platforms without mDNS.
class NoAdvertiser implements PrinterAdvertiser {
  @override
  bool get isActive => false;

  @override
  Future<void> publish(List<AdvertisedPrinter> printers) async {}

  @override
  Future<void> stop() async {}
}

/// Paper geometry shared with the Android print framework.
Map<String, Object?> systemPrinterInfo(Printer p) {
  final g = p.geometry();
  return {
    'id': p.id,
    'name': p.name,
    'kind': p.isDocument ? 'document' : (p.isLabel ? 'label' : 'roll'),
    'width_mm': p.paperWidth,
    'height_mm': p.isLabel ? (p.labelHeight ?? p.paperWidth) : 297,
    'dpi': g.dpi,
    'dots': p.isDocument ? 0 : g.dotsPerLine,
    'is_default': p.isDefault,
    'description': p.paperLabel,
  };
}
