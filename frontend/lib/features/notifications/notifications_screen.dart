import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/shell.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/widgets.dart';
import '../../shared/models/models.dart';
import '../../shared/widgets/paged_list.dart';

class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});
  @override
  ConsumerState<NotificationsScreen> createState() => _S();
}

class _S extends ConsumerState<NotificationsScreen> {
  int _token = 0;
  @override
  Widget build(BuildContext context) => ResponsiveBody(
        padding: EdgeInsets.zero,
        child: PagedList<NotificationItem>(
          reloadToken: _token,
          load: (p) => ref.read(apiProvider).notifications(page: p),
          header: Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () async {
                try {
                  await ref.read(apiProvider).markAllRead();
                  ref.invalidate(unreadCountProvider);
                  setState(() => _token++);
                } catch (e) {
                  if (context.mounted) toast(context, errorText(e), error: true);
                }
              },
              icon: const Icon(Icons.done_all),
              label: const Text('Mark all read'),
            ),
          ),
          empty: const EmptyState(icon: Icons.notifications_none, title: 'No notifications', message: 'Payment confirmations, review decisions and financing updates show up here.'),
          itemBuilder: (c, n) => AppCard(
            onTap: n.read
                ? null
                : () async {
                    try {
                      await ref.read(apiProvider).markRead(n.id);
                      ref.invalidate(unreadCountProvider);
                      setState(() => _token++);
                    } catch (_) {}
                  },
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(n.read ? Icons.notifications_none : Icons.notifications_active, color: n.read ? Theme.of(c).hintColor : Theme.of(c).colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(n.title, style: TextStyle(fontWeight: n.read ? FontWeight.w500 : FontWeight.w800)),
                if (n.body != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(n.body!)),
                Padding(padding: const EdgeInsets.only(top: 4), child: Text(fmtDateTime(n.createdAt), style: TextStyle(color: Theme.of(c).hintColor, fontSize: 12))),
              ])),
            ]),
          ),
        ),
      );
}
