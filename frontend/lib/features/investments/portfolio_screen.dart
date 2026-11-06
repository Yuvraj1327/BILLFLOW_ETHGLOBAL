import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/widgets.dart';
import '../../shared/models/models.dart';
import '../../shared/widgets/paged_list.dart';

final portfolioProvider = FutureProvider.autoDispose<Json>((ref) => ref.watch(apiProvider).portfolio());

class PortfolioScreen extends ConsumerWidget {
  const PortfolioScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pf = ref.watch(portfolioProvider);
    return ResponsiveBody(
      padding: EdgeInsets.zero,
      child: PagedList<Investment>(
        load: (p) => ref.read(apiProvider).investments(page: p),
        header: AsyncView<Json>(
          value: pf,
          onRetry: () => ref.invalidate(portfolioProvider),
          builder: (j) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            StatGrid([
              StatTile(label: 'Active positions', value: '${j.integer('positions')}', icon: Icons.layers_outlined),
              StatTile(label: 'Invested (active)', value: fmtUsdt(j.str('active_invested')), icon: Icons.payments_outlined),
              StatTile(label: 'Expected repayment', value: fmtUsdt(j.str('expected_repayment')), sub: 'if debtors repay in full', icon: Icons.schedule),
              StatTile(label: 'Returned so far', value: fmtUsdt(j.str('returned')), sub: 'settled on-chain', icon: Icons.verified_outlined, color: Colors.green),
            ]),
            const SizedBox(height: 8),
            const Text('Figures come from on-chain events verified by the backend. Expected repayment is not guaranteed.', style: TextStyle(fontSize: 12)),
            const SectionTitle('Your investments'),
          ]),
        ),
        empty: const EmptyState(icon: Icons.pie_chart_outline, title: 'No investments yet', message: 'Fund an offer from the marketplace. It appears here after the backend verifies the transaction.'),
        itemBuilder: (c, i) => AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Expanded(child: Text(i.invoiceNumber, style: const TextStyle(fontWeight: FontWeight.w800))), StatusChip(i.status, label: i.status == 'CONFIRMED' ? 'Active' : null)]),
            const SizedBox(height: 6),
            KeyValue('Invested', fmtUsdt(i.amount)),
            KeyValue('Expected repayment', fmtUsdt(i.expectedRepayment)),
            KeyValue('Matures', fmtDate(i.maturityDate)),
            if (i.repaymentAmount != null) KeyValue('Repaid', fmtUsdt(i.repaymentAmount)),
            KeyValue('Funding tx', null, child: TxLink(i.txHash, url: i.explorerUrl)),
            if (i.repaymentTxHash != null) KeyValue('Settlement tx', null, child: TxLink(i.repaymentTxHash!)),
          ]),
        ),
      ),
    );
  }
}
