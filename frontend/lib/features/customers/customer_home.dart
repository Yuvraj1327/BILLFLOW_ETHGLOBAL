import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/widgets.dart';
import '../../shared/models/models.dart';
import '../../shared/widgets/paged_list.dart';

/// Home for the "customer" role: open a payment link and see payments made.
class CustomerHome extends ConsumerStatefulWidget {
  const CustomerHome({super.key});
  @override
  ConsumerState<CustomerHome> createState() => _S();
}

class _S extends ConsumerState<CustomerHome> {
  final _link = TextEditingController();
  String? _err;

  /// Accepts a full link (…/pay/<token>) or a bare token.
  void _open() {
    final t = _link.text.trim();
    final m = RegExp(r'/pay/([A-Za-z0-9_\-]+)').firstMatch(t);
    final token = m?.group(1) ?? (RegExp(r'^[A-Za-z0-9_\-]{16,}$').hasMatch(t) ? t : null);
    if (token == null) {
      setState(() => _err = 'Paste the payment link you received from the merchant.');
      return;
    }
    context.go('/pay/$token');
  }

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ResponsiveBody(
        padding: EdgeInsets.zero,
        child: PagedList<Payment>(
          load: (p) => ref.read(apiProvider).payments(page: p),
          header: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AppCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Pay an invoice', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                TextField(controller: _link, decoration: InputDecoration(labelText: 'Payment link', errorText: _err), onSubmitted: (_) => _open()),
                const SizedBox(height: 10),
                FilledButton(onPressed: _open, child: const Text('Open checkout')),
                const SizedBox(height: 6),
                Text('You do not need an account to pay: open the link and connect your wallet.', style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12)),
              ]),
            ),
            const SectionTitle('Your payments'),
          ]),
          empty: const EmptyState(icon: Icons.receipt_long_outlined, title: 'No payments yet', message: 'Payments you make from this account appear here once verified by NEXA BILLFLOW.'),
          itemBuilder: (c, p) => AppCard(
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.invoiceNumber ?? 'Invoice', style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(fmtDateTime(p.confirmedAt), style: TextStyle(color: Theme.of(c).hintColor)),
                TxLink(p.txHash, url: p.explorerUrl),
              ])),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [Text(fmtUsdt(p.amount), style: const TextStyle(fontWeight: FontWeight.w700)), const SizedBox(height: 4), StatusChip(p.status)]),
            ]),
          ),
        ),
      );
}
