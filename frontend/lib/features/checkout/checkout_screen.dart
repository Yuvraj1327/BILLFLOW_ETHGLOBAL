import '../../core/widgets/brand_logo.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/config/app_config.dart';
import '../../core/errors/app_exception.dart';
import '../../core/services/wallet/wallet_service.dart';
import '../../core/utils/abi.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/widgets.dart';
import '../../shared/models/models.dart';
import '../wallet/tx_tracker.dart';
import '../wallet/wallet_actions.dart';

final publicInvoiceProvider = FutureProvider.autoDispose.family<PublicInvoice, String>((ref, token) => ref.watch(apiProvider).publicInvoice(token));

/// PUBLIC checkout (/pay/:token): no login, no merchant dashboard. The customer pays with their own wallet.
/// SUCCESS is shown only after the BACKEND reports the payment as confirmed. A wallet response never counts as success.
class CheckoutScreen extends ConsumerWidget {
  const CheckoutScreen({super.key, required this.token});
  final String token;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inv = ref.watch(publicInvoiceProvider(token));
    return Scaffold(
      appBar: AppBar(title: const BrandTitle('NEXA BILLFLOW checkout'), automaticallyImplyLeading: false),
      body: SingleChildScrollView(
        child: ResponsiveBody(
          maxWidth: 620,
          child: inv.when(
            loading: () => const Padding(padding: EdgeInsets.all(60), child: Center(child: CircularProgressIndicator())),
            error: (e, _) => ErrorState(e is AppException && (e.status == 404 || e.status == 410) ? AppException(e.code, 'This payment link is invalid or has expired. Ask the merchant for a new link.', status: e.status) : e,
                onRetry: () => ref.invalidate(publicInvoiceProvider(token))),
            data: (i) => _Body(token: token, inv: i),
          ),
        ),
      ),
    );
  }
}

enum _Phase { idle, working, pending, confirmed, failed }

class _Body extends ConsumerStatefulWidget {
  const _Body({required this.token, required this.inv});
  final String token;
  final PublicInvoice inv;
  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> {
  _Phase _phase = _Phase.idle;
  String _step = '';
  String? _error, _tx;
  BigInt? _balance;
  bool _balanceLoading = false;
  PaymentRecord? _confirmed;
  PaymentStatus? _status;
  bool _disposed = false;
  bool _polling = false;

  PublicInvoice get inv => widget.inv;
  bool _same(String a, String b) => a.toLowerCase() == b.toLowerCase();

  @override
  void initState() {
    super.initState();
    _resume();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// If a payment was already submitted for this link (e.g. page refreshed), track it instead of letting the user pay twice.
  Future<void> _resume() async {
    final h = await PendingTx.load(widget.token);
    if (h != null && !_disposed) {
      setState(() {
        _tx = h;
        _phase = _Phase.pending;
        _step = 'Checking your earlier payment';
      });
      unawaited(_track(h));
    }
  }

  Future<void> _loadBalance() async {
    final w = ref.read(walletProvider);
    if (!w.connected || w.chainId != inv.chainId) return;
    setState(() => _balanceLoading = true);
    try {
      final b = await ref.read(chainReaderProvider).erc20Balance(inv.usdt, w.address!);
      if (mounted) setState(() => _balance = b);
    } catch (_) {
      if (mounted) setState(() => _balance = null);
    }
    if (mounted) setState(() => _balanceLoading = false);
  }

  /// Waits for the BACKEND to report this tx hash as a confirmed payment.
  Future<void> _track(String hash) async {
    if (_polling) return;
    _polling = true;
    final api = ref.read(apiProvider);
    final chain = ref.read(chainReaderProvider);
    final end = DateTime.now().add(const Duration(minutes: 6));
    try {
      while (!_disposed && DateTime.now().isBefore(end)) {
        // 1) the tx itself reverted → failed, safe to retry
        final ok = await chain.receiptStatus(hash).catchError((_) => null);
        if (ok == false) {
          await PendingTx.clear(widget.token);
          if (!_disposed) setState(() { _phase = _Phase.failed; _error = 'The transaction failed on-chain. You were not charged for the invoice (only network fees). You can try again.'; });
          return;
        }
        // 2) if signed in, ask the verifier directly (applies the event immediately)
        if (ref.read(authProvider).valueOrNull != null) {
          try { await api.verifyPayment(hash); } catch (_) {}
        }
        // 3) the public status is the source of truth
        try {
          final s = await api.publicStatus(widget.token);
          final m = s.payments.where((p) => _same(p.txHash, hash) && (p.status ?? 'CONFIRMED') == 'CONFIRMED');
          if (!_disposed) setState(() => _status = s);
          if (m.isNotEmpty) {
            await PendingTx.clear(widget.token);
            if (!_disposed) setState(() { _confirmed = m.first; _phase = _Phase.confirmed; _error = null; });
            ref.invalidate(publicInvoiceProvider(widget.token));
            return;
          }
        } catch (_) {}
        if (!_disposed) setState(() { _phase = _Phase.pending; _step = ok == null ? 'Waiting for the network to include your transaction' : 'Mined. Waiting for NEXA BILLFLOW to verify it on-chain'; });
        await Future<void>.delayed(const Duration(seconds: 5));
      }
      if (!_disposed) setState(() { _phase = _Phase.pending; _step = 'Still waiting for verification. You can safely close this page; your payment will show as paid once verified.'; });
    } finally {
      _polling = false;
    }
  }

  Future<void> _pay() async {
    if (_phase == _Phase.working || _phase == _Phase.pending) return; // duplicate-submit guard
    setState(() { _phase = _Phase.working; _error = null; _step = 'Preparing'; });
    String? sent;
    try {
      if (await PendingTx.load(widget.token) != null) throw AppException('duplicate', 'A payment for this link is already in progress.');
      final api = ref.read(apiProvider);
      final chain = ref.read(chainReaderProvider);

      final payer = await ensureWallet(ref, chainId: inv.chainId, explorer: AppConfig.explorerUrl);
      // Re-read status right before paying so a payment completed elsewhere cannot be duplicated.
      final fresh = await api.publicStatus(widget.token);
      if (!fresh.payable) throw AppException('not_payable', fresh.payableReason ?? 'This invoice can no longer be paid.');
      final remainingBase = toBase(fresh.remainingAmount, inv.decimals);
      if (remainingBase == null || remainingBase <= BigInt.zero) throw AppException('nothing_due', 'Nothing is due on this invoice.');

      setState(() => _step = 'Checking your USDT balance');
      final bal = await chain.erc20Balance(inv.usdt, payer);
      setState(() => _balance = bal);
      if (bal < remainingBase) throw AppException('insufficient_balance', 'Insufficient USDT. You have ${fromBase(bal, inv.decimals)} USDT but ${fresh.remainingAmount} USDT is due.');

      setState(() => _step = 'Checking allowance');
      var allowance = await chain.erc20Allowance(inv.usdt, payer, inv.paymentsContract);
      if (allowance < remainingBase) {
        setState(() => _step = 'Step 1 of 2: approve ${fresh.remainingAmount} USDT in your wallet');
        final ah = await walletSend(ref, to: inv.usdt, data: encodeApprove(inv.paymentsContract, remainingBase), chainId: inv.chainId, explorer: AppConfig.explorerUrl);
        setState(() => _step = 'Waiting for the approval to be mined');
        if (!await chain.waitForReceipt(ah)) throw AppException('approve_failed', 'The approval transaction failed on-chain. No payment was made.');
        allowance = await chain.erc20Allowance(inv.usdt, payer, inv.paymentsContract);
        if (allowance < remainingBase) throw AppException('allowance_low', 'The approval did not register yet. Please try again in a moment.');
      }

      // A FRESH signed quote is requested only now, so it cannot expire while the user was approving.
      setState(() => _step = 'Requesting a signed payment quote');
      final intent = await api.paymentIntent(widget.token, payer);
      if (intent.chainId != inv.chainId || !_same(intent.paymentsContract, inv.paymentsContract) || !_same(intent.usdt, inv.usdt)) {
        throw AppException('config_mismatch', 'The payment quote does not match the invoice configuration. Payment cancelled for your safety.');
      }
      if (allowance < intent.approveBase) throw AppException('allowance_low', 'Your approved amount is lower than the quote. Please try again.');
      if (intent.expiresAt != null && intent.expiresAt!.isBefore(DateTime.now().add(const Duration(seconds: 20)))) {
        throw AppException('quote_expired', 'The quote expired. Please press Pay again.');
      }

      setState(() => _step = 'Step 2 of 2: confirm the payment in your wallet');
      sent = await walletSend(ref, to: intent.paymentsContract, data: encodePayInvoice(intent.quote, intent.signature), chainId: inv.chainId, explorer: AppConfig.explorerUrl);
      await PendingTx.save(widget.token, sent);
      setState(() { _tx = sent; _phase = _Phase.pending; _step = 'Submitted. Waiting for confirmation'; });
      unawaited(_track(sent));
    } on WalletException catch (e) {
      setState(() { _phase = _Phase.failed; _error = e.userRejected ? 'You rejected the request in your wallet. No payment was made.' : e.message; });
    } catch (e) {
      setState(() { _phase = sent != null ? _Phase.pending : _Phase.failed; _error = errorText(e); });
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<WalletState>(walletProvider, (_, n) {
      if (n.connected && n.chainId == inv.chainId) _loadBalance();
    });
    final w = ref.watch(walletProvider);
    final svc = ref.watch(walletServiceProvider);
    final paid = _phase == _Phase.confirmed || inv.status == 'PAID';
    final remaining = _status?.remainingAmount ?? inv.remainingAmount;
    final remainingBase = toBase(remaining, inv.decimals);
    final insufficient = _balance != null && remainingBase != null && _balance! < remainingBase;
    final wrongNet = w.connected && w.chainId != inv.chainId;
    final busy = _phase == _Phase.working || _phase == _Phase.pending;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(inv.merchantName, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Theme.of(context).hintColor)),
          const SizedBox(height: 4),
          Row(children: [Expanded(child: Text('Invoice ${inv.number}', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800))), StatusChip(paid ? 'PAID' : inv.status)]),
          const SizedBox(height: 8),
          Text(fmtUsdt(remaining), style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.primary)),
          Text('amount due${remaining != inv.amount ? ' (invoice total ${fmtUsdt(inv.amount)})' : ''}', style: TextStyle(color: Theme.of(context).hintColor)),
          const SizedBox(height: 8),
          if (inv.description != null && inv.description!.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(inv.description!)),
          KeyValue('Due date', fmtDate(inv.dueDate)),
          KeyValue('Network', '${AppConfig.chainName} (chain ${inv.chainId})'),
        ]),
      ),
      const SizedBox(height: 12),
      if (_phase == _Phase.confirmed) _success(context) else if (paid) const InfoBanner('This invoice has been paid. Thank you!', tone: BannerTone.success, icon: Icons.verified)
      else if (!inv.payable && _status?.payable != true && _phase != _Phase.pending) InfoBanner(inv.payableReason ?? 'This invoice cannot be paid right now.', tone: BannerTone.warn)
      else ...[
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Pay with your wallet', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            if (!svc.isAvailable)
              InfoBanner('${svc.unavailableReason}\nOpen this link in a desktop browser with a wallet extension (such as MetaMask), or in your wallet app’s built-in browser.', tone: BannerTone.warn)
            else if (!w.connected) ...[
              const Text('Connect your wallet to continue. NEXA BILLFLOW never sees your private key.'),
              const SizedBox(height: 10),
              BusyButton(label: 'Connect wallet', icon: Icons.account_balance_wallet_outlined, busy: w.busy, onPressed: () => ref.read(walletProvider.notifier).connect()),
            ] else ...[
              KeyValue('Your wallet', w.address, copy: true, mono: true),
              if (wrongNet) ...[
                const InfoBanner('Your wallet is on the wrong network. Switch to Whitechain Sepolia to pay.', tone: BannerTone.warn),
                const SizedBox(height: 8),
                BusyButton(label: 'Switch to ${AppConfig.chainName}', busy: w.busy, onPressed: () => ref.read(walletProvider.notifier).switchNetwork(inv.chainId, AppConfig.explorerUrl)),
              ] else ...[
                KeyValue('USDT balance', _balanceLoading ? 'Loading…' : (_balance == null ? '—' : fmtUsdt(fromBase(_balance!, inv.decimals)))),
                if (_balance == null && !_balanceLoading) TextButton(onPressed: _loadBalance, child: const Text('Check balance')),
                if (insufficient) InfoBanner('Insufficient USDT: you need ${fmtUsdt(remaining)}.', tone: BannerTone.error),
                const SizedBox(height: 10),
                BusyButton(label: busy ? (_step.isEmpty ? 'Working…' : _step) : 'Pay ${fmtUsdt(remaining)}', icon: Icons.lock_outline, busy: _phase == _Phase.working, onPressed: (busy || insufficient) ? null : _pay),
                const SizedBox(height: 6),
                Text('You will confirm up to two wallet prompts: an USDT allowance for this invoice, then the payment.', style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12)),
              ],
            ],
          ]),
        ),
      ],
      if (_phase == _Phase.pending) ...[
        const SizedBox(height: 12),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)), const SizedBox(width: 10), const Expanded(child: Text('Payment pending verification', style: TextStyle(fontWeight: FontWeight.w800)))]),
            const SizedBox(height: 6),
            Text(_step),
            if (_tx != null) KeyValue('Transaction', null, child: TxLink(_tx!)),
            const SizedBox(height: 4),
            Text('This is not marked as paid until NEXA BILLFLOW verifies it on-chain. Do not pay again.', style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12)),
          ]),
        ),
      ],
      if (_error != null) ...[
        const SizedBox(height: 12),
        InfoBanner(_error!, tone: _phase == _Phase.pending ? BannerTone.warn : BannerTone.error),
      ],
      const SizedBox(height: 16),
      Center(child: Text('Testnet · Payments are verified on-chain by the NEXA BILLFLOW backend', style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12))),
    ]);
  }

  Widget _success(BuildContext context) {
    final p = _confirmed!;
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const InfoBanner('Payment confirmed — verified on-chain by NEXA BILLFLOW.', tone: BannerTone.success, icon: Icons.verified),
        const SizedBox(height: 8),
        KeyValue('Amount', fmtUsdt(p.amount)),
        KeyValue('Confirmed', fmtDateTime(p.confirmedAt)),
        KeyValue('Transaction', null, child: TxLink(p.txHash, url: p.explorerUrl)),
        const SizedBox(height: 8),
        FilledButton.icon(onPressed: () => context.push('/receipt/${widget.token}/${p.txHash}'), icon: const Icon(Icons.receipt_long), label: const Text('View & download receipt')),
      ]),
    );
  }
}
