import 'package:flutter/foundation.dart';

import '../data/database.dart';
import '../data/models/printer.dart';

class PrinterStore extends ChangeNotifier {
  PrinterStore(this._repo);

  final PrinterRepository _repo;

  /// Called after a printer is deleted, so routes can be unassigned.
  Future<void> Function(String printerId)? onDeleted;
  List<Printer> _printers = const [];

  List<Printer> get printers => _printers;

  /// The explicit default, or the only printer when there is just one.
  Printer? get defaultPrinter {
    for (final p in _printers) {
      if (p.isDefault) return p;
    }
    return _printers.length == 1 ? _printers.first : null;
  }

  Printer? byId(String id) {
    for (final p in _printers) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<void> load() async {
    _printers = await _repo.all();
    notifyListeners();
  }

  Future<void> save(Printer printer) async {
    // The first printer added becomes the default automatically.
    final makeDefault = printer.isDefault || _printers.every((p) => p.id == printer.id);
    await _repo.save(printer.copyWith(isDefault: makeDefault));
    await load();
  }

  Future<void> setDefault(String id) async {
    final printer = byId(id);
    if (printer == null) return;
    await _repo.save(printer.copyWith(isDefault: true));
    await load();
  }

  Future<void> delete(String id) async {
    final wasDefault = byId(id)?.isDefault ?? false;
    await _repo.delete(id);
    await onDeleted?.call(id);
    await load();
    if (wasDefault && _printers.isNotEmpty) await setDefault(_printers.first.id);
  }
}
