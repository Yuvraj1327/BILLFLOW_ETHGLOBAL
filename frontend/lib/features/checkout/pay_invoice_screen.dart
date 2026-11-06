import '../../core/widgets/brand_logo.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/utils/validators.dart' as v;
import '../../core/widgets/widgets.dart';

/// PUBLIC entry for customers (/pay): paste an invoice/payment link, then continue to the normal public checkout.
/// No account, no login. The invoice itself is fetched from the backend by CheckoutScreen.
class PayInvoiceScreen extends StatefulWidget {
  const PayInvoiceScreen({super.key});
  @override
  State<PayInvoiceScreen> createState() => _PayInvoiceState();
}

class _PayInvoiceState extends State<PayInvoiceScreen> {
  final _form = GlobalKey<FormState>();
  final _link = TextEditingController();

  @override
  void dispose() { _link.dispose(); super.dispose(); }

  void _go() {
    if (!_form.currentState!.validate()) return;
    context.go('/pay/${v.parsePaymentToken(_link.text)!}');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const BrandTitle('Pay an invoice'), leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/welcome'))),
        body: SafeArea(
          child: SingleChildScrollView(
            child: ResponsiveBody(
              maxWidth: 480,
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _form,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Center(child: BillflowLogo(height: 96)),
                  const SizedBox(height: 16),
                  Text('Pay with USDT', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  const Text('No account needed. Paste the payment link you received, connect your wallet and pay. You will get a receipt once the payment is confirmed on-chain.', textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _link,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.go,
                    onFieldSubmitted: (_) => _go(),
                    decoration: const InputDecoration(labelText: 'Invoice or payment link', hintText: 'https://…/pay/…', prefixIcon: Icon(Icons.link)),
                    validator: (x) => (x ?? '').trim().isEmpty ? 'Paste your payment link' : (v.parsePaymentToken(x) == null ? 'This does not look like a NEXA BILLFLOW payment link' : null),
                  ),
                  const SizedBox(height: 20),
                  BusyButton(label: 'Continue to checkout', busy: false, onPressed: _go),
                ]),
              ),
            ),
          ),
        ),
      );
}
