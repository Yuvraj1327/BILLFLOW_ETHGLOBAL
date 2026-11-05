import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/widgets/widgets.dart';
import 'providers.dart';

class _Dest {
  const _Dest(this.label, this.icon, this.path);
  final String label, path;
  final IconData icon;
}

const _merchant = [
  _Dest('Home', Icons.dashboard_outlined, '/merchant'),
  _Dest('Invoices', Icons.receipt_long_outlined, '/merchant/invoices'),
  _Dest('Customers', Icons.people_outline, '/merchant/customers'),
  _Dest('Financing', Icons.account_balance_outlined, '/merchant/financing'),
  _Dest('Payments', Icons.swap_horiz, '/transactions'),
];
const _investor = [
  _Dest('Marketplace', Icons.storefront_outlined, '/investor'),
  _Dest('Portfolio', Icons.pie_chart_outline, '/investor/portfolio'),
  _Dest('Activity', Icons.swap_horiz, '/transactions'),
];
const _customer = [
  _Dest('Payments', Icons.swap_horiz, '/customer'),
];
const _admin = [
  _Dest('Overview', Icons.dashboard_outlined, '/admin'),
  _Dest('Users', Icons.people_outline, '/admin/users'),
  _Dest('Businesses', Icons.business_outlined, '/admin/businesses'),
  _Dest('Financing', Icons.account_balance_outlined, '/admin/financing'),
  _Dest('Monitor', Icons.monitor_heart_outlined, '/admin/monitoring'),
];

final unreadCountProvider = FutureProvider.autoDispose<int>((ref) async => (await ref.watch(apiProvider).notifications(unreadOnly: true)).total);

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.location, required this.child});
  final String location;
  final Widget child;

  int _index(List<_Dest> d) {
    var best = -1, len = -1;
    for (var i = 0; i < d.length; i++) {
      final p = d[i].path;
      final match = location == p || location.startsWith('$p/');
      // '/merchant' is a prefix of every merchant route, so prefer the longest match.
      if (match && p.length > len) { best = i; len = p.length; }
    }
    return best < 0 ? 0 : best;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(authProvider).valueOrNull;
    if (profile == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final dests = switch (profile.role) { 'merchant' => _merchant, 'investor' => _investor, 'admin' => _admin, _ => _customer };
    final idx = _index(dests);
    final wide = isWide(context);
    final unread = ref.watch(unreadCountProvider).valueOrNull ?? 0;
    final onRoot = dests.any((d) => d.path == location);

    final appBar = AppBar(
      automaticallyImplyLeading: false,
      leading: onRoot ? null : BackButton(onPressed: () => context.canPop() ? context.pop() : context.go(dests.first.path)),
      title: Text(onRoot ? dests[idx].label : 'BillFlow'),
      actions: [
        IconButton(
          tooltip: 'Notifications',
          onPressed: () => context.push('/notifications'),
          icon: Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: const Icon(Icons.notifications_none)),
        ),
        PopupMenuButton<String>(
          tooltip: 'Account',
          icon: CircleAvatar(radius: 15, child: Text(profile.label.isEmpty ? '?' : profile.label[0].toUpperCase())),
          onSelected: (v) async {
            if (v == 'logout') {
              await ref.read(authProvider.notifier).signOut();
            } else {
              context.push(v);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(enabled: false, child: Text('${profile.label}\n${profile.role.toUpperCase()}', style: const TextStyle(fontSize: 12))),
            const PopupMenuItem(value: '/profile', child: Text('Profile & wallet')),
            if (profile.isMerchant) const PopupMenuItem(value: '/merchant/business', child: Text('Business profile')),
            if (profile.isInvestor) const PopupMenuItem(value: '/transactions', child: Text('Transactions')),
            const PopupMenuItem(value: '/settings', child: Text('Settings')),
            const PopupMenuItem(value: 'logout', child: Text('Log out')),
          ],
        ),
        const SizedBox(width: 8),
      ],
    );

    final showNav = dests.length > 1;
    if (wide && showNav) {
      return Scaffold(
        appBar: appBar,
        body: Row(children: [
          NavigationRail(
            selectedIndex: idx,
            labelType: NavigationRailLabelType.all,
            onDestinationSelected: (i) => context.go(dests[i].path),
            destinations: [for (final d in dests) NavigationRailDestination(icon: Icon(d.icon), label: Text(d.label))],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: child),
        ]),
      );
    }
    return Scaffold(
      appBar: appBar,
      body: child,
      bottomNavigationBar: showNav
          ? NavigationBar(
              selectedIndex: idx,
              onDestinationSelected: (i) => context.go(dests[i].path),
              destinations: [for (final d in dests) NavigationDestination(icon: Icon(d.icon), label: d.label)],
            )
          : null,
    );
  }
}
