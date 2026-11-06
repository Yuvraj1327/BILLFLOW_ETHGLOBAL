import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide shortHash;
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/errors/app_exception.dart';
import '../../core/services/wallet/wallet_service.dart';
import '../../core/utils/abi.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/widgets.dart';
import '../../shared/models/models.dart';
import '../../shared/widgets/paged_list.dart';
import '../financing/financing_screens.dart';
import '../wallet/tx_tracker.dart';
import '../wallet/wallet_actions.dart';

// NOTE: every call below is authorised by the BACKEND (role=admin from the database). Hiding these screens in the UI is cosmetic only.

final adminHealthProvider = FutureProvider.autoDispose<(Json, Json)>((ref) async {
  final api = ref.watch(apiProvider);
  final idx = await api.adminIndexer();
  final h = await api.chainHealth();
  return (idx, h);
});

class AdminDashboard extends ConsumerWidget {
  const AdminDashboard({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final h = ref.watch(adminHealthProvider);
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(adminHealthProvider),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ResponsiveBody(
          child: AsyncView<(Json, Json)>(
            value: h,
            onRetry: () => ref.invalidate(adminHealthProvider),
            builder: (d) {
              final idx = d.$1, health = d.$2;
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                StatGrid([
                  StatTile(label: 'Indexer cursor block', value: '${idx['cursor_block'] ?? '—'}', icon: Icons.sync),
                  StatTile(label: 'Unprocessed events', value: '${idx['unprocessed_events'] ?? 0}', icon: Icons.pending_actions, color: ((idx['unprocessed_events'] ?? 0) as num) > 0 ? Colors.orange : Colors.green),
                  StatTile(label: 'Reorged events', value: '${idx['reorged_events'] ?? 0}', icon: Icons.call_split, color: ((idx['reorged_events'] ?? 0) as num) > 0 ? Colors.red : null),
                  StatTile(label: 'Indexer in API process', value: idx['enabled_in_api_process'] == true ? 'Yes' : 'No', icon: Icons.memory),
                ]),
                const SectionTitle('Chain health'),
                AppCard(child: Column(children: [for (final e in health.entries) KeyValue(titleCase(e.key), '${e.value}')])),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      final r = await ref.read(apiProvider).adminRetryIndexer();
                      ref.invalidate(adminHealthProvider);
                      if (context.mounted) toast(context, 'Retried parked events: applied ${r['applied']}');
                    } catch (e) {
                      if (context.mounted) toast(context, errorText(e), error: true);
                    }
                  },
                  icon: const Icon(Icons.replay),
                  label: const Text('Retry unprocessed events'),
                ),
                const SectionTitle('Shortcuts'),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  ActionChip(avatar: const Icon(Icons.swap_horiz, size: 18), label: const Text('Transactions'), onPressed: () => context.go('/transactions')),
                  ActionChip(avatar: const Icon(Icons.monitor_heart_outlined, size: 18), label: const Text('Events & audit logs'), onPressed: () => context.go('/admin/monitoring')),
                ]),
              ]);
            },
          ),
        ),
      ),
    );
  }
}

class AdminUsers extends ConsumerStatefulWidget {
  const AdminUsers({super.key});
  @override
  ConsumerState<AdminUsers> createState() => _UsersState();
}

class _UsersState extends ConsumerState<AdminUsers> {
  String? _role;
  String _q = '';
  int _token = 0;

  Future<void> _changeRole(Json u) async {
    var role = u.str('role');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text('Role for ${u.str('email')}'),
          content: DropdownButton<String>(value: role, isExpanded: true, items: [for (final r in ['customer', 'merchant', 'investor', 'admin']) DropdownMenuItem(value: r, child: Text(r))], onChanged: (x) => setS(() => role = x ?? role)),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Change role'))],
        ),
      ),
    );
    if (ok != true || role == u.str('role')) return;
    try {
      await ref.read(apiProvider).adminSetRole(u.str('id'), role);
      setState(() => _token++);
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    }
  }

  Future<void> _verifyInvestor(Json u, String decision) async {
    try {
      await ref.read(apiProvider).adminInvestorVerification(u.str('id'), decision);
      setState(() => _token++);
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) => ResponsiveBody(
        padding: EdgeInsets.zero,
        child: PagedList<Json>(
          reloadToken: _token,
          load: (p) async => Paged.from(await ref.read(apiProvider).adminList('users', page: p, query: {'role': _role, 'q': _q.isEmpty ? null : _q}), (j) => j),
          header: Column(children: [
            TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search by email or name'), onSubmitted: (s) => setState(() { _q = s.trim(); _token++; })),
            const SizedBox(height: 8),
            SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
              Padding(padding: const EdgeInsets.only(right: 6), child: ChoiceChip(label: const Text('All'), selected: _role == null, onSelected: (_) => setState(() { _role = null; _token++; }))),
              for (final r in ['customer', 'merchant', 'investor', 'admin']) Padding(padding: const EdgeInsets.only(right: 6), child: ChoiceChip(label: Text(titleCase(r)), selected: _role == r, onSelected: (_) => setState(() { _role = r; _token++; }))),
            ])),
            const SizedBox(height: 12),
          ]),
          empty: const EmptyState(icon: Icons.people_outline, title: 'No users match'),
          itemBuilder: (c, u) => AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(u.strN('email') ?? u.str('id'), style: const TextStyle(fontWeight: FontWeight.w700))),
                StatusChip(u.str('role'), label: titleCase(u.str('role'))),
              ]),
              if (u.strN('display_name') != null) Text(u.str('display_name')),
              if (u.strN('wallet_address') != null) Text('Wallet ${shortAddr(u.str('wallet_address'))}', style: TextStyle(color: Theme.of(c).hintColor, fontSize: 12)),
              const SizedBox(height: 6),
              Wrap(spacing: 8, children: [
                OutlinedButton(onPressed: () => _changeRole(u), child: const Text('Change role')),
                if (u.str('role') == 'investor') ...[
                  StatusChip(u.str('investor_verification'), label: 'Investor: ${u.str('investor_verification')}'),
                  TextButton(onPressed: () => _verifyInvestor(u, 'verify'), child: const Text('Verify')),
                  TextButton(onPressed: () => _verifyInvestor(u, 'reject'), child: const Text('Reject')),
                ],
              ]),
            ]),
          ),
        ),
      );
}

class AdminBusinesses extends ConsumerStatefulWidget {
  const AdminBusinesses({super.key});
  @override
  ConsumerState<AdminBusinesses> createState() => _BizState();
}

class _BizState extends ConsumerState<AdminBusinesses> {
  String? _status = 'pending';
  int _token = 0;

  Future<void> _review(Business b, String decision) async {
    final notes = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${decision == 'verify' ? 'Verify' : 'Reject'} ${b.legalName}?'),
        content: TextField(controller: notes, maxLength: 1000, maxLines: 3, decoration: const InputDecoration(labelText: 'Notes (kept in the audit log)')),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm'))],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(apiProvider).adminReviewBusiness(b.id, decision, notes: notes.text.trim().isEmpty ? null : notes.text.trim());
      setState(() => _token++);
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) => ResponsiveBody(
        padding: EdgeInsets.zero,
        child: PagedList<Business>(
          reloadToken: _token,
          load: (p) => ref.read(apiProvider).adminBusinesses(page: p, status: _status),
          header: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
              for (final s in ['pending', 'unverified', 'verified', 'rejected']) Padding(padding: const EdgeInsets.only(right: 6), child: ChoiceChip(label: Text(titleCase(s)), selected: _status == s, onSelected: (_) => setState(() { _status = s; _token++; }))),
            ])),
          ),
          empty: const EmptyState(icon: Icons.business_outlined, title: 'No businesses in this state'),
          itemBuilder: (c, b) => AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [Expanded(child: Text(b.legalName, style: const TextStyle(fontWeight: FontWeight.w800))), StatusChip(b.verificationStatus)]),
              KeyValue('Country', b.country),
              KeyValue('Tax ID', b.taxId),
              KeyValue('Payout wallet', b.payoutWallet, copy: true, mono: true),
              Wrap(spacing: 8, children: [
                FilledButton(onPressed: b.isVerified ? null : () => _review(b, 'verify'), child: const Text('Verify')),
                OutlinedButton(onPressed: b.verificationStatus == 'rejected' ? null : () => _review(b, 'reject'), child: const Text('Reject')),
              ]),
            ]),
          ),
        ),
      );
}

class AdminFinancing extends ConsumerStatefulWidget {
  const AdminFinancing({super.key});
  @override
  ConsumerState<AdminFinancing> createState() => _FinState();
}

class _FinState extends ConsumerState<AdminFinancing> {
  String? _status = 'REQUESTED';
  @override
  Widget build(BuildContext context) => ResponsiveBody(
        padding: EdgeInsets.zero,
        child: PagedList<Offer>(
          key: ValueKey(_status),
          load: (p) => ref.read(apiProvider).offers(page: p, status: _status),
          header: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
              for (final s in ['REQUESTED', 'UNDER_REVIEW', 'APPROVED', 'LISTED', 'FUNDED', 'SETTLED', 'REJECTED']) Padding(padding: const EdgeInsets.only(right: 6), child: ChoiceChip(label: Text(titleCase(s)), selected: _status == s, onSelected: (_) => setState(() => _status = s))),
            ])),
          ),
          empty: const EmptyState(icon: Icons.account_balance_outlined, title: 'Nothing in this queue'),
          itemBuilder: (c, o) => OfferCard(o, onTap: () => c.push('/admin/financing/${o.id}')),
        ),
      );
}

/// Admin review of one financing request: documents, off-chain debtor evidence, approve/reject, then the on-chain publish plan.
class AdminOfferReview extends ConsumerStatefulWidget {
  const AdminOfferReview({super.key, required this.id});
  final String id;
  @override
  ConsumerState<AdminOfferReview> createState() => _ReviewState();
}

class _ReviewState extends ConsumerState<AdminOfferReview> {
  final _notes = TextEditingController(), _evidence = TextEditingController(), _by = TextEditingController(), _assign = TextEditingController();
  final _form = GlobalKey<FormState>();
  DateTime _ackAt = DateTime.now();
  bool _busy = false;
  PublishPlan? _plan;
  String _planMsg = '';
  TxVerification? _txResult;

  @override
  void dispose() {
    for (final c in [_notes, _evidence, _by, _assign]) {
      c.dispose();
    }
    super.dispose();
  }

  void _refresh() => ref.invalidate(offerProvider(widget.id));

  Future<void> _decide(Offer o, String decision) async {
    if (decision == 'approve' && !_form.currentState!.validate()) return;
    if (decision == 'reject' && _notes.text.trim().isEmpty) {
      toast(context, 'Add a note explaining the rejection', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(apiProvider).reviewOffer(o.id, {
        'decision': decision,
        if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
        if (decision == 'approve') ...{
          'debtor_ack': {'evidence_ref': _evidence.text.trim(), 'acknowledged_at': _ackAt.toUtc().toIso8601String(), if (_by.text.trim().isNotEmpty) 'acknowledged_by': _by.text.trim()},
          'assignment_notice': {'reference': _assign.text.trim()},
        },
      });
      _refresh();
      if (mounted) toast(context, 'Decision recorded');
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _loadPlan(Offer o) async {
    setState(() => _busy = true);
    try {
      _plan = await ref.read(apiProvider).publishPlan(o.id);
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  /// Sends the next on-chain step from the connected wallet. The wallet must hold the required contract role; otherwise the chain reverts.
  Future<void> _sendStep(OnchainStep s, ChainConfig cfg) async {
    setState(() { _busy = true; _planMsg = ''; _txResult = null; });
    try {
      final String data;
      switch (s.function) {
        case 'registerInvoice':
          data = encodeRegisterInvoice(Map<String, dynamic>.from(s.args['p'] as Map));
        case 'verifyInvoice':
          data = encodeVerifyInvoice(BigInt.parse('${s.args['invoiceId']}'), '${s.args['debtorAckRef']}');
        case 'createOffer':
          data = encodeCreateOffer(BigInt.parse('${s.args['invoiceId']}'), BigInt.parse('${s.args['advance']}'), BigInt.parse('${s.args['fundingDeadline']}'));
        default:
          throw AppException('unknown_step', 'Unknown on-chain step ${s.function}.');
      }
      final hash = await walletSend(ref, to: s.contract, data: data, chainId: cfg.chainId, explorer: cfg.explorerUrl);
      setState(() => _planMsg = 'Submitted $hash. Waiting for backend verification…');
      final r = await pollVerification(() => ref.read(apiProvider).verifyFinancingTx(hash), onUpdate: (x) { if (mounted) setState(() => _txResult = x); });
      setState(() => _txResult = r);
      if (r.verified) {
        _refresh();
        _plan = await ref.read(apiProvider).publishPlan(widget.id);
      }
    } on WalletException catch (e) {
      _planMsg = e.userRejected ? 'You rejected the request in your wallet.' : e.message;
    } catch (e) {
      _planMsg = errorText(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final offer = ref.watch(offerProvider(widget.id));
    return SingleChildScrollView(
      child: ResponsiveBody(
        maxWidth: 820,
        child: AsyncView<Offer>(
          value: offer,
          onRetry: _refresh,
          builder: (o) {
            final docs = ref.watch(_adminDocsProvider(o.invoiceId));
            final canReview = const {'REQUESTED', 'UNDER_REVIEW'}.contains(o.status);
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              OfferCard(o, onTap: () {}),
              const SectionTitle('Invoice documents'),
              AsyncView<List<InvoiceDoc>>(
                value: docs,
                onRetry: () => ref.invalidate(_adminDocsProvider(o.invoiceId)),
                isEmpty: (d) => d.isEmpty,
                empty: const InfoBanner('No PDF attached. Do not approve without a document.', tone: BannerTone.warn),
                builder: (list) => Column(children: [
                  for (final d in list)
                    AppCard(child: Row(children: [
                      const Icon(Icons.picture_as_pdf_outlined),
                      const SizedBox(width: 8),
                      Expanded(child: Text(shortHash(d.documentHash), style: const TextStyle(fontFamily: 'monospace'))),
                      if (d.duplicateWarnings.isNotEmpty) const Icon(Icons.warning_amber, color: Colors.orange),
                      TextButton(onPressed: () async {
                        try {
                          final url = await ref.read(apiProvider).adminDocUrl(o.invoiceId, d.id);
                          if (context.mounted) await openUrl(context, url);
                        } catch (e) {
                          if (context.mounted) toast(context, errorText(e), error: true);
                        }
                      }, child: const Text('Open (60s link)')),
                    ])),
                ]),
              ),
              if (canReview) ...[
                const SectionTitle('Review'),
                Form(
                  key: _form,
                  child: AppCard(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const InfoBanner('Approval records off-chain evidence of the debtor’s acknowledgement and the assignment notice. It is not a legal verification of the invoice.'),
                      const SizedBox(height: 10),
                      TextFormField(controller: _evidence, decoration: const InputDecoration(labelText: 'Debtor acknowledgement evidence reference *'), validator: (x) => (x == null || x.trim().length < 3) ? 'At least 3 characters (required to approve)' : null),
                      const SizedBox(height: 8),
                      TextFormField(controller: _by, decoration: const InputDecoration(labelText: 'Acknowledged by')),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final d = await showDatePicker(context: context, initialDate: _ackAt, firstDate: DateTime(2020), lastDate: DateTime.now());
                          if (d != null) setState(() => _ackAt = d);
                        },
                        icon: const Icon(Icons.event),
                        label: Text('Acknowledged on ${fmtDate(_ackAt)}'),
                      ),
                      const SizedBox(height: 8),
                      TextFormField(controller: _assign, decoration: const InputDecoration(labelText: 'Assignment notice reference *'), validator: (x) => (x == null || x.trim().length < 3) ? 'At least 3 characters (required to approve)' : null),
                      const SizedBox(height: 8),
                      TextFormField(controller: _notes, maxLines: 2, decoration: const InputDecoration(labelText: 'Notes')),
                      const SizedBox(height: 12),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        if (o.status == 'REQUESTED') OutlinedButton(onPressed: _busy ? null : () => _decide(o, 'start_review'), child: const Text('Start review')),
                        FilledButton(onPressed: _busy ? null : () => _decide(o, 'approve'), child: const Text('Approve')),
                        OutlinedButton(onPressed: _busy ? null : () => _decide(o, 'reject'), child: const Text('Reject')),
                      ]),
                    ]),
                  ),
                ),
              ],
              if (const {'APPROVED', 'LISTED'}.contains(o.status)) ...[
                const SectionTitle('On-chain publishing'),
                AppCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('The backend never signs. A wallet holding the required contract role (ISSUER → VERIFIER → OPERATOR) must send each step. Status changes only after the backend verifies the resulting event.'),
                    const SizedBox(height: 8),
                    if (_plan == null) BusyButton(label: 'Load next on-chain step', busy: _busy, onPressed: () => _loadPlan(o)),
                    if (_plan != null) ...[
                      Text(_plan!.message, style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12)),
                      const SizedBox(height: 8),
                      if (_plan!.next == null) const InfoBanner('All steps are done.', tone: BannerTone.success)
                      else ...[
                        KeyValue('Next step', _plan!.next!.function),
                        KeyValue('Required role', _plan!.next!.signer),
                        KeyValue('Contract', _plan!.next!.contract, copy: true, mono: true),
                        if (_plan!.next!.note != null) Text(_plan!.next!.note!, style: const TextStyle(fontSize: 12)),
                        const SizedBox(height: 8),
                        ref.watch(chainConfigProvider).when(
                              loading: () => const LinearProgressIndicator(),
                              error: (e, _) => ErrorState(e),
                              data: (cfg) => BusyButton(label: 'Send ${_plan!.next!.function} from my wallet', busy: _busy, onPressed: () => _sendStep(_plan!.next!, cfg)),
                            ),
                      ],
                      if (_plan!.remaining.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Remaining: ${_plan!.remaining.join(' → ')}')),
                    ],
                    if (_planMsg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: InfoBanner(_planMsg, tone: BannerTone.warn)),
                    if (_txResult != null) Padding(padding: const EdgeInsets.only(top: 8), child: InfoBanner('Backend verification: ${_txResult!.stage}${_txResult!.detail.isEmpty ? '' : ' — ${_txResult!.detail}'}', tone: _txResult!.verified ? BannerTone.success : (_txResult!.terminalFailure ? BannerTone.error : BannerTone.info))),
                  ]),
                ),
              ],
            ]);
          },
        ),
      ),
    );
  }
}

final _adminDocsProvider = FutureProvider.autoDispose.family<List<InvoiceDoc>, String>((ref, invoiceId) => ref.watch(apiProvider).adminInvoiceDocs(invoiceId));

class AdminMonitoring extends ConsumerStatefulWidget {
  const AdminMonitoring({super.key});
  @override
  ConsumerState<AdminMonitoring> createState() => _MonState();
}

class _MonState extends ConsumerState<AdminMonitoring> {
  String _tab = 'events';
  bool _unprocessed = false;
  @override
  Widget build(BuildContext context) => ResponsiveBody(
        padding: EdgeInsets.zero,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(children: [
              SegmentedButton<String>(
                segments: const [ButtonSegment(value: 'events', label: Text('Events')), ButtonSegment(value: 'audit-logs', label: Text('Audit log')), ButtonSegment(value: 'settings', label: Text('Settings'))],
                selected: {_tab},
                onSelectionChanged: (s) => setState(() => _tab = s.first),
              ),
              const SizedBox(width: 12),
              if (_tab == 'events') FilterChip(label: const Text('Unprocessed only'), selected: _unprocessed, onSelected: (s) => setState(() => _unprocessed = s)),
            ]),
          ),
          Expanded(
            child: _tab == 'settings'
                ? const _Settings()
                : PagedList<Json>(
                    key: ValueKey('$_tab$_unprocessed'),
                    load: (p) async => Paged.from(await ref.read(apiProvider).adminList(_tab, page: p, query: {if (_tab == 'events' && _unprocessed) 'unprocessed_only': true}), (j) => j),
                    empty: const EmptyState(icon: Icons.inbox_outlined, title: 'Nothing recorded'),
                    itemBuilder: (c, j) => AppCard(
                      child: _tab == 'events'
                          ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Row(children: [Expanded(child: Text(j.str('event_name'), style: const TextStyle(fontWeight: FontWeight.w800))), StatusChip(j['processed_at'] == null ? 'PENDING' : 'PROCESSED', label: j['reorged_at'] != null ? 'Reorged' : (j['processed_at'] == null ? 'Unprocessed' : 'Processed'))]),
                              Text('Block ${j.str('block_number')} · log ${j.str('log_index')}', style: TextStyle(color: Theme.of(c).hintColor, fontSize: 12)),
                              if (j.strN('tx_hash') != null) TxLink(j.str('tx_hash')),
                              if (j.strN('error') != null) Text(j.str('error'), style: const TextStyle(color: Colors.red, fontSize: 12)),
                            ])
                          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(j.str('action'), style: const TextStyle(fontWeight: FontWeight.w800)),
                              Text('${j.str('entity_type')} ${j.str('entity_id')}', style: TextStyle(color: Theme.of(c).hintColor, fontSize: 12)),
                              Text(fmtDateTime(j.date('created_at')), style: TextStyle(color: Theme.of(c).hintColor, fontSize: 12)),
                            ]),
                    ),
                  ),
          ),
        ]),
      );
}

class _Settings extends ConsumerWidget {
  const _Settings();
  @override
  Widget build(BuildContext context, WidgetRef ref) => FutureBuilder<dynamic>(
        future: ref.read(apiProvider).adminSettings(),
        builder: (c, s) {
          if (s.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (s.hasError) return ErrorState(s.error!);
          final data = s.data;
          final entries = data is Map ? data.entries.toList() : (data is List ? data.map((e) => MapEntry('${(e as Map)['key']}', e['value'])).toList() : <MapEntry<dynamic, dynamic>>[]);
          if (entries.isEmpty) return const EmptyState(icon: Icons.settings_outlined, title: 'No settings');
          return ListView(padding: const EdgeInsets.all(16), children: [
            const InfoBanner('Platform settings are read-only in this build. Change them through PUT /admin/settings/{key}.'),
            const SizedBox(height: 8),
            for (final e in entries) AppCard(child: KeyValue('${e.key}', '${e.value}')),
          ]);
        },
      );
}
