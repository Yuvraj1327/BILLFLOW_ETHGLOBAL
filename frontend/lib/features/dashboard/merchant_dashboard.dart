import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/widgets.dart';
import '../../shared/models/models.dart';

class DashboardData {
  DashboardData({required this.byStatus, required this.invoiced, required this.collected, required this.outstanding, required this.decimals, required this.total, required this.fetched, required this.offers, required this.recent, required this.business});
  final Map<String, int> byStatus;
  final BigInt invoiced, collected, outstanding;
  final int decimals, total, fetched;
  final Map<String, int> offers;
  final List<Payment> recent;
  final Business? business;
  bool get truncated => fetched < total;
}

/// The backend has no aggregate endpoint, so figures are computed from real invoice rows (up to 500) with exact BigInt math.
final merchantDashboardProvider = FutureProvider.autoDispose<DashboardData>((ref) async {
  final api = ref.watch(apiProvider);
  final first = await api.invoices(page: 1, pageSize: 100);
  final all = [...first.items];
  for (var p = 2; p <= 5 && all.length < first.total; p++) {
    all.addAll((await api.invoices(page: p, pageSize: 100)).items);
  }
  final by = <String, int>{};
  var invoiced = BigInt.zero, collected = BigInt.zero, outstanding = BigInt.zero;
  for (final i in all) {
    by[i.status] = (by[i.status] ?? 0) + 1;
    if (i.status == 'CANCELLED' || i.status == 'DRAFT') continue;
    invoiced += i.amountBase;
    collected += i.paidBase;
    if (i.status != 'PAID') outstanding += i.remainingBase;
  }
  final offers = <String, int>{};
  Business? biz;
  List<Payment> recent = const [];
  try {
    for (final o in (await api.offers()).items) {
      offers[o.displayStatus] = (offers[o.displayStatus] ?? 0) + 1;
    }
  } catch (_) {}
  try {
    recent = (await api.payments(pageSize: 5)).items;
  } catch (_) {}
  try {
    biz = await api.myBusiness();
  } catch (_) {}
  return DashboardData(
    byStatus: by, invoiced: invoiced, collected: collected, outstanding: outstanding,
    decimals: all.isEmpty ? 6 : all.first.decimals, total: first.total, fetched: all.length, offers: offers, recent: recent, business: biz,
  );
});

class MerchantDashboard extends ConsumerWidget {
  const MerchantDashboard({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(merchantDashboardProvider);
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(merchantDashboardProvider),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ResponsiveBody(
          child: AsyncView<DashboardData>(
            value: data,
            onRetry: () => ref.invalidate(merchantDashboardProvider),
            builder: (d) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              PageHeader('Welcome back, ${(ref.watch(authProvider).valueOrNull?.label ?? '').split(' ').first}',
                  subtitle: 'Here is how your invoices and payments are doing.',
                  actions: [
                    OutlinedButton.icon(onPressed: () => context.go('/merchant/customers'), icon: const Icon(Icons.person_add_alt_1_outlined), label: const Text('Add customer')),
                    FilledButton.icon(onPressed: () => context.push('/merchant/invoices/new'), icon: const Icon(Icons.add), label: const Text('New invoice')),
                  ]),
              if (d.business != null && (d.business!.payoutWallet ?? '').isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: AppCard(child: Row(children: [
                    const Icon(Icons.account_balance_wallet_outlined),
                    const SizedBox(width: 12),
                    const Expanded(child: Text('Add a payout wallet to your business so you can issue invoices and receive USDT.', style: TextStyle(fontWeight: FontWeight.w600))),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: () => context.push('/merchant/business'), child: const Text('Add wallet')),
                  ])),
                ),
              if (d.business != null && !d.business!.isVerified)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: InfoBanner('Business verification: ${titleCase(d.business!.verificationStatus)}. Financing requires a verified business.', tone: BannerTone.warn, icon: Icons.verified_user_outlined),
                ),
              StatGrid([
                StatTile(label: 'Invoiced', value: fmtUsdt(fromBase(d.invoiced, d.decimals)), icon: Icons.receipt_long_outlined),
                StatTile(label: 'Collected (verified)', value: fmtUsdt(fromBase(d.collected, d.decimals)), icon: Icons.verified_outlined, color: Colors.green),
                StatTile(label: 'Outstanding', value: fmtUsdt(fromBase(d.outstanding, d.decimals)), icon: Icons.hourglass_bottom, color: Colors.orange),
                StatTile(label: 'Overdue', value: '${d.byStatus['OVERDUE'] ?? 0}', sub: 'invoices', icon: Icons.warning_amber_outlined, color: Colors.red),
              ]),
              if (d.truncated) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Showing totals for the latest ${d.fetched} of ${d.total} invoices.', style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12))),
              TwoCol(
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const SectionTitle('Invoices by status'),
              AppCard(
                child: d.total == 0
                    ? EmptyState(icon: Icons.receipt_long_outlined, title: 'No invoices yet', message: 'Create your first invoice to see your numbers here.', action: FilledButton(onPressed: () => context.push('/merchant/invoices/new'), child: const Text('Create invoice')))
                    : StackedBar(d.byStatus),
              ),
              ]),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SectionTitle('Financing', trailing: TextButton(onPressed: () => context.go('/merchant/financing'), child: const Text('Open'))),
              AppCard(
                child: d.offers.isEmpty
                    ? const Text('No financing requests. Eligible invoices can be financed from the invoice page.')
                    : Wrap(spacing: 8, runSpacing: 8, children: [for (final e in d.offers.entries) StatusChip(e.key, label: '${titleCase(e.key)}: ${e.value}')]),
              ),
              ]),
              ),
              SectionTitle('Recent verified payments', trailing: TextButton(onPressed: () => context.go('/transactions'), child: const Text('All'))),
              if (d.recent.isEmpty)
                const AppCard(child: Text('No verified payments yet.'))
              else
                for (final p in d.recent)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: AppCard(
                      child: Row(children: [
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(p.invoiceNumber ?? 'Payment', style: const TextStyle(fontWeight: FontWeight.w700)),
                          Text('${shortAddr(p.payerWallet)} · ${fmtDate(p.confirmedAt)}', style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12)),
                        ])),
                        Text(fmtUsdt(p.amount), style: const TextStyle(fontWeight: FontWeight.w800)),
                      ]),
                    ),
                  ),
            ]),
          ),
        ),
      ),
    );
  }
}
