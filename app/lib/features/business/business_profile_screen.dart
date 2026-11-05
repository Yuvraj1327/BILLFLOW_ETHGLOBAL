import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/format.dart';
import '../../core/utils/validators.dart' as v;
import '../../core/widgets/widgets.dart';
import '../../shared/models/models.dart';

final businessProvider = FutureProvider.autoDispose<Business>((ref) => ref.watch(apiProvider).myBusiness());
final membersProvider = FutureProvider.autoDispose<List<Member>>((ref) => ref.watch(apiProvider).members());

class BusinessProfileScreen extends ConsumerWidget {
  const BusinessProfileScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final biz = ref.watch(businessProvider);
    final members = ref.watch(membersProvider);
    return SingleChildScrollView(
      child: ResponsiveBody(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AsyncView<Business>(
            value: biz,
            onRetry: () => ref.invalidate(businessProvider),
            builder: (b) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (!b.isVerified)
                InfoBanner(
                  b.verificationStatus == 'rejected'
                      ? 'Your business verification was rejected. Update your details or contact support.'
                      : 'Your business is not verified yet. You can invoice and get paid; financing needs a verified business.',
                  tone: b.verificationStatus == 'rejected' ? BannerTone.error : BannerTone.warn,
                ),
              const SizedBox(height: 12),
              AppCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(b.legalName, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800))),
                    StatusChip(b.verificationStatus),
                  ]),
                  const SizedBox(height: 8),
                  KeyValue('Country', b.country),
                  KeyValue('Tax ID', b.taxId),
                  KeyValue('Payout wallet', b.payoutWallet, copy: true, mono: true),
                  KeyValue('Verified at', b.verifiedAt == null ? null : fmtDate(b.verifiedAt)),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(onPressed: () => _edit(context, ref, b), icon: const Icon(Icons.edit_outlined), label: const Text('Edit business')),
                ]),
              ),
            ]),
          ),
          SectionTitle('Team', trailing: TextButton.icon(onPressed: () => _addMember(context, ref), icon: const Icon(Icons.person_add_alt), label: const Text('Add member'))),
          AsyncView<List<Member>>(
            value: members,
            onRetry: () => ref.invalidate(membersProvider),
            builder: (list) => Column(children: [
              for (final m in list)
                AppCard(
                  child: Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(m.displayName ?? m.email ?? m.userId, style: const TextStyle(fontWeight: FontWeight.w600)), Text(titleCase(m.role), style: TextStyle(color: Theme.of(context).hintColor))])),
                    if (m.role != 'owner')
                      IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.person_remove_outlined),
                        onPressed: () async {
                          if (!await confirm(context, 'Remove member?', 'They will lose access to this business.', action: 'Remove', destructive: true)) return;
                          try {
                            await ref.read(apiProvider).removeMember(m.userId);
                            ref.invalidate(membersProvider);
                          } catch (e) {
                            if (context.mounted) toast(context, errorText(e), error: true);
                          }
                        },
                      ),
                  ]),
                ),
            ]),
          ),
          const SizedBox(height: 8),
          const Text('Logo, address and contact fields are not part of the current backend schema, so they are not shown here.', style: TextStyle(fontSize: 12)),
        ]),
      ),
    );
  }

  Future<void> _addMember(BuildContext context, WidgetRef ref) async {
    final c = TextEditingController();
    final form = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add team member'),
        content: Form(key: form, child: TextFormField(controller: c, autofocus: true, decoration: const InputDecoration(labelText: 'Email of an existing merchant account'), validator: v.email)),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), FilledButton(onPressed: () { if (form.currentState!.validate()) Navigator.pop(ctx, true); }, child: const Text('Add'))],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(apiProvider).addMember(c.text.trim());
      ref.invalidate(membersProvider);
    } catch (e) {
      if (context.mounted) toast(context, errorText(e), error: true);
    }
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, Business b) async {
    final name = TextEditingController(text: b.legalName), country = TextEditingController(text: b.country), tax = TextEditingController(text: b.taxId), wallet = TextEditingController(text: b.payoutWallet);
    final form = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit business'),
        content: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextFormField(controller: name, decoration: const InputDecoration(labelText: 'Legal name'), validator: (x) => v.required(x, 'Name')),
              const SizedBox(height: 10),
              TextFormField(controller: country, decoration: const InputDecoration(labelText: 'Country')),
              const SizedBox(height: 10),
              TextFormField(controller: tax, decoration: const InputDecoration(labelText: 'Tax ID')),
              const SizedBox(height: 10),
              TextFormField(controller: wallet, decoration: const InputDecoration(labelText: 'Payout wallet'), validator: v.optionalAddress),
            ]),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), FilledButton(onPressed: () { if (form.currentState!.validate()) Navigator.pop(ctx, true); }, child: const Text('Save'))],
      ),
    );
    if (ok != true) return;
    try {
      String? n(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
      await ref.read(apiProvider).updateBusiness({'legal_name': name.text.trim(), 'country': n(country), 'tax_id': n(tax), 'payout_wallet': n(wallet)});
      ref.invalidate(businessProvider);
      if (context.mounted) toast(context, 'Business updated');
    } catch (e) {
      if (context.mounted) toast(context, errorText(e), error: true);
    }
  }
}
