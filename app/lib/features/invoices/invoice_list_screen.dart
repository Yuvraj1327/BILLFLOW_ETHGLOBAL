import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/widgets.dart';
import '../../shared/models/models.dart';
import '../../shared/widgets/paged_list.dart';

const invoiceStatuses = ['DRAFT', 'PENDING', 'PARTIALLY_PAID', 'PAID', 'OVERDUE', 'CANCELLED'];

class InvoiceListScreen extends ConsumerStatefulWidget {
  const InvoiceListScreen({super.key});
  @override
  ConsumerState<InvoiceListScreen> createState() => _S();
}

class _S extends ConsumerState<InvoiceListScreen> {
  String? _status;
  String _q = '';
  int _token = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
        floatingActionButton: FloatingActionButton.extended(onPressed: () => context.push('/merchant/invoices/new'), icon: const Icon(Icons.add), label: const Text('New invoice')),
        body: ResponsiveBody(
          padding: EdgeInsets.zero,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(children: [
                TextField(
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search by invoice number'),
                  onSubmitted: (s) => setState(() {
                    _q = s.trim();
                    _token++;
                  }),
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    Padding(padding: const EdgeInsets.only(right: 6), child: ChoiceChip(label: const Text('All'), selected: _status == null, onSelected: (_) => setState(() { _status = null; _token++; }))),
                    for (final s in invoiceStatuses)
                      Padding(padding: const EdgeInsets.only(right: 6), child: ChoiceChip(label: Text(titleCase(s)), selected: _status == s, onSelected: (_) => setState(() { _status = s; _token++; }))),
                  ]),
                ),
              ]),
            ),
            Expanded(
              child: PagedList<Invoice>(
                reloadToken: _token,
                load: (p) => ref.read(apiProvider).invoices(page: p, status: _status, q: _q.isEmpty ? null : _q),
                empty: EmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: 'No invoices found',
                  message: _status == null && _q.isEmpty ? 'Create your first invoice, or upload a PDF and let AI extract the fields for your review.' : 'Try a different filter.',
                  action: FilledButton(onPressed: () => context.push('/merchant/invoices/new'), child: const Text('Create invoice')),
                ),
                itemBuilder: (c, i) => AppCard(
                  onTap: () => c.push('/merchant/invoices/${i.id}'),
                  child: Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(i.number, style: const TextStyle(fontWeight: FontWeight.w800)),
                      Text(i.customerName ?? '—', style: TextStyle(color: Theme.of(c).hintColor)),
                      Text('Due ${fmtDate(i.dueDate)}', style: TextStyle(color: Theme.of(c).hintColor, fontSize: 12)),
                    ])),
                    Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text(fmtUsdt(i.amount), style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      StatusChip(i.status),
                      if (i.financingStatus != null) Padding(padding: const EdgeInsets.only(top: 4), child: StatusChip(i.financingStatus!, label: 'Financing: ${titleCase(i.financingStatus!)}')),
                    ]),
                  ]),
                ),
              ),
            ),
          ]),
        ),
      );
}
