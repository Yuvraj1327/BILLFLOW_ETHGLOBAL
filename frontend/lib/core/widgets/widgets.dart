import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide shortHash;
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme/app_theme.dart';
import '../config/app_config.dart';
import '../errors/app_exception.dart';
import '../utils/format.dart';

// ───────────── feedback ─────────────
void toast(BuildContext context, String message, {bool error = false}) {
  final m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(content: Text(message), backgroundColor: error ? Tokens.danger : null));
}

Future<void> copyText(BuildContext context, String text, [String label = 'Copied']) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) toast(context, label);
}

Future<void> openUrl(BuildContext context, String url) async {
  final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) toast(context, 'Could not open $url', error: true);
}

Future<bool> confirm(BuildContext context, String title, String body, {String action = 'Confirm', bool destructive = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: Tokens.danger) : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return r ?? false;
}

// ───────────── layout ─────────────
/// Centers content with a max width so wide web windows stay readable; full width on phones.
class ResponsiveBody extends StatelessWidget {
  const ResponsiveBody({super.key, required this.child, this.maxWidth = 1040, this.padding = const EdgeInsets.all(16)});
  final Widget child;
  final double maxWidth;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: Padding(padding: padding, child: child)),
      );
}

bool isWide(BuildContext c) => MediaQuery.sizeOf(c).width >= 900;

/// Layout classes used across the app: phone (bottom nav), tablet (rail), desktop (sidebar).
enum Layout { mobile, tablet, desktop }

Layout layoutOf(BuildContext c) {
  final w = MediaQuery.sizeOf(c).width;
  return w < 700 ? Layout.mobile : (w < 1100 ? Layout.tablet : Layout.desktop);
}

class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.onTap});
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
      );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 20, 2, 8),
        child: Row(children: [
          Expanded(child: Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
          if (trailing != null) trailing!,
        ]),
      );
}

class KeyValue extends StatelessWidget {
  const KeyValue(this.k, this.v, {super.key, this.copy = false, this.mono = false, this.child});
  final String k;
  final String? v;
  final bool copy, mono;
  final Widget? child;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 130, child: Text(k, style: TextStyle(color: Theme.of(context).hintColor))),
          Expanded(
            child: child ??
                SelectableText(v == null || v!.isEmpty ? '—' : v!,
                    style: TextStyle(fontWeight: FontWeight.w600, fontFamily: mono ? 'monospace' : null, fontSize: mono ? 13 : null)),
          ),
          if (copy && v != null) IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.copy, size: 16), onPressed: () => copyText(context, v!)),
        ]),
      );
}

// ───────────── status ─────────────
Color statusColor(String s) {
  switch (s.toUpperCase()) {
    case 'PAID':
    case 'SETTLED':
    case 'VERIFIED':
    case 'CONFIRMED':
    case 'LISTED':
    case 'AVAILABLE':
    case 'APPROVED':
      return Tokens.success;
    case 'PENDING':
    case 'REQUESTED':
    case 'SUBMITTED':
    case 'UNDER_REVIEW':
    case 'PARTIALLY_PAID':
    case 'FUNDED':
    case 'ACTIVE':
      return Tokens.info;
    case 'OVERDUE':
    case 'DEFAULTED':
    case 'EXPIRED':
      return Tokens.warning;
    case 'CANCELLED':
    case 'REJECTED':
    case 'FAILED':
      return Tokens.danger;
    default:
      return Tokens.slate;
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key, this.label});
  final String status;
  final String? label;
  @override
  Widget build(BuildContext context) {
    final c = statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Text(label ?? titleCase(status), style: TextStyle(color: c, fontWeight: FontWeight.w700, fontSize: 12)),
    );
  }
}

class TxLink extends StatelessWidget {
  const TxLink(this.hash, {super.key, this.url});
  final String hash;
  final String? url;
  @override
  Widget build(BuildContext context) => Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, children: [
        SelectableText(shortHash(hash), style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
        IconButton(visualDensity: VisualDensity.compact, tooltip: 'Copy hash', icon: const Icon(Icons.copy, size: 16), onPressed: () => copyText(context, hash, 'Hash copied')),
        IconButton(visualDensity: VisualDensity.compact, tooltip: 'Open in explorer', icon: const Icon(Icons.open_in_new, size: 16), onPressed: () => openUrl(context, url ?? AppConfig.txUrl(hash))),
      ]);
}

// ───────────── async states ─────────────
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 48, color: Theme.of(context).hintColor),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700), textAlign: TextAlign.center),
            if (message != null) ...[const SizedBox(height: 6), Text(message!, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).hintColor))],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ]),
        ),
      );
}

class ErrorState extends StatelessWidget {
  const ErrorState(this.error, {super.key, this.onRetry});
  final Object error;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => EmptyState(
        icon: Icons.error_outline,
        title: 'Something went wrong',
        message: errorText(error),
        action: onRetry == null ? null : OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Try again')),
      );
}

/// loading / error / empty / data in one place so every screen handles all four states.
class AsyncView<T> extends StatelessWidget {
  const AsyncView({super.key, required this.value, required this.builder, this.onRetry, this.isEmpty, this.empty});
  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback? onRetry;
  final bool Function(T data)? isEmpty;
  final Widget? empty;
  @override
  Widget build(BuildContext context) => value.when(
        skipLoadingOnReload: true,
        loading: () => const Center(child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator())),
        error: (e, _) => ErrorState(e, onRetry: onRetry),
        data: (d) => (isEmpty?.call(d) ?? false) ? (empty ?? const SizedBox.shrink()) : builder(d),
      );
}

class BusyButton extends StatelessWidget {
  const BusyButton({super.key, required this.label, required this.onPressed, this.busy = false, this.icon, this.outlined = false});
  final String label;
  final VoidCallback? onPressed;
  final bool busy, outlined;
  final IconData? icon;
  @override
  Widget build(BuildContext context) {
    final child = busy
        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4))
        : Row(mainAxisSize: MainAxisSize.min, children: [if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 8)], Flexible(child: Text(label, overflow: TextOverflow.ellipsis))]);
    return outlined
        ? OutlinedButton(onPressed: busy ? null : onPressed, child: child)
        : FilledButton(onPressed: busy ? null : onPressed, child: child);
  }
}

class InfoBanner extends StatelessWidget {
  const InfoBanner(this.text, {super.key, this.tone = BannerTone.info, this.icon});
  final String text;
  final BannerTone tone;
  final IconData? icon;
  @override
  Widget build(BuildContext context) {
    final c = switch (tone) { BannerTone.info => Tokens.info, BannerTone.warn => Tokens.warning, BannerTone.error => Tokens.danger, BannerTone.success => Tokens.success };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.09), borderRadius: BorderRadius.circular(12), border: Border.all(color: c.withValues(alpha: 0.35))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon ?? Icons.info_outline, color: c, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
      ]),
    );
  }
}

enum BannerTone { info, warn, error, success }

class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.sub, this.icon, this.color});
  final String label, value;
  final String? sub;
  final IconData? icon;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return AppCard(
      padding: const EdgeInsets.all(18),
      child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 84), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800))),
            if (sub != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(sub!, style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12))),
          ]),
        ),
        if (icon != null)
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(color: c.withValues(alpha: .1), borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, size: 20, color: c),
          ),
      ])),
    );
  }
}

/// Page heading with optional subtitle and actions; actions wrap under the title on narrow screens.
class PageHeader extends StatelessWidget {
  const PageHeader(this.title, {super.key, this.subtitle, this.actions = const []});
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: t.textTheme.headlineSmall),
      if (subtitle != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(subtitle!, style: TextStyle(color: t.hintColor))),
    ]);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: LayoutBuilder(builder: (c, box) => box.maxWidth >= 640 && actions.isNotEmpty
          ? Row(crossAxisAlignment: CrossAxisAlignment.center, children: [Expanded(child: text), Wrap(spacing: 8, children: actions)])
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [text, if (actions.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Wrap(spacing: 8, runSpacing: 8, children: actions))])),
    );
  }
}

/// Two cards side by side on wide layouts, stacked on narrow ones.
class TwoCol extends StatelessWidget {
  const TwoCol(this.a, this.b, {super.key});
  final Widget a, b;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (c, box) => box.maxWidth >= 820
      ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: a), const SizedBox(width: 16), Expanded(child: b)])
      : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [a, const SizedBox(height: 4), b]));
}

/// Grid of tiles that reflows from 2 to 4 columns.
class StatGrid extends StatelessWidget {
  const StatGrid(this.tiles, {super.key});
  final List<Widget> tiles;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (c, box) {
        final cols = box.maxWidth >= 860 ? 4 : (box.maxWidth >= 560 ? 3 : 2);
        final rows = <Widget>[];
        for (var i = 0; i < tiles.length; i += cols) {
          final slice = tiles.skip(i).take(cols).toList();
          rows.add(Padding(
            padding: EdgeInsets.only(bottom: i + cols < tiles.length ? 12 : 0),
            child: IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (var j = 0; j < cols; j++) ...[
                  if (j > 0) const SizedBox(width: 12),
                  Expanded(child: j < slice.length ? slice[j] : const SizedBox.shrink()),
                ],
              ]),
            ),
          ));
        }
        return Column(children: rows);
      });
}

/// Proportional stacked bar (no chart dependency): [segments] are label -> count.
class StackedBar extends StatelessWidget {
  const StackedBar(this.segments, {super.key});
  final Map<String, int> segments;
  @override
  Widget build(BuildContext context) {
    final total = segments.values.fold<int>(0, (a, b) => a + b);
    if (total == 0) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Row(children: [
          for (final e in segments.entries.where((e) => e.value > 0))
            Expanded(flex: e.value, child: Container(height: 12, color: statusColor(e.key), margin: const EdgeInsets.only(right: 1))),
        ]),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 14, runSpacing: 4, children: [
        for (final e in segments.entries.where((e) => e.value > 0))
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 9, height: 9, decoration: BoxDecoration(color: statusColor(e.key), shape: BoxShape.circle)),
            const SizedBox(width: 5),
            Text('${titleCase(e.key)} ${e.value}', style: const TextStyle(fontSize: 12)),
          ]),
      ]),
    ]);
  }
}

/// Shown instead of investor screens until an admin verifies the investor (the backend enforces this too).
class InvestorGate extends StatelessWidget {
  const InvestorGate(this.status, {super.key, required this.onAction});
  final String status; // unverified | pending | rejected
  final void Function(String route) onAction;
  @override
  Widget build(BuildContext context) {
    final (icon, title, msg, label, route) = switch (status) {
      'pending' => (Icons.hourglass_top_rounded, 'Verification in review', 'Thanks for submitting your details. An admin is reviewing them, and the marketplace opens as soon as you are verified.', 'View verification status', '/investor/verification'),
      'rejected' => (Icons.error_outline, 'Verification needs attention', 'Your verification was not approved. Update your details and resubmit.', 'Update and resubmit', '/onboarding/investor'),
      _ => (Icons.verified_user_outlined, 'Verify your investor profile', 'Complete a short verification to browse and fund invoice offers. It only takes a minute.', 'Start verification', '/onboarding/investor'),
    };
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: AppCard(
            padding: const EdgeInsets.all(28),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Tokens.teal.withValues(alpha: .12), shape: BoxShape.circle), child: Icon(icon, size: 36, color: Tokens.tealDeep)),
              const SizedBox(height: 18),
              Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(msg, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).hintColor, height: 1.45)),
              const SizedBox(height: 22),
              FilledButton(onPressed: () => onAction(route), child: Text(label)),
            ]),
          ),
        ),
      ),
    );
  }
}
