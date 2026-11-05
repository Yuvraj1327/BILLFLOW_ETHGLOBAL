import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:printing/printing.dart';

import '../../app/providers.dart';
import '../../core/config/app_config.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/widgets.dart';
import '../../shared/models/models.dart';
import '../invoices/invoice_pdf.dart';


class _ReceiptData {
  _ReceiptData(this.invoice, this.payment);
  final PublicInvoice invoice;
  final PaymentRecord? payment;
}

final _receiptProvider = FutureProvider.autoDispose.family<_ReceiptData, (String, String)>((ref, key) async {
  final api = ref.watch(apiProvider);
  final inv = await api.publicInvoice(key.$1);
  final st = await api.publicStatus(key.$1);
  final m = st.payments.where((p) => p.txHash.toLowerCase() == key.$2.toLowerCase());
  return _ReceiptData(inv, m.isEmpty ? null : m.first);
});

/// Receipt only for payments the BACKEND lists as confirmed for this link.
class ReceiptScreen extends ConsumerWidget {
  const ReceiptScreen({super.key, required this.token, required this.txHash});
  final String token, txHash;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_receiptProvider((token, txHash)));
    return Scaffold(
      appBar: AppBar(title: const Text('Payment receipt'), leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/pay/$token'))),
      body: SingleChildScrollView(
        child: ResponsiveBody(
          maxWidth: 560,
          child: AsyncView<_ReceiptData>(
            value: data,
            onRetry: () => ref.invalidate(_receiptProvider((token, txHash))),
            builder: (d) {
              final p = d.payment;
              if (p == null || (p.status ?? 'CONFIRMED') != 'CONFIRMED') {
                return Column(children: [
                  const InfoBanner('This payment has not been verified by BillFlow yet, so no receipt is available. Check back shortly.', tone: BannerTone.warn),
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: () => ref.invalidate(_receiptProvider((token, txHash))), child: const Text('Refresh')),
                ]);
              }
              return AppCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const InfoBanner('Verified on-chain by BillFlow', tone: BannerTone.success, icon: Icons.verified),
                  const SizedBox(height: 10),
                  KeyValue('Merchant', d.invoice.merchantName),
                  KeyValue('Invoice', d.invoice.number),
                  KeyValue('Amount', fmtUsdt(p.amount)),
                  KeyValue('Payer', p.payerWallet, copy: true, mono: true),
                  KeyValue('Confirmed', fmtDateTime(p.confirmedAt)),
                  KeyValue('Network', AppConfig.chainName),
                  KeyValue('Transaction', null, child: TxLink(p.txHash, url: p.explorerUrl)),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    icon: const Icon(Icons.download),
                    label: const Text('Download receipt (PDF)'),
                    onPressed: () async {
                      try {
                        final bytes = await buildReceiptPdf(
                          merchantName: d.invoice.merchantName, invoiceNumber: d.invoice.number, amount: p.amount, payer: p.payerWallet,
                          txHash: p.txHash, explorerUrl: p.explorerUrl ?? AppConfig.txUrl(p.txHash), confirmedAt: p.confirmedAt,
                        );
                        await Printing.sharePdf(bytes: bytes, filename: 'receipt-${d.invoice.number}.pdf');
                      } catch (e) {
                        if (context.mounted) toast(context, errorText(e), error: true);
                      }
                    },
                  ),
                ]),
              );
            },
          ),
        ),
      ),
    );
  }
}
