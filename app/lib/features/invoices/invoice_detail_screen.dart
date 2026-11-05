import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/providers.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/widgets.dart';
import '../../shared/models/models.dart';
import 'invoice_pdf.dart';

final invoiceProvider = FutureProvider.autoDispose.family<Invoice, String>((ref, id) => ref.watch(apiProvider).invoice(id));
final invoiceStatusProvider = FutureProvider.autoDispose.family<PaymentStatus, String>((ref, id) => ref.watch(apiProvider).paymentStatus(id));
final invoiceDocsProvider = FutureProvider.autoDispose.family<List<InvoiceDoc>, String>((ref, id) => ref.watch(apiProvider).invoiceDocs(id));

class InvoiceDetailScreen extends ConsumerStatefulWidget {
  const InvoiceDetailScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<InvoiceDetailScreen> createState() => _S();
}

class _S extends ConsumerState<InvoiceDetailScreen> {
  bool _busy = false;
  PaymentLink? _link;
  AiNote? _note;
  Validation? _validation;
  String _aiBusy = '';
  String _tone = 'neutral';

  void _refresh() {
    ref.invalidate(invoiceProvider(widget.id));
    ref.invalidate(invoiceStatusProvider(widget.id));
    ref.invalidate(invoiceDocsProvider(widget.id));
  }

  Future<void> _run(Future<void> Function() f, {String? ok}) async {
    setState(() => _busy = true);
    try {
      await f();
      if (ok != null && mounted) toast(context, ok);
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _ai(String kind, Future<void> Function() f) async {
    setState(() => _aiBusy = kind);
    try {
      await f();
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    }
    if (mounted) setState(() => _aiBusy = '');
  }

  Future<void> _generateAndUploadPdf(Invoice inv) => _run(() async {
        final b = await ref.read(apiProvider).myBusiness();
        final bytes = await buildInvoicePdf(invoice: inv, merchantName: b.legalName, merchantWallet: b.payoutWallet);
        await Printing.layoutPdf(onLayout: (_) async => bytes, name: 'invoice-${inv.number}.pdf');
        if (!mounted) return;
        final yes = await confirm(context, 'Attach this PDF to the invoice?', 'The file is stored privately and its hash is recorded (required for financing).', action: 'Upload');
        if (!yes) return;
        await ref.read(apiProvider).uploadInvoicePdf(inv.id, bytes, 'invoice-${inv.number}.pdf');
        _refresh();
      }, ok: null);

  Future<void> _uploadPdf(Invoice inv) async {
    final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['pdf'], withData: true);
    final f = res?.files.single;
    if (f == null || f.bytes == null) return;
    await _run(() async {
      final d = await ref.read(apiProvider).uploadInvoicePdf(inv.id, f.bytes!, f.name);
      _refresh();
      if (mounted && d.duplicateWarnings.isNotEmpty) toast(context, 'Warning: ${d.duplicateWarnings.join('; ')}', error: true);
    }, ok: 'PDF uploaded');
  }

  @override
  Widget build(BuildContext context) {
    final inv = ref.watch(invoiceProvider(widget.id));
    return AsyncView<Invoice>(
      value: inv,
      onRetry: _refresh,
      builder: (i) {
        final status = i.isDraft ? null : ref.watch(invoiceStatusProvider(i.id));
        final docs = ref.watch(invoiceDocsProvider(i.id));
        return RefreshIndicator(
          onRefresh: () async => _refresh(),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: ResponsiveBody(
              maxWidth: 820,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                AppCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(i.number, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800))),
                      StatusChip(i.status),
                    ]),
                    const SizedBox(height: 4),
                    Text(fmtUsdt(i.amount), style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.primary)),
                    const SizedBox(height: 8),
                    KeyValue('Customer', i.customerName),
                    KeyValue('Issued', fmtDate(i.issueDate)),
                    KeyValue('Due', fmtDate(i.dueDate)),
                    KeyValue('Paid so far', fmtUsdt(i.paidAmount)),
                    KeyValue('Review', titleCase(i.reviewStatus)),
                    if (i.description != null && i.description!.isNotEmpty) KeyValue('Description', i.description),
                    if (i.invoiceHash != null) KeyValue('Invoice hash', i.invoiceHash, copy: true, mono: true),
                    if (i.paymentTxHash != null) KeyValue('Payment tx', null, child: TxLink(i.paymentTxHash!, url: i.paymentExplorerUrl)),
                    if (i.financingStatus != null) KeyValue('Financing', null, child: StatusChip(i.financingStatus!)),
                  ]),
                ),
                const SizedBox(height: 12),
                _actions(i),
                if (!i.isDraft) ...[
                  const SectionTitle('Payment'),
                  AsyncView<PaymentStatus>(
                    value: status!,
                    onRetry: () => ref.invalidate(invoiceStatusProvider(i.id)),
                    builder: (s) => AppCard(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        InfoBanner(
                          s.status == 'PAID'
                              ? 'Paid in full — verified on-chain by the BillFlow backend.'
                              : s.payments.isEmpty
                                  ? 'No verified payment yet. A payment is only counted after the backend verifies it on-chain; a wallet submission alone is not enough.'
                                  : 'Partially paid: ${fmtUsdt(s.remainingAmount)} remaining.',
                          tone: s.status == 'PAID' ? BannerTone.success : BannerTone.info,
                          icon: s.status == 'PAID' ? Icons.verified : Icons.hourglass_empty,
                        ),
                        const SizedBox(height: 8),
                        for (final p in s.payments)
                          Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(fmtUsdt(p.amount), style: const TextStyle(fontWeight: FontWeight.w700)),
                              Text('Payer ${shortAddr(p.payerWallet)} · ${fmtDateTime(p.confirmedAt)}', style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12)),
                              TxLink(p.txHash, url: p.explorerUrl),
                            ])),
                            StatusChip(p.status ?? 'CONFIRMED', label: (p.status ?? 'CONFIRMED') == 'CONFIRMED' ? 'Verified' : null),
                          ])),
                      ]),
                    ),
                  ),
                ],
                const SectionTitle('Documents'),
                AsyncView<List<InvoiceDoc>>(
                  value: docs,
                  onRetry: () => ref.invalidate(invoiceDocsProvider(i.id)),
                  isEmpty: (d) => d.isEmpty,
                  empty: const AppCard(child: Text('No PDF attached yet. Financing requires an attached invoice PDF.')),
                  builder: (list) => Column(children: [
                    for (final d in list)
                      AppCard(
                        child: Row(children: [
                          const Icon(Icons.picture_as_pdf_outlined),
                          const SizedBox(width: 10),
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('PDF · ${(d.sizeBytes / 1024).toStringAsFixed(1)} KB · ${fmtDate(d.createdAt)}'),
                            Text(shortHash(d.documentHash), style: TextStyle(color: Theme.of(context).hintColor, fontFamily: 'monospace', fontSize: 12)),
                          ])),
                          TextButton(
                            onPressed: () async {
                              try {
                                final url = await ref.read(apiProvider).invoiceDocUrl(i.id, d.id);
                                if (context.mounted) await openUrl(context, url);
                              } catch (e) {
                                if (context.mounted) toast(context, errorText(e), error: true);
                              }
                            },
                            child: const Text('Open'),
                          ),
                        ]),
                      ),
                  ]),
                ),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(onPressed: _busy ? null : () => _uploadPdf(i), icon: const Icon(Icons.upload_file), label: const Text('Upload PDF')),
                  OutlinedButton.icon(onPressed: _busy ? null : () => _generateAndUploadPdf(i), icon: const Icon(Icons.picture_as_pdf_outlined), label: const Text('Generate PDF')),
                ]),
                if (!i.isDraft) _aiPanel(i),
              ]),
            ),
          ),
        );
      },
    );
  }

  Widget _actions(Invoice i) {
    final api = ref.read(apiProvider);
    final canPay = i.status == 'PENDING' || i.status == 'PARTIALLY_PAID' || i.status == 'OVERDUE';
    return Wrap(spacing: 8, runSpacing: 8, children: [
      if (i.isDraft) ...[
        FilledButton.icon(onPressed: _busy ? null : () => _run(() async { await api.issueInvoice(i.id); _refresh(); }, ok: 'Invoice issued'), icon: const Icon(Icons.send), label: const Text('Issue invoice')),
        OutlinedButton.icon(onPressed: () => context.push('/merchant/invoices/${i.id}/edit'), icon: const Icon(Icons.edit_outlined), label: const Text('Edit')),
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () async {
                  if (!await confirm(context, 'Delete draft?', 'This cannot be undone.', action: 'Delete', destructive: true)) return;
                  await _run(() async {
                    await api.deleteInvoice(i.id);
                    if (mounted) context.go('/merchant/invoices');
                  });
                },
          icon: const Icon(Icons.delete_outline),
          label: const Text('Delete'),
        ),
      ],
      if (canPay) FilledButton.icon(onPressed: _busy ? null : () => _paymentLink(i), icon: const Icon(Icons.link), label: Text(_link == null ? 'Payment link' : 'New payment link')),
      if (i.financingBlocker == null) OutlinedButton.icon(onPressed: () => context.push('/merchant/financing/new?invoice=${i.id}'), icon: const Icon(Icons.account_balance_outlined), label: const Text('Request financing')),
      if (i.financingOfferId != null) OutlinedButton.icon(onPressed: () => context.push('/merchant/financing/${i.financingOfferId}'), icon: const Icon(Icons.account_balance_outlined), label: const Text('View financing')),
      if (!i.isDraft && i.status != 'PAID' && i.status != 'CANCELLED' && i.paidBase == BigInt.zero && !i.hasActiveFinancing)
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () async {
                  if (!await confirm(context, 'Cancel invoice?', 'Any payment link stops working.', action: 'Cancel invoice', destructive: true)) return;
                  await _run(() async { await api.cancelInvoice(i.id); _refresh(); }, ok: 'Invoice cancelled');
                },
          icon: const Icon(Icons.cancel_outlined),
          label: const Text('Cancel invoice'),
        ),
      if (_link != null) _linkCard(),
    ]);
  }

  Future<void> _paymentLink(Invoice i) => _run(() async {
        final l = await ref.read(apiProvider).createPaymentLink(i.id);
        setState(() => _link = l);
      });

  Widget _linkCard() => SizedBox(
        width: double.infinity,
        child: AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Payment link', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            SelectableText(_link!.url),
            Text('Expires ${fmtDateTime(_link!.expiresAt)}. Creating a new link revokes this one.', style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              FilledButton.icon(onPressed: () => copyText(context, _link!.url, 'Link copied'), icon: const Icon(Icons.copy), label: const Text('Copy')),
              OutlinedButton.icon(onPressed: () => Share.share('Pay invoice via BillFlow: ${_link!.url}'), icon: const Icon(Icons.share), label: const Text('Share')),
            ]),
          ]),
        ),
      );

  Widget _aiPanel(Invoice i) {
    final api = ref.read(apiProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionTitle('AI assistant (Claude)'),
      AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Suggestions only. The AI never approves financing, authorises payments or changes an invoice.'),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            BusyButton(label: 'Summarise', outlined: true, icon: Icons.auto_awesome, busy: _aiBusy == 'sum', onPressed: () => _ai('sum', () async { final n = await api.aiSummary(i.id); setState(() { _note = n; _validation = null; }); })),
            BusyButton(label: 'Validate', outlined: true, icon: Icons.fact_check_outlined, busy: _aiBusy == 'val', onPressed: () => _ai('val', () async { final n = await api.aiValidate(i.id); setState(() { _validation = n; _note = null; }); })),
            DropdownButton<String>(value: _tone, items: const [for (final t in ['friendly', 'neutral', 'firm']) DropdownMenuItem(value: t, child: Text(t))], onChanged: (t) => setState(() => _tone = t ?? 'neutral')),
            BusyButton(label: 'Draft reminder', outlined: true, icon: Icons.mail_outline, busy: _aiBusy == 'rem', onPressed: () => _ai('rem', () async { final n = await api.aiReminder(i.id, _tone); setState(() { _note = n; _validation = null; }); })),
          ]),
          if (_note != null) ...[
            const Divider(height: 24),
            Text(_note!.title, style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            SelectableText(_note!.body),
            for (final x in _note!.items) Padding(padding: const EdgeInsets.only(top: 4), child: Text('• $x')),
            const SizedBox(height: 6),
            Row(children: [TextButton.icon(onPressed: () => copyText(context, '${_note!.title}\n\n${_note!.body}'), icon: const Icon(Icons.copy, size: 16), label: const Text('Copy'))]),
            if (_note!.notice.isNotEmpty) Text(_note!.notice, style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12)),
          ],
          if (_validation != null) ...[
            const Divider(height: 24),
            Text('Confidence ${(_validation!.confidence * 100).toStringAsFixed(0)}%${_validation!.aiUsed ? '' : ' (rule checks only; AI unavailable)'}', style: const TextStyle(fontWeight: FontWeight.w800)),
            if (_validation!.issues.isEmpty && _validation!.duplicates.isEmpty && _validation!.aiWarnings.isEmpty) const Padding(padding: EdgeInsets.only(top: 6), child: Text('No issues found.')),
            for (final x in [..._validation!.issues, ..._validation!.duplicates, ..._validation!.aiWarnings]) Padding(padding: const EdgeInsets.only(top: 6), child: InfoBanner(x, tone: BannerTone.warn)),
          ],
        ]),
      ),
    ]);
  }
}
