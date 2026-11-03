import 'package:flutter/material.dart';

import '../services/support_store.dart';
import 'widgets.dart';

/// The vendor's products or services, each linking to its page on the website.
class OrgItemsScreen extends StatelessWidget {
  const OrgItemsScreen({super.key, required this.title, required this.items, required this.icon});

  final String title;
  final List<OrgItem> items;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: PageListView(
        children: [
          for (final item in items)
            Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: item.url == null ? null : () => openLink(context, Uri.parse(item.url!)),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (item.imageUrl != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(
                          item.imageUrl!,
                          width: 72,
                          height: 72,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => IconBadge(icon, size: 72),
                        ),
                      )
                    else
                      IconBadge(icon, size: 48),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(item.title, style: theme.textTheme.titleMedium),
                        if (item.category != null)
                          Text(item.category!, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary)),
                        if (item.description != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            item.description!,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ]),
                    ),
                    if (item.url != null) const Icon(Icons.open_in_new_rounded, size: 18),
                  ]),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
