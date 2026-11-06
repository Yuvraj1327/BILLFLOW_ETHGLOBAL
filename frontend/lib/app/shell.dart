import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/widgets/brand_logo.dart';
import '../core/widgets/widgets.dart';
import '../shared/models/models.dart';
import 'theme/app_theme.dart';
import 'providers.dart';

class _Dest {
  const _Dest(this.label, this.icon, this.path, {this.mobilePrimary = true});
  final String label, path;
  final IconData icon;
  /// false = lives in the "More" sheet on phones (still a normal sidebar/rail item on larger screens).
  final bool mobilePrimary;
}

const _merchant = [
  _Dest('Dashboard', Icons.dashboard_outlined, '/merchant'),
  _Dest('Invoices', Icons.receipt_long_outlined, '/merchant/invoices'),
  _Dest('Customers', Icons.people_outline, '/merchant/customers'),
  _Dest('Financing', Icons.account_balance_outlined, '/merchant/financing'),
  _Dest('Payments', Icons.swap_horiz, '/transactions', mobilePrimary: false),
  _Dest('Reports', Icons.insert_chart_outlined, '/merchant/reports', mobilePrimary: false),
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
    return best;
  }

  List<_Dest> _dests(Profile p) => p.isMerchant ? _merchant : p.isInvestor ? _investor : p.isAdmin ? _admin : _customer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(authProvider).valueOrNull;
    if (profile == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final dests = _dests(profile);
    final idx = _index(dests); // -1 on utility pages such as /notifications, /profile, /settings
    final layout = layoutOf(context);
    final onRoot = dests.any((d) => d.path == location);
    final unread = ref.watch(unreadCountProvider).valueOrNull ?? 0;
    final title = idx >= 0 && onRoot ? dests[idx].label : _utilityTitle(location);

    void back() => context.canPop() ? context.pop() : context.go(dests.first.path);

    final appBar = AppBar(
      automaticallyImplyLeading: false,
      titleSpacing: layout == Layout.desktop ? 24 : null,
      leading: layout == Layout.desktop
          ? (onRoot ? null : BackButton(onPressed: back))
          : onRoot ? const Padding(padding: EdgeInsets.all(10), child: BillflowLogo(height: 32)) : BackButton(onPressed: back),
      title: Text(title, style: layout == Layout.desktop ? const TextStyle(fontSize: 20, fontWeight: FontWeight.w800) : null),
      actions: [
        IconButton(
          tooltip: 'Notifications',
          onPressed: () => context.push('/notifications'),
          icon: Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: const Icon(Icons.notifications_none)),
        ),
        _AccountMenu(profile: profile),
        SizedBox(width: layout == Layout.desktop ? 16 : 8),
      ],
    );

    final body = DecoratedBox(
      decoration: BoxDecoration(color: Theme.of(context).brightness == Brightness.light ? Tokens.surfaceTint : Colors.black),
      child: child,
    );
    final showNav = dests.length > 1;

    switch (layout) {
      case Layout.desktop:
        return Scaffold(
          body: Row(children: [
            _Sidebar(dests: dests, selected: idx, profile: profile, location: location),
            Expanded(child: Scaffold(appBar: appBar, body: body)),
          ]),
        );
      case Layout.tablet:
        return Scaffold(
          appBar: appBar,
          body: Row(children: [
            if (showNav)
              NavigationRail(
                selectedIndex: idx < 0 ? null : idx,
                labelType: NavigationRailLabelType.all,
                onDestinationSelected: (i) => context.go(dests[i].path),
                destinations: [for (final d in dests) NavigationRailDestination(icon: Icon(d.icon), label: Text(d.label))],
              ),
            if (showNav) const VerticalDivider(width: 1),
            Expanded(child: body),
          ]),
        );
      case Layout.mobile:
        final primary = [for (final d in dests) if (d.mobilePrimary) d];
        final hasMore = primary.length < dests.length;
        final sel = idx >= 0 && dests[idx].mobilePrimary ? primary.indexOf(dests[idx]) : (hasMore && idx >= 0 ? primary.length : -1);
        return Scaffold(
          appBar: appBar,
          body: body,
          bottomNavigationBar: showNav
              ? NavigationBar(
                  selectedIndex: sel < 0 ? 0 : sel,
                  indicatorColor: sel < 0 ? Colors.transparent : null,
                  onDestinationSelected: (i) {
                    if (i < primary.length) {
                      context.go(primary[i].path);
                    } else {
                      _moreSheet(context, [for (final d in dests) if (!d.mobilePrimary) d]);
                    }
                  },
                  destinations: [
                    for (final d in primary) NavigationDestination(icon: Icon(d.icon), label: d.label),
                    if (hasMore) const NavigationDestination(icon: Icon(Icons.more_horiz), label: 'More'),
                  ],
                )
              : null,
        );
    }
  }

  void _moreSheet(BuildContext context, List<_Dest> extra) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final d in extra)
            ListTile(leading: Icon(d.icon), title: Text(d.label), onTap: () { Navigator.pop(c); context.go(d.path); }),
          ListTile(leading: const Icon(Icons.settings_outlined), title: const Text('Settings'), onTap: () { Navigator.pop(c); context.push('/settings'); }),
        ]),
      ),
    );
  }

  static String _utilityTitle(String loc) {
    if (loc.startsWith('/notifications')) return 'Notifications';
    if (loc.startsWith('/profile')) return 'Profile & wallet';
    if (loc.startsWith('/settings')) return 'Settings';
    if (loc.startsWith('/merchant/business')) return 'Business profile';
    if (loc.contains('/invoices/new')) return 'New invoice';
    if (loc.contains('/invoices/')) return 'Invoice';
    if (loc.contains('/customers/')) return 'Customer';
    if (loc.contains('/offers/')) return 'Financing offer';
    if (loc.contains('/financing/')) return 'Financing';
    return 'NEXA BILLFLOW';
  }
}

class _AccountMenu extends ConsumerWidget {
  const _AccountMenu({required this.profile});
  final Profile profile;
  @override
  Widget build(BuildContext context, WidgetRef ref) => PopupMenuButton<String>(
        tooltip: 'Account',
        icon: CircleAvatar(radius: 16, backgroundColor: Tokens.blue, foregroundColor: Colors.white, child: Text(profile.label.isEmpty ? '?' : profile.label[0].toUpperCase())),
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
      );
}

/// Desktop navigation: brand, role navigation, utility links and the signed-in user.
class _Sidebar extends ConsumerWidget {
  const _Sidebar({required this.dests, required this.selected, required this.profile, required this.location});
  final List<_Dest> dests;
  final int selected;
  final Profile profile;
  final String location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context);
    final light = t.brightness == Brightness.light;
    return Container(
      width: 256,
      decoration: BoxDecoration(color: t.colorScheme.surface, border: Border(right: BorderSide(color: t.dividerTheme.color ?? Colors.black12))),
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(padding: const EdgeInsets.fromLTRB(20, 22, 20, 18), child: InkWell(onTap: () => context.go(dests.first.path), child: const BrandLockup(height: 34))),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 4, 22, 8),
            child: Text(profile.role.toUpperCase(), style: TextStyle(fontSize: 11, letterSpacing: 1.2, fontWeight: FontWeight.w700, color: t.hintColor)),
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.symmetric(horizontal: 12), children: [
              for (var i = 0; i < dests.length; i++) _NavTile(icon: dests[i].icon, label: dests[i].label, selected: i == selected, onTap: () => context.go(dests[i].path)),
              const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Divider()),
              _NavTile(icon: Icons.notifications_none, label: 'Notifications', selected: location.startsWith('/notifications'), onTap: () => context.push('/notifications')),
              if (profile.isMerchant) _NavTile(icon: Icons.storefront_outlined, label: 'Business profile', selected: location.startsWith('/merchant/business'), onTap: () => context.push('/merchant/business')),
              _NavTile(icon: Icons.account_balance_wallet_outlined, label: 'Profile & wallet', selected: location.startsWith('/profile'), onTap: () => context.push('/profile')),
              _NavTile(icon: Icons.settings_outlined, label: 'Settings', selected: location.startsWith('/settings'), onTap: () => context.push('/settings')),
            ]),
          ),
          Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: light ? Tokens.surfaceTint : const Color(0xFF111111), borderRadius: BorderRadius.circular(14)),
            child: Row(children: [
              CircleAvatar(radius: 18, backgroundColor: Tokens.blue, foregroundColor: Colors.white, child: Text(profile.label.isEmpty ? '?' : profile.label[0].toUpperCase())),
              const SizedBox(width: 10),
              Expanded(child: Text(profile.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700))),
              IconButton(tooltip: 'Log out', icon: const Icon(Icons.logout, size: 20), onPressed: () => ref.read(authProvider.notifier).signOut()),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({required this.icon, required this.label, required this.selected, required this.onTap});
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = selected ? cs.primary : cs.onSurface.withValues(alpha: .78);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? cs.primary.withValues(alpha: .09) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(children: [
              Icon(icon, size: 21, color: fg),
              const SizedBox(width: 12),
              Expanded(child: Text(label, style: TextStyle(color: fg, fontWeight: selected ? FontWeight.w700 : FontWeight.w500))),
              if (selected) Container(width: 4, height: 18, decoration: BoxDecoration(color: Tokens.teal, borderRadius: BorderRadius.circular(2))),
            ]),
          ),
        ),
      ),
    );
  }
}
