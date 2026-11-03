import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../data/models/print_job.dart';
import '../services/support_store.dart';
import 'org_items_screen.dart';
import 'theme.dart';
import 'widgets.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key, required this.onOpenTab});

  final ValueChanged<int> onOpenTab;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(children: [
          Image.asset('assets/logo.png', height: 34, filterQuality: FilterQuality.medium),
          const SizedBox(width: 12),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Universal Print'),
            Text(
              'Direct printing engine',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ]),
        ]),
        actions: [
          IconButton(
            tooltip: theme.brightness == Brightness.dark ? 'Light mode' : 'Dark mode',
            icon: Icon(theme.brightness == Brightness.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
            onPressed: () => s.theme.setMode(theme.brightness == Brightness.dark ? ThemeMode.light : ThemeMode.dark),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([s.printers, s.printService, s.apiServer, s.support]),
        builder: (context, _) {
          final printer = s.printers.defaultPrinter;
          final jobs = s.printService.recentJobs;
          final today = DateTime.now();
          final todayJobs = jobs.where((j) =>
              j.createdAt.year == today.year && j.createdAt.month == today.month && j.createdAt.day == today.day);
          final failed = todayJobs.where((j) => j.status == JobStatus.failed).length;

          return PageListView(
            children: [
              _ApiHero(onTap: () => onOpenTab(3)),
              const SizedBox(height: 16),
              Row(children: [
                _Stat(
                  icon: Icons.print_rounded,
                  label: 'Printers',
                  value: '${s.printers.printers.length}',
                  color: theme.colorScheme.primary,
                  onTap: () => onOpenTab(1),
                ),
                const SizedBox(width: 12),
                _Stat(
                  icon: Icons.task_alt_rounded,
                  label: 'Jobs today',
                  value: '${todayJobs.length}',
                  color: successColor,
                  onTap: () => onOpenTab(2),
                ),
                const SizedBox(width: 12),
                _Stat(
                  icon: Icons.error_outline_rounded,
                  label: 'Failed today',
                  value: '$failed',
                  color: failed > 0 ? theme.colorScheme.error : theme.colorScheme.outline,
                  onTap: () => onOpenTab(2),
                ),
              ]),
              const SizedBox(height: 24),
              const SectionHeader('Default printer'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    IconBadge(
                      printer == null ? Icons.print_disabled_outlined : connectionIcon(printer.connectionType),
                      size: 48,
                      color: printer == null ? theme.colorScheme.outline : null,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(printer?.name ?? 'No default printer', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 2),
                        Text(
                          printer == null
                              ? 'Add a printer to start printing'
                              : '${printer.connectionType.label} · ${printer.target} · ${printer.paperLabel}',
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ]),
                    ),
                    if (printer == null) ...[
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: () => onOpenTab(1),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Add'),
                      ),
                    ],
                  ]),
                ),
              ),
              if (printer != null) ...[
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: _QuickAction(
                      icon: Icons.print_outlined,
                      label: 'Test print',
                      onTap: () => runTestPrint(context, printer),
                    ),
                  ),
                  if (!printer.isLabel && !printer.isDocument) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: _QuickAction(
                        icon: Icons.point_of_sale_rounded,
                        label: 'Cash drawer',
                        onTap: () => runOpenCashDrawer(context, printer),
                      ),
                    ),
                  ],
                ]),
              ],
              const SizedBox(height: 24),
              SectionHeader(
                'Recent jobs',
                trailing: jobs.isEmpty
                    ? null
                    : TextButton(onPressed: () => onOpenTab(2), child: const Text('View all')),
              ),
              Card(
                child: jobs.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: EmptyState(
                          icon: Icons.receipt_long_outlined,
                          title: 'No print jobs yet',
                          message: 'Jobs sent by your software appear here.',
                        ),
                      )
                    : Column(children: [
                        for (final (i, job) in jobs.take(5).indexed) ...[
                          if (i > 0) const Divider(indent: 16, endIndent: 16),
                          ListTile(
                            leading: IconBadge(Icons.description_outlined, size: 36, color: theme.colorScheme.secondary),
                            title: Text('${job.documentType} → ${job.printerName}', overflow: TextOverflow.ellipsis),
                            subtitle: Text(formatTime(job.createdAt)),
                            trailing: JobStatusChip(job.status),
                            onTap: () => onOpenTab(2),
                          ),
                        ],
                      ]),
              ),
              _OrgSection(
                title: 'Products',
                icon: Icons.inventory_2_outlined,
                items: s.support.products,
                loading: s.support.loading,
              ),
              _OrgSection(
                title: 'Services',
                icon: Icons.handyman_outlined,
                items: s.support.services,
                loading: s.support.loading,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Horizontal strip of the vendor's products or services, with placeholder
/// cards while the first answer loads. Hidden when there is nothing to show.
/// Can be dragged with a finger, mouse or trackpad (desktop too), and a mouse
/// wheel scrolls it sideways.
class _OrgSection extends StatefulWidget {
  const _OrgSection({required this.title, required this.icon, required this.items, required this.loading});

  final String title;
  final IconData icon;
  final List<OrgItem> items;
  final bool loading;

  @override
  State<_OrgSection> createState() => _OrgSectionState();
}

class _OrgSectionState extends State<_OrgSection> {
  static const _cardWidth = 168.0;

  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // A vertical wheel would otherwise do nothing on a horizontal list.
  void _onWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_controller.hasClients) return;
    final delta = event.scrollDelta.dx != 0 ? event.scrollDelta.dx : event.scrollDelta.dy;
    final position = _controller.position;
    final target = (position.pixels + delta).clamp(position.minScrollExtent, position.maxScrollExtent);
    if (target != position.pixels) {
      GestureBinding.instance.pointerSignalResolver.register(event, (_) => _controller.jumpTo(target));
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    if (items.isEmpty && !widget.loading) return const SizedBox.shrink();
    void openAll() => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => OrgItemsScreen(title: widget.title, items: items, icon: widget.icon),
        ));
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SectionHeader(
          widget.title,
          trailing: items.isEmpty ? null : TextButton(onPressed: openAll, child: const Text('View all')),
        ),
        SizedBox(
          height: 208,
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: PointerDeviceKind.values.toSet(),
              scrollbars: false,
            ),
            child: Listener(
              onPointerSignal: _onWheel,
              child: Scrollbar(
                controller: _controller,
                thumbVisibility: items.isNotEmpty,
                child: ListView.separated(
                  controller: _controller,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: items.isEmpty ? 3 : items.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (context, i) => SizedBox(
                    width: _cardWidth,
                    child: items.isEmpty ? const _SkeletonCard() : _OrgCard(item: items[i], icon: widget.icon),
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _OrgCard extends StatelessWidget {
  const _OrgCard({required this.item, required this.icon});

  final OrgItem item;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final placeholder = ColoredBox(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
      child: Center(child: Icon(icon, size: 36, color: theme.colorScheme.primary)),
    );
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: item.url == null ? null : () => openLink(context, Uri.parse(item.url!)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            height: 104,
            child: item.imageUrl == null
                ? placeholder
                : Image.network(item.imageUrl!, fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item.title, style: theme.textTheme.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
              if (item.category ?? item.description case final sub?) ...[
                const SizedBox(height: 2),
                Text(
                  sub,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Pulsing grey card shown in place of a product/service while loading.
class _SkeletonCard extends StatefulWidget {
  const _SkeletonCard();

  @override
  State<_SkeletonCard> createState() => _SkeletonCardState();
}

class _SkeletonCardState extends State<_SkeletonCard> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    Widget bar(double width, double height) => Container(
          width: width,
          height: height,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
        );
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: FadeTransition(
        opacity: Tween(begin: 0.45, end: 1.0).animate(_pulse),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(height: 104, color: color),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              bar(120, 14),
              const SizedBox(height: 8),
              bar(80, 10),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Gradient banner with the API state and the address software prints to.
class _ApiHero extends StatelessWidget {
  const _ApiHero({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final api = AppScope.of(context).apiServer;
    final theme = Theme.of(context);
    final running = api.isRunning;
    final address = '${api.allowLan ? '0.0.0.0' : '127.0.0.1'}:${api.port}';
    final dark = theme.brightness == Brightness.dark;
    final colors = dark
        ? const [Color(0xFF1E3A8A), Color(0xFF312E81)]
        : const [Color(0xFF2350D8), Color(0xFF5B3FD9)];
    return Material(
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: BoxDecoration(gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight)),
        child: InkWell(
          mouseCursor: clickCursor,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: running ? const Color(0xFF4ADE80) : const Color(0xFFFCA5A5),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        running ? 'Online' : 'Offline',
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    running ? 'Print API is running' : 'Print API is stopped',
                    style: theme.textTheme.titleLarge?.copyWith(color: Colors.white),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    api.lastError ?? address,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontFamily: api.lastError == null ? 'monospace' : null,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ]),
              ),
              const SizedBox(width: 12),
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(running ? Icons.cloud_done_rounded : Icons.cloud_off_rounded, color: Colors.white, size: 30),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.label, required this.value, required this.color, required this.onTap});

  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Card(
        child: InkWell(
          mouseCursor: clickCursor,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              IconBadge(icon, size: 34, color: color),
              const SizedBox(height: 12),
              Text(value, style: theme.textTheme.headlineSmall),
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: InkWell(
        mouseCursor: clickCursor,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            IconBadge(icon, size: 34),
            const SizedBox(width: 10),
            Expanded(child: Text(label, style: theme.textTheme.titleSmall, maxLines: 2)),
          ]),
        ),
      ),
    );
  }
}
