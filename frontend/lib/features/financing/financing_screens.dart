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
import '../investments/funding_panel.dart';

class MerchantFinancingScreen extends ConsumerWidget {
  const MerchantFinancingScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => ResponsiveBody(
        padding: EdgeInsets.zero,
        child: PagedList<Offer>(
          load: (p) => ref.read(apiProvider).offers(page: p),
          header: const Padding(padding: EdgeInsets.only(bottom: 12), child: InfoBanner('Invoice financing advances part of an unpaid invoice from investors. Requests are reviewed by NEXA BILLFLOW; nothing is guaranteed and nothing happens on-chain until approval.')),
          empty: const EmptyState(icon: Icons.account_balance_outlined, title: 'No financing requests', message: 'Open an eligible unpaid invoice and choose “Request financing”.'),
          itemBuilder: (c, o) => OfferCard(o, onTap: () => c.push('/merchant/financing/${o.id}')),
        ),
      );
}

class OfferCard extends StatelessWidget {
  const OfferCard(this.o, {super.key, required this.onTap});
  final Offer o;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => AppCard(
        onTap: onTap,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(o.invoiceNumber, style: const TextStyle(fontWeight: FontWeight.w800))),
            StatusChip(o.status, label: titleCase(o.displayStatus)),
          ]),
          if (o.businessName != null) Row(children: [Text(o.businessName!, style: TextStyle(color: Theme.of(context).hintColor)), if (o.businessVerified) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.verified, size: 14, color: Colors.green))]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: KeyValue('Advance', fmtUsdt(o.advance))),
            Expanded(child: KeyValue('Face value', fmtUsdt(o.faceValue))),
          ]),
          Row(children: [
            Expanded(child: KeyValue('Discount', '${o.discountPercent}%')),
            Expanded(child: KeyValue('Matures', fmtDate(o.maturityDate))),
          ]),
        ]),
      );
}

class FinancingRequestScreen extends ConsumerStatefulWidget {
  const FinancingRequestScreen({super.key, this.invoiceId});
  final String? invoiceId;
  @override
  ConsumerState<FinancingRequestScreen> createState() => _ReqState();
}

class _ReqState extends ConsumerState<FinancingRequestScreen> {
  final _form = GlobalKey<FormState>();
  final _advance = TextEditingController();
  final _hours = TextEditingController(text: '72');
  Invoice? _inv;
  Business? _biz;
  Object? _err;
  bool _loading = true, _busy = false, _ack = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _advance.dispose();
    _hours.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      if (widget.invoiceId == null) throw AppException('no_invoice', 'Open an invoice and choose “Request financing”.');
      final api = ref.read(apiProvider);
      _inv = await api.invoice(widget.invoiceId!);
      _biz = await api.myBusiness();
    } catch (e) {
      _err = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  String? _discount() {
    final i = _inv;
    final a = toBase(_advance.text, i?.decimals ?? 6);
    if (i == null || a == null || i.amountBase == BigInt.zero || a > i.amountBase) return null;
    final bps = ((i.amountBase - a) * BigInt.from(10000)) ~/ i.amountBase;
    return (bps.toInt() / 100).toStringAsFixed(2);
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final o = await ref.read(apiProvider).submitFinancing(_inv!.id, _advance.text.trim(), windowHours: int.tryParse(_hours.text.trim()));
      if (mounted) {
        toast(context, 'Financing request submitted for review');
        context.go('/merchant/financing/${o.id}');
      }
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_err != null) return ErrorState(_err!, onRetry: () => setState(() { _loading = true; _err = null; _load(); }));
    final i = _inv!;
    final blocker = i.financingBlocker ?? ((_biz?.isVerified ?? false) ? null : 'Your business must be verified by an admin before you can request financing.');
    final disc = _discount();
    return SingleChildScrollView(
      child: ResponsiveBody(
        maxWidth: 640,
        child: Form(
          key: _form,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Request financing', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            AppCard(child: Column(children: [KeyValue('Invoice', i.number), KeyValue('Customer', i.customerName), KeyValue('Face value', fmtUsdt(i.amount)), KeyValue('Due', fmtDate(i.dueDate))])),
            const SizedBox(height: 12),
            if (blocker != null) InfoBanner(blocker, tone: BannerTone.warn),
            if (blocker == null) ...[
              TextFormField(
                controller: _advance,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: 'Advance you want to receive (USDT)', helperText: disc == null ? 'Must be less than or equal to the face value' : 'Implied discount: $disc%'),
                validator: (x) {
                  final e = v.positiveDecimal(x);
                  if (e != null) return e;
                  final a = toBase(x!, i.decimals);
                  if (a == null || a > i.amountBase) return 'Cannot exceed the invoice amount';
                  return null;
                },
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              TextFormField(controller: _hours, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Funding window (hours)', helperText: 'How long investors have to fund (1–720)'), validator: (x) {
                final n = int.tryParse(x ?? '');
                return (n == null || n < 1 || n > 720) ? 'Enter 1–720' : null;
              }),
              const SizedBox(height: 12),
              const InfoBanner('A lower advance means a bigger discount for the investor. The platform may reject the request or set limits. Your customer is the debtor and must pay the full invoice at maturity.'),
              CheckboxListTile(contentPadding: EdgeInsets.zero, value: _ack, onChanged: (x) => setState(() => _ack = x ?? false), controlAffinity: ListTileControlAffinity.leading, title: const Text('I confirm this invoice is genuine and not already financed or paid.')),
              BusyButton(label: 'Submit request', busy: _busy, onPressed: _ack ? _submit : null),
            ],
          ]),
        ),
      ),
    );
  }
}

final offerProvider = FutureProvider.autoDispose.family<Offer, String>((ref, id) => ref.watch(apiProvider).offer(id));

/// Role-aware offer view: merchants see status + cancel; investors see disclosures + the funding panel.
class OfferDetailScreen extends ConsumerWidget {
  const OfferDetailScreen({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(authProvider).valueOrNull;
    final offer = ref.watch(offerProvider(id));
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(offerProvider(id)),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ResponsiveBody(
          maxWidth: 820,
          child: AsyncView<Offer>(
            value: offer,
            onRetry: () => ref.invalidate(offerProvider(id)),
            builder: (o) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              AppCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(o.invoiceNumber, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800))),
                    StatusChip(o.status, label: titleCase(o.displayStatus)),
                  ]),
                  if (o.isOverdue) const Padding(padding: EdgeInsets.only(top: 8), child: InfoBanner('This invoice is past maturity and has not been settled.', tone: BannerTone.warn)),
                  const SizedBox(height: 8),
                  KeyValue('Business', o.businessName),
                  KeyValue('Business verified', o.businessVerified ? 'Yes (off-chain review)' : 'No'),
                  KeyValue('Face value', fmtUsdt(o.faceValue)),
                  KeyValue('Advance', fmtUsdt(o.advance)),
                  KeyValue('Discount', '${o.discountPercent}% of face value'),
                  KeyValue('Matures', fmtDate(o.maturityDate)),
                  KeyValue('Funding deadline', fmtDateTime(o.fundingDeadline)),
                  if (o.onchainId != null) KeyValue('On-chain offer', o.onchainId, mono: true),
                  if (o.contract != null) KeyValue('Contract', o.contract, copy: true, mono: true),
                  if (o.reviewNotes != null) KeyValue('Review notes', o.reviewNotes),
                ]),
              ),
              const SizedBox(height: 12),
              InfoBanner(o.disclosure.isEmpty ? 'Invoice financing carries credit risk. The discount is not a guaranteed return.' : o.disclosure, tone: BannerTone.warn, icon: Icons.gpp_maybe_outlined),
              const SizedBox(height: 12),
              _Timeline(o),
              const SizedBox(height: 12),
              if (profile?.isInvestor ?? false) FundingPanel(offer: o, onDone: () => ref.invalidate(offerProvider(id))),
              if ((profile?.isMerchant ?? false) && const {'REQUESTED', 'UNDER_REVIEW', 'APPROVED'}.contains(o.status) && o.registeredAt == null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      if (!await confirm(context, 'Cancel request?', 'The financing request will be withdrawn.', action: 'Cancel request', destructive: true)) return;
                      try {
                        await ref.read(apiProvider).cancelOffer(o.id);
                        ref.invalidate(offerProvider(id));
                      } catch (e) {
                        if (context.mounted) toast(context, errorText(e), error: true);
                      }
                    },
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('Cancel request'),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Verification / funding / settlement progress derived only from backend status values.
class _Timeline extends StatelessWidget {
  const _Timeline(this.o);
  final Offer o;
  @override
  Widget build(BuildContext context) {
    const order = ['REQUESTED', 'UNDER_REVIEW', 'APPROVED', 'LISTED', 'FUNDED', 'SETTLED'];
    final terminal = const {'REJECTED', 'EXPIRED', 'CANCELLED', 'DEFAULTED'}.contains(o.status);
    final idx = order.indexOf(o.status);
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Progress', style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        for (var i = 0; i < order.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Icon(!terminal && idx >= i ? Icons.check_circle : Icons.radio_button_unchecked, size: 18, color: !terminal && idx >= i ? Colors.green : Theme.of(context).hintColor),
              const SizedBox(width: 8),
              Text(switch (order[i]) {
                'REQUESTED' => 'Submitted',
                'UNDER_REVIEW' => 'Under review',
                'APPROVED' => 'Verified by NEXA BILLFLOW',
                'LISTED' => 'Open for funding (on-chain)',
                'FUNDED' => 'Funded (verified on-chain)',
                _ => 'Settled (verified on-chain)',
              }),
            ]),
          ),
        if (terminal) Padding(padding: const EdgeInsets.only(top: 8), child: StatusChip(o.status)),
      ]),
    );
  }
}
