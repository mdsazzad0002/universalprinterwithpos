import 'dart:convert';
import 'dart:typed_data';

/// IPP value tags (RFC 8010).
abstract final class IppTag {
  static const operationGroup = 0x01;
  static const jobGroup = 0x02;
  static const endOfAttributes = 0x03;
  static const printerGroup = 0x04;
  static const unsupportedGroup = 0x05;

  static const unsupportedValue = 0x10;
  static const unknown = 0x12;
  static const noValue = 0x13;
  static const integer = 0x21;
  static const boolean = 0x22;
  static const enumeration = 0x23;
  static const octetString = 0x30;
  static const dateTime = 0x31;
  static const resolution = 0x32;
  static const rangeOfInteger = 0x33;
  static const begCollection = 0x34;
  static const textWithLanguage = 0x35;
  static const nameWithLanguage = 0x36;
  static const endCollection = 0x37;
  static const text = 0x41;
  static const name = 0x42;
  static const keyword = 0x44;
  static const uri = 0x45;
  static const uriScheme = 0x46;
  static const charset = 0x47;
  static const naturalLanguage = 0x48;
  static const mimeMediaType = 0x49;
  static const memberAttrName = 0x4A;
}

/// IPP operation ids and status codes used by the system printer.
abstract final class IppOp {
  static const printJob = 0x0002;
  static const validateJob = 0x0004;
  static const createJob = 0x0005;
  static const sendDocument = 0x0006;
  static const cancelJob = 0x0008;
  static const getJobAttributes = 0x0009;
  static const getJobs = 0x000A;
  static const getPrinterAttributes = 0x000B;
  static const closeJob = 0x003B;
  static const identifyPrinter = 0x003C;
}

abstract final class IppStatus {
  static const ok = 0x0000;
  static const okIgnoredOrSubstituted = 0x0001;
  static const badRequest = 0x0400;
  static const notPossible = 0x0404;
  static const notFound = 0x0406;
  static const requestEntityTooLarge = 0x0409;
  static const documentFormatNotSupported = 0x040A;
  static const attributesOrValuesNotSupported = 0x040B;
  static const internalError = 0x0500;
  static const operationNotSupported = 0x0501;
  static const versionNotSupported = 0x0503;
  static const deviceError = 0x0504;
  static const notAcceptingJobs = 0x0506;
}

class IppResolution {
  const IppResolution(this.x, this.y, {this.units = 3});

  final int x;
  final int y;

  /// 3 = dots per inch, 4 = dots per cm.
  final int units;
}

class IppRange {
  const IppRange(this.lower, this.upper);

  final int lower;
  final int upper;
}

/// Members of a collection value, in order.
class IppCollection {
  const IppCollection(this.members);

  final List<IppAttribute> members;

  IppAttribute? operator [](String name) {
    for (final m in members) {
      if (m.name == name) return m;
    }
    return null;
  }
}

/// One attribute: a name, a value tag and one or more values. Values are
/// `int`, `bool`, `String`, [Uint8List], [IppResolution], [IppRange] or
/// [IppCollection], matching [tag].
class IppAttribute {
  const IppAttribute(this.tag, this.name, this.values);

  IppAttribute.integer(this.name, List<int> v) : tag = IppTag.integer, values = v;
  IppAttribute.enumeration(this.name, List<int> v) : tag = IppTag.enumeration, values = v;
  IppAttribute.boolean(this.name, bool v) : tag = IppTag.boolean, values = [v];
  IppAttribute.keyword(this.name, List<String> v) : tag = IppTag.keyword, values = v;
  IppAttribute.text(this.name, String v) : tag = IppTag.text, values = [v];
  IppAttribute.nameValue(this.name, String v) : tag = IppTag.name, values = [v];
  IppAttribute.uri(this.name, List<String> v) : tag = IppTag.uri, values = v;
  IppAttribute.charset(this.name, List<String> v) : tag = IppTag.charset, values = v;
  IppAttribute.language(this.name, List<String> v) : tag = IppTag.naturalLanguage, values = v;
  IppAttribute.mime(this.name, List<String> v) : tag = IppTag.mimeMediaType, values = v;
  IppAttribute.resolution(this.name, List<IppResolution> v) : tag = IppTag.resolution, values = v;
  IppAttribute.range(this.name, int lower, int upper) : tag = IppTag.rangeOfInteger, values = [IppRange(lower, upper)];
  IppAttribute.collection(this.name, List<IppCollection> v) : tag = IppTag.begCollection, values = v;
  IppAttribute.noValue(this.name) : tag = IppTag.noValue, values = const [''];

  final int tag;
  final String name;
  final List<Object> values;

  Object? get value => values.isEmpty ? null : values.first;

  String? get string => value is String ? value as String : null;

  int? get integer => value is int ? value as int : null;
}

class IppGroup {
  IppGroup(this.tag, [List<IppAttribute>? attributes]) : attributes = attributes ?? [];

  final int tag;
  final List<IppAttribute> attributes;

  IppAttribute? operator [](String name) {
    for (final a in attributes) {
      if (a.name == name) return a;
    }
    return null;
  }

  void add(IppAttribute a) => attributes.add(a);
}

class IppFormatException implements Exception {
  IppFormatException(this.message);

  final String message;

  @override
  String toString() => 'Invalid IPP message: $message';
}

/// An IPP request or response: header, attribute groups and document data.
class IppMessage {
  IppMessage({
    this.major = 2,
    this.minor = 0,
    required this.code,
    required this.requestId,
    List<IppGroup>? groups,
    Uint8List? data,
  }) : groups = groups ?? [],
       data = data ?? Uint8List(0);

  final int major;
  final int minor;

  /// Operation id in a request, status code in a response.
  final int code;
  final int requestId;
  final List<IppGroup> groups;
  final Uint8List data;

  IppGroup? group(int tag) {
    for (final g in groups) {
      if (g.tag == tag) return g;
    }
    return null;
  }

  IppAttribute? operation(String name) => group(IppTag.operationGroup)?[name];

  IppAttribute? job(String name) => group(IppTag.jobGroup)?[name];

  static IppMessage decode(Uint8List bytes) => _Reader(bytes).message();

  Uint8List encode() {
    final w = _Writer();
    w.u8(major);
    w.u8(minor);
    w.u16(code);
    w.u32(requestId);
    for (final g in groups) {
      w.u8(g.tag);
      for (final a in g.attributes) {
        w.attribute(a);
      }
    }
    w.u8(IppTag.endOfAttributes);
    w.b.add(data);
    return w.b.toBytes();
  }
}

class _Writer {
  final b = BytesBuilder(copy: false);

  void u8(int v) => b.addByte(v & 0xFF);

  void u16(int v) => b.add([v >> 8 & 0xFF, v & 0xFF]);

  void u32(int v) => b.add([v >> 24 & 0xFF, v >> 16 & 0xFF, v >> 8 & 0xFF, v & 0xFF]);

  void bytes(List<int> v) {
    u16(v.length);
    b.add(v);
  }

  void attribute(IppAttribute a) {
    for (var i = 0; i < a.values.length; i++) {
      value(a.tag, i == 0 ? a.name : '', a.values[i]);
    }
  }

  void value(int tag, String name, Object v) {
    u8(tag);
    bytes(utf8.encode(name));
    switch (v) {
      case IppCollection c:
        u16(0);
        for (final m in c.members) {
          u8(IppTag.memberAttrName);
          u16(0);
          bytes(utf8.encode(m.name));
          for (final mv in m.values) {
            value(m.tag, '', mv);
          }
        }
        u8(IppTag.endCollection);
        u16(0);
        u16(0);
      case int n when tag == IppTag.boolean:
        u16(1);
        u8(n);
      case bool flag:
        u16(1);
        u8(flag ? 1 : 0);
      case int n:
        u16(4);
        u32(n);
      case IppResolution r:
        u16(9);
        u32(r.x);
        u32(r.y);
        u8(r.units);
      case IppRange r:
        u16(8);
        u32(r.lower);
        u32(r.upper);
      case Uint8List raw:
        bytes(raw);
      case String s:
        bytes(utf8.encode(s));
      default:
        throw ArgumentError('Cannot encode IPP value $v');
    }
  }
}

class _Reader {
  _Reader(this.d) : view = ByteData.sublistView(d);

  final Uint8List d;
  final ByteData view;
  int p = 0;

  void need(int n) {
    if (p + n > d.length) throw IppFormatException('truncated at byte $p');
  }

  int u8() {
    need(1);
    return d[p++];
  }

  int u16() {
    need(2);
    final v = view.getUint16(p);
    p += 2;
    return v;
  }

  Uint8List bytes() {
    final n = u16();
    need(n);
    final v = Uint8List.sublistView(d, p, p + n);
    p += n;
    return v;
  }

  IppMessage message() {
    need(8);
    final major = d[0], minor = d[1];
    final code = view.getUint16(2);
    final requestId = view.getUint32(4);
    p = 8;
    final groups = <IppGroup>[];
    IppGroup? current;
    while (true) {
      final tag = u8();
      if (tag == IppTag.endOfAttributes) break;
      if (tag < 0x10) {
        current = IppGroup(tag);
        groups.add(current);
        continue;
      }
      if (current == null) throw IppFormatException('attribute outside a group');
      final name = utf8.decode(bytes(), allowMalformed: true);
      final v = tag == IppTag.begCollection ? collection() : decodeValue(tag, bytes());
      if (name.isEmpty) {
        if (current.attributes.isEmpty) throw IppFormatException('additional value without attribute');
        final last = current.attributes.removeLast();
        current.attributes.add(IppAttribute(last.tag, last.name, [...last.values, v]));
      } else {
        current.add(IppAttribute(tag, name, [v]));
      }
    }
    return IppMessage(
      major: major,
      minor: minor,
      code: code,
      requestId: requestId,
      groups: groups,
      data: Uint8List.sublistView(d, p),
    );
  }

  /// After a begCollection name; its own (empty) value is still unread.
  IppCollection collection() {
    bytes();
    final members = <IppAttribute>[];
    String? member;
    while (true) {
      final tag = u8();
      final name = bytes(); // always empty inside collections
      if (tag == IppTag.endCollection) {
        bytes();
        break;
      }
      if (name.isNotEmpty) throw IppFormatException('named value inside a collection');
      if (tag == IppTag.memberAttrName) {
        member = utf8.decode(bytes(), allowMalformed: true);
        continue;
      }
      if (member == null) throw IppFormatException('collection value without member name');
      final v = tag == IppTag.begCollection ? collection() : decodeValue(tag, bytes());
      final i = members.lastIndexWhere((m) => m.name == member);
      if (i >= 0 && i == members.length - 1) {
        final m = members.removeLast();
        members.add(IppAttribute(m.tag, m.name, [...m.values, v]));
      } else {
        members.add(IppAttribute(tag, member, [v]));
      }
    }
    return IppCollection(members);
  }

  Object decodeValue(int tag, Uint8List v) {
    final bd = ByteData.sublistView(v);
    switch (tag) {
      case IppTag.integer || IppTag.enumeration:
        if (v.length != 4) throw IppFormatException('bad integer length');
        return bd.getInt32(0);
      case IppTag.boolean:
        if (v.length != 1) throw IppFormatException('bad boolean length');
        return v[0] != 0;
      case IppTag.resolution:
        if (v.length != 9) throw IppFormatException('bad resolution length');
        return IppResolution(bd.getInt32(0), bd.getInt32(4), units: v[8]);
      case IppTag.rangeOfInteger:
        if (v.length != 8) throw IppFormatException('bad range length');
        return IppRange(bd.getInt32(0), bd.getInt32(4));
      case IppTag.octetString || IppTag.dateTime:
        return Uint8List.fromList(v);
      case IppTag.textWithLanguage || IppTag.nameWithLanguage:
        // language length + language + text length + text
        if (v.length < 4) return '';
        final langLen = bd.getUint16(0);
        if (2 + langLen + 2 > v.length) return '';
        final textLen = bd.getUint16(2 + langLen);
        final start = 4 + langLen;
        return utf8.decode(v.sublist(start, (start + textLen).clamp(start, v.length)), allowMalformed: true);
      default:
        return utf8.decode(v, allowMalformed: true);
    }
  }
}
