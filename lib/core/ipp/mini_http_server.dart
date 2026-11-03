import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class MiniRequest {
  MiniRequest(this.method, this.path, this.headers, this.body, this.remote);

  final String method;
  final String path;

  /// Lower-case header names.
  final Map<String, String> headers;
  final Uint8List body;
  final InternetAddress remote;

  /// `Host` header without the port, for building URLs the client can reach.
  String? get host {
    final h = headers['host'];
    if (h == null || h.isEmpty) return null;
    if (h.startsWith('[')) return h.substring(0, h.indexOf(']') + 1);
    final i = h.lastIndexOf(':');
    return i < 0 ? h : h.substring(0, i);
  }
}

class MiniResponse {
  MiniResponse(this.status, this.body, {this.contentType = 'text/plain; charset=utf-8'});

  MiniResponse.text(this.status, String text, {this.contentType = 'text/plain; charset=utf-8'})
    : body = utf8.encode(text);

  final int status;
  final Uint8List body;
  final String contentType;
}

typedef MiniHandler = Future<MiniResponse> Function(MiniRequest request);

/// Minimal HTTP/1.1 server for IPP. Unlike `dart:io`'s [HttpServer] it
/// answers `Expect: 100-continue`, which CUPS, Windows and macOS send before
/// every print job; without it each job stalls until the client gives up
/// waiting. Supports keep-alive, Content-Length and chunked bodies.
class MiniHttpServer {
  MiniHttpServer._(this._socket, this._handler, this.maxBodyBytes) {
    _socket.listen((s) => _Connection(this, s).run());
  }

  final ServerSocket _socket;
  final MiniHandler _handler;
  final int maxBodyBytes;
  final _connections = <Socket>{};

  int get port => _socket.port;

  InternetAddress get address => _socket.address;

  static Future<MiniHttpServer> bind(
    InternetAddress address,
    int port,
    MiniHandler handler, {
    int maxBodyBytes = 64 * 1024 * 1024,
  }) async {
    final socket = await ServerSocket.bind(
      address,
      port,
      v6Only: false,
      shared: false,
    );
    return MiniHttpServer._(socket, handler, maxBodyBytes);
  }

  Future<void> close() async {
    await _socket.close();
    for (final c in _connections.toList()) {
      c.destroy();
    }
    _connections.clear();
  }
}

class _HttpError implements Exception {
  _HttpError(this.status, this.message);

  final int status;
  final String message;
}

class _Connection {
  _Connection(this.server, this.socket) : input = _Input(socket);

  final MiniHttpServer server;
  final Socket socket;
  final _Input input;

  static const _idle = Duration(seconds: 60);

  Future<void> run() async {
    server._connections.add(socket);
    try {
      while (await _one()) {}
    } on _HttpError catch (e) {
      await _write(MiniResponse.text(e.status, e.message), keepAlive: false);
    } catch (_) {
      // Client went away or sent garbage; just drop the connection.
    } finally {
      server._connections.remove(socket);
      input.cancel();
      socket.destroy();
    }
  }

  /// Handles one request; false when the connection should close.
  Future<bool> _one() async {
    final requestLine = await input.readLine(timeout: _idle);
    if (requestLine == null) return false;
    if (requestLine.isEmpty) return true; // stray CRLF between requests
    final parts = requestLine.split(' ');
    if (parts.length != 3 || !parts[2].startsWith('HTTP/1.')) throw _HttpError(400, 'Bad request line');
    final method = parts[0].toUpperCase();
    final http10 = parts[2] == 'HTTP/1.0';

    final headers = <String, String>{};
    while (true) {
      final line = await input.readLine(timeout: _idle);
      if (line == null) return false;
      if (line.isEmpty) break;
      final i = line.indexOf(':');
      if (i <= 0) continue;
      final name = line.substring(0, i).trim().toLowerCase();
      final value = line.substring(i + 1).trim();
      headers[name] = headers.containsKey(name) ? '${headers[name]}, $value' : value;
      if (headers.length > 100) throw _HttpError(431, 'Too many headers');
    }

    final connection = headers['connection']?.toLowerCase() ?? '';
    final keepAlive = http10 ? connection.contains('keep-alive') : !connection.contains('close');

    final chunked = headers['transfer-encoding']?.toLowerCase().contains('chunked') ?? false;
    final length = int.tryParse(headers['content-length'] ?? '');
    if (length != null && length > server.maxBodyBytes) throw _HttpError(413, 'Document is too large');
    if ((headers['expect'] ?? '').toLowerCase() == '100-continue' && (chunked || (length ?? 0) > 0)) {
      socket.add(latin1.encode('HTTP/1.1 100 Continue\r\n\r\n'));
      await socket.flush();
    }

    final Uint8List body;
    if (chunked) {
      final b = BytesBuilder(copy: false);
      while (true) {
        final sizeLine = await input.readLine(timeout: _idle);
        if (sizeLine == null) return false;
        final size = int.tryParse(sizeLine.split(';').first.trim(), radix: 16);
        if (size == null) throw _HttpError(400, 'Bad chunk size');
        if (size == 0) {
          while ((await input.readLine(timeout: _idle))?.isNotEmpty ?? false) {}
          break;
        }
        if (b.length + size > server.maxBodyBytes) throw _HttpError(413, 'Document is too large');
        b.add(await input.read(size, timeout: _idle));
        await input.readLine(timeout: _idle);
      }
      body = b.toBytes();
    } else {
      body = length == null || length == 0 ? Uint8List(0) : await input.read(length, timeout: _idle);
    }

    final path = Uri.tryParse(parts[1])?.path ?? parts[1];
    MiniResponse response;
    try {
      response = await server._handler(MiniRequest(method, path, headers, body, socket.remoteAddress));
    } catch (e) {
      response = MiniResponse.text(500, 'Internal error: $e');
    }
    await _write(response, keepAlive: keepAlive, head: method == 'HEAD');
    return keepAlive;
  }

  Future<void> _write(MiniResponse r, {required bool keepAlive, bool head = false}) async {
    final head0 = StringBuffer()
      ..write('HTTP/1.1 ${r.status} ${_reason(r.status)}\r\n')
      ..write('Content-Type: ${r.contentType}\r\n')
      ..write('Content-Length: ${r.body.length}\r\n')
      ..write('Connection: ${keepAlive ? 'keep-alive' : 'close'}\r\n')
      ..write('Server: UniversalPrint\r\n\r\n');
    socket.add(latin1.encode(head0.toString()));
    if (!head) socket.add(r.body);
    await socket.flush();
  }

  static String _reason(int status) => switch (status) {
    200 => 'OK',
    400 => 'Bad Request',
    404 => 'Not Found',
    405 => 'Method Not Allowed',
    413 => 'Request Entity Too Large',
    415 => 'Unsupported Media Type',
    431 => 'Request Header Fields Too Large',
    _ => status >= 500 ? 'Internal Server Error' : 'Status',
  };
}

/// Buffered reader over a socket stream.
class _Input {
  _Input(Stream<Uint8List> stream) {
    _sub = stream.listen(
      (d) {
        _chunks.add(d);
        _available += d.length;
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
      onError: (_) {
        _done = true;
        _wake();
      },
      cancelOnError: true,
    );
  }

  late final StreamSubscription<Uint8List> _sub;
  final _chunks = ListQueue<Uint8List>();
  int _offset = 0;
  int _available = 0;
  bool _done = false;
  Completer<void>? _waiter;

  static const _maxLine = 16 * 1024;

  void _wake() {
    final w = _waiter;
    _waiter = null;
    w?.complete();
  }

  void cancel() => _sub.cancel();

  /// False when the stream ended.
  Future<bool> _more(Duration timeout) async {
    if (_done) return false;
    final w = _waiter = Completer<void>();
    try {
      await w.future.timeout(timeout);
    } on TimeoutException {
      return false;
    }
    return true;
  }

  int _indexOfNewline() {
    var pos = 0;
    var first = true;
    for (final c in _chunks) {
      final start = first ? _offset : 0;
      for (var i = start; i < c.length; i++) {
        if (c[i] == 0x0A) return pos + i - start;
      }
      pos += c.length - start;
      first = false;
    }
    return -1;
  }

  Uint8List _take(int n) {
    final out = Uint8List(n);
    var filled = 0;
    while (filled < n) {
      final c = _chunks.first;
      final take = (c.length - _offset) < (n - filled) ? c.length - _offset : n - filled;
      out.setRange(filled, filled + take, c, _offset);
      filled += take;
      _offset += take;
      if (_offset == c.length) {
        _chunks.removeFirst();
        _offset = 0;
      }
    }
    _available -= n;
    return out;
  }

  /// A line without its CR LF, or null at end of stream / idle timeout.
  Future<String?> readLine({required Duration timeout}) async {
    while (true) {
      final i = _indexOfNewline();
      if (i >= 0) {
        final bytes = _take(i + 1);
        var end = i;
        if (end > 0 && bytes[end - 1] == 0x0D) end--;
        return latin1.decode(Uint8List.sublistView(bytes, 0, end));
      }
      if (_available > _maxLine) throw _HttpError(431, 'Header line too long');
      if (!await _more(timeout)) return null;
    }
  }

  Future<Uint8List> read(int n, {required Duration timeout}) async {
    while (_available < n) {
      if (!await _more(timeout)) throw const SocketException('Connection closed mid-body');
    }
    return _take(n);
  }
}
