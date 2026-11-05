import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/config/app_config.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/widgets.dart';
import '../../shared/models/models.dart';
import '../../shared/widgets/paged_list.dart';

/// Unified history. Which data is shown depends on the BACKEND role; authorization is enforced server-side.
class TransactionsScreen extends ConsumerWidget {
  const TransactionsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(authProvider).valueOrNull;
    if (p == null) return const SizedBox.shrink();
    final api = ref.read(apiProvider);
    const empty = EmptyState(icon: Icons.swap_horiz, title: 'No transactions yet', message: 'Only on-chain activity verified by BillFlow is listed.');

    if (p.isAdmin) {
      return ResponsiveBody(
        padding: EdgeInsets.zero,
        child: PagedList<Json>(
          load: (pg) async => Paged.from(await api.adminList('transactions', page: pg), (j) => j),
          empty: empty,
          itemBuilder: (c, j) => AppCard(
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(titleCase(j.str('kind').isEmpty ? 'transaction' : j.str('kind')), style: const TextStyle(fontWeight: FontWeight.w700)),
                TxLink(j.str('tx_hash')),
                Text(fmtDateTime(j.date('created_at')), style: TextStyle(color: Theme.of(c).hintColor, fontSize: 12)),
              ])),
              StatusChip(j.str('status')),
            ]),
          ),
        ),
      );
    }
    if (p.isInvestor) {
      return ResponsiveBody(
        padding: EdgeInsets.zero,
        child: PagedList<Investment>(
          load: (pg) => api.investments(page: pg),
          empty: empty,
          itemBuilder: (c, i) => AppCard(
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Funded ${i.invoiceNumber}', style: const TextStyle(fontWeight: FontWeight.w700)),
                TxLink(i.txHash, url: i.explorerUrl),
                Text(fmtDateTime(i.fundedAt), style: TextStyle(color: Theme.of(c).hintColor, fontSize: 12)),
              ])),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [Text(fmtUsdt(i.amount), style: const TextStyle(fontWeight: FontWeight.w700)), const SizedBox(height: 4), StatusChip(i.status)]),
            ]),
          ),
        ),
      );
    }
    return ResponsiveBody(
      padding: EdgeInsets.zero,
      child: PagedList<Payment>(
        load: (pg) => api.payments(page: pg),
        empty: empty,
        itemBuilder: (c, x) => AppCard(
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(x.invoiceNumber ?? 'Payment', style: const TextStyle(fontWeight: FontWeight.w700)),
              Text('From ${shortAddr(x.payerWallet)}', style: TextStyle(color: Theme.of(c).hintColor)),
              TxLink(x.txHash, url: x.explorerUrl.isEmpty ? AppConfig.txUrl(x.txHash) : x.explorerUrl),
              Text(fmtDateTime(x.confirmedAt), style: TextStyle(color: Theme.of(c).hintColor, fontSize: 12)),
            ])),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(fmtUsdt(x.amount), style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              StatusChip(x.status, label: x.status == 'CONFIRMED' ? 'Verified' : null),
            ]),
          ]),
        ),
      ),
    );
  }
}
