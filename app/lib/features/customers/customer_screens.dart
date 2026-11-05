import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/format.dart';
import '../../core/utils/validators.dart' as v;
import '../../core/widgets/widgets.dart';
import '../../shared/models/models.dart';
import '../../shared/widgets/paged_list.dart';

class CustomerListScreen extends ConsumerStatefulWidget {
  const CustomerListScreen({super.key});
  @override
  ConsumerState<CustomerListScreen> createState() => _ListState();
}

class _ListState extends ConsumerState<CustomerListScreen> {
  String _q = '';
  bool _archived = false;
  int _token = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () async {
            if (await showCustomerForm(context, ref) == true) setState(() => _token++);
          },
          icon: const Icon(Icons.person_add_alt),
          label: const Text('Add customer'),
        ),
        body: ResponsiveBody(
          padding: EdgeInsets.zero,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search customers'),
                    onSubmitted: (s) => setState(() {
                      _q = s.trim();
                      _token++;
                    }),
                  ),
                ),
                const SizedBox(width: 8),
                FilterChip(label: const Text('Archived'), selected: _archived, onSelected: (s) => setState(() {
                      _archived = s;
                      _token++;
                    })),
              ]),
            ),
            Expanded(
              child: PagedList<Customer>(
                reloadToken: _token,
                load: (p) => ref.read(apiProvider).customers(page: p, q: _q.isEmpty ? null : _q, archived: _archived),
                empty: EmptyState(
                  icon: Icons.people_outline,
                  title: _archived ? 'No archived customers' : 'No customers yet',
                  message: _archived ? null : 'Add the businesses or people you invoice. Their wallet is optional.',
                ),
                itemBuilder: (c, cu) => AppCard(
                  onTap: () => c.push('/merchant/customers/${cu.id}'),
                  child: Row(children: [
                    CircleAvatar(child: Text(cu.name.isEmpty ? '?' : cu.name[0].toUpperCase())),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(cu.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text(cu.email ?? 'No email', style: TextStyle(color: Theme.of(c).hintColor)),
                    ])),
                    if (cu.archived) const StatusChip('archived'),
                    const Icon(Icons.chevron_right),
                  ]),
                ),
              ),
            ),
          ]),
        ),
      );
}

/// Create (customer == null) or edit. Returns true when saved.
Future<bool?> showCustomerForm(BuildContext context, WidgetRef ref, {Customer? customer}) {
  final name = TextEditingController(text: customer?.name), email = TextEditingController(text: customer?.email), wallet = TextEditingController(text: customer?.walletAddress);
  final form = GlobalKey<FormState>();
  var busy = false;
  return showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: Text(customer == null ? 'Add customer' : 'Edit customer'),
        content: SingleChildScrollView(
          child: Form(
            key: form,
            child: SizedBox(
              width: 420,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextFormField(controller: name, decoration: const InputDecoration(labelText: 'Name *'), validator: (x) => v.required(x, 'Name')),
                const SizedBox(height: 10),
                TextFormField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email'), validator: (x) => (x == null || x.trim().isEmpty) ? null : v.email(x)),
                const SizedBox(height: 10),
                TextFormField(controller: wallet, decoration: const InputDecoration(labelText: 'Wallet address (optional)'), validator: v.optionalAddress),
              ]),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    if (!form.currentState!.validate()) return;
                    setS(() => busy = true);
                    String? n(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
                    final body = {'name': name.text.trim(), 'email': n(email), 'wallet_address': n(wallet)};
                    try {
                      final api = ref.read(apiProvider);
                      if (customer == null) {
                        await api.createCustomer(body);
                      } else {
                        await api.updateCustomer(customer.id, body);
                      }
                      if (ctx.mounted) Navigator.pop(ctx, true);
                    } catch (e) {
                      setS(() => busy = false);
                      if (ctx.mounted) toast(ctx, errorText(e), error: true);
                    }
                  },
            child: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

final customerProvider = FutureProvider.autoDispose.family<Customer, String>((ref, id) => ref.watch(apiProvider).customer(id));

class CustomerDetailScreen extends ConsumerStatefulWidget {
  const CustomerDetailScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<CustomerDetailScreen> createState() => _DetailState();
}

class _DetailState extends ConsumerState<CustomerDetailScreen> {
  int _token = 0;
  @override
  Widget build(BuildContext context) {
    final cu = ref.watch(customerProvider(widget.id));
    return ResponsiveBody(
      padding: EdgeInsets.zero,
      child: AsyncView<Customer>(
        value: cu,
        onRetry: () => ref.invalidate(customerProvider(widget.id)),
        builder: (c) => PagedList<Invoice>(
          reloadToken: _token,
          load: (p) => ref.read(apiProvider).invoices(page: p, customerId: c.id),
          header: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AppCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(c.name, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800))),
                  if (c.archived) const StatusChip('archived'),
                ]),
                KeyValue('Email', c.email),
                KeyValue('Wallet', c.walletAddress, copy: true, mono: true),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  FilledButton.icon(onPressed: c.archived ? null : () => context.push('/merchant/invoices/new?customer=${c.id}'), icon: const Icon(Icons.add), label: const Text('New invoice')),
                  OutlinedButton.icon(
                    onPressed: () async {
                      if (await showCustomerForm(context, ref, customer: c) == true) ref.invalidate(customerProvider(c.id));
                    },
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Edit'),
                  ),
                  if (!c.archived)
                    OutlinedButton.icon(
                      onPressed: () async {
                        if (!await confirm(context, 'Archive customer?', 'Their invoices keep their history. You can no longer invoice them.', action: 'Archive', destructive: true)) return;
                        try {
                          await ref.read(apiProvider).archiveCustomer(c.id);
                          if (context.mounted) context.pop();
                        } catch (e) {
                          if (context.mounted) toast(context, errorText(e), error: true);
                        }
                      },
                      icon: const Icon(Icons.archive_outlined),
                      label: const Text('Archive'),
                    ),
                ]),
              ]),
            ),
            const SectionTitle('Invoice history'),
          ]),
          empty: const EmptyState(icon: Icons.receipt_long_outlined, title: 'No invoices for this customer yet'),
          itemBuilder: (ctx, i) => AppCard(
            onTap: () => ctx.push('/merchant/invoices/${i.id}'),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(i.number, style: const TextStyle(fontWeight: FontWeight.w700)), Text('Due ${fmtDate(i.dueDate)}', style: TextStyle(color: Theme.of(ctx).hintColor))])),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [Text(fmtUsdt(i.amount), style: const TextStyle(fontWeight: FontWeight.w700)), const SizedBox(height: 4), StatusChip(i.status)]),
            ]),
          ),
        ),
      ),
    );
  }
}
