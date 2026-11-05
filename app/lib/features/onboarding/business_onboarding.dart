import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/validators.dart' as v;
import '../../core/widgets/widgets.dart';

/// Merchants without a business are routed here by the router (decided from the BACKEND profile).
class BusinessOnboardingScreen extends ConsumerStatefulWidget {
  const BusinessOnboardingScreen({super.key});
  @override
  ConsumerState<BusinessOnboardingScreen> createState() => _S();
}

class _S extends ConsumerState<BusinessOnboardingScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(), _country = TextEditingController(), _tax = TextEditingController(), _wallet = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_name, _country, _tax, _wallet]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      String? opt(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
      await ref.read(apiProvider).createBusiness({
        'legal_name': _name.text.trim(),
        if (opt(_country) != null) 'country': opt(_country),
        if (opt(_tax) != null) 'tax_id': opt(_tax),
        if (opt(_wallet) != null) 'payout_wallet': opt(_wallet),
      });
      await ref.read(authProvider.notifier).reload(); // router then sends the merchant to the dashboard
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final wallet = ref.watch(walletProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Set up your business'), actions: [TextButton(onPressed: () => ref.read(authProvider.notifier).signOut(), child: const Text('Log out'))]),
      body: SingleChildScrollView(
        child: ResponsiveBody(
          maxWidth: 560,
          child: Form(
            key: _form,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const InfoBanner('Tell us about the business that issues invoices. An admin will review it; financing requires a verified business.'),
              const SizedBox(height: 16),
              TextFormField(controller: _name, decoration: const InputDecoration(labelText: 'Legal business name *'), validator: (x) => v.required(x, 'Business name')),
              const SizedBox(height: 12),
              TextFormField(controller: _country, decoration: const InputDecoration(labelText: 'Country')),
              const SizedBox(height: 12),
              TextFormField(controller: _tax, decoration: const InputDecoration(labelText: 'Tax ID')),
              const SizedBox(height: 12),
              TextFormField(
                controller: _wallet,
                decoration: InputDecoration(
                  labelText: 'Payout wallet (receives USDT)',
                  helperText: 'Customers pay USDT to this address. Double-check it.',
                  suffixIcon: wallet.address == null ? null : IconButton(tooltip: 'Use connected wallet', icon: const Icon(Icons.account_balance_wallet_outlined), onPressed: () => _wallet.text = wallet.address!),
                ),
                validator: v.optionalAddress,
              ),
              const SizedBox(height: 20),
              BusyButton(label: 'Create business', busy: _busy, onPressed: _submit),
            ]),
          ),
        ),
      ),
    );
  }
}
