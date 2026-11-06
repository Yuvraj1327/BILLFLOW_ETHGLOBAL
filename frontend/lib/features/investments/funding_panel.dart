import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/errors/app_exception.dart';
import '../../core/services/wallet/wallet_service.dart';
import '../../core/utils/abi.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/widgets.dart';
import '../../shared/models/models.dart';
import '../wallet/tx_tracker.dart';
import '../wallet/wallet_actions.dart';

/// Investor funding: approve USDT → fund(offerId) signed in the investor's wallet → backend verifies the tx.
/// The offer only becomes FUNDED when the BACKEND verifies the on-chain event. Nothing here marks it funded.
class FundingPanel extends ConsumerStatefulWidget {
  const FundingPanel({super.key, required this.offer, required this.onDone});
  final Offer offer;
  final VoidCallback onDone;
  @override
  ConsumerState<FundingPanel> createState() => _S();
}

class _S extends ConsumerState<FundingPanel> {
  bool _busy = false, _ack = false;
  String _step = '';
  String? _error, _tx;
  TxVerification? _result;

  Future<void> _fund(ChainConfig cfg) async {
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      final o = widget.offer;
      final profile = ref.read(authProvider).valueOrNull;
      if (cfg.usdt == null || cfg.financing == null || !cfg.configured) throw AppException('not_configured', 'The financing contract is not configured on the backend yet.');
      final onchainId = BigInt.tryParse(o.onchainId ?? '');
      if (onchainId == null) throw AppException('not_listed', 'This offer is not listed on-chain yet.');

      setState(() => _step = 'Connecting wallet');
      final addr = await ensureWallet(ref, chainId: cfg.chainId, explorer: cfg.explorerUrl);
      if (profile?.walletAddress == null || profile!.walletAddress!.toLowerCase() != addr.toLowerCase()) {
        throw AppException('wallet_not_linked', 'Link this wallet to your account first (Profile → Link wallet). Otherwise NEXA BILLFLOW cannot attribute the investment to you.');
      }

      final chain = ref.read(chainReaderProvider);
      setState(() => _step = 'Checking USDT balance');
      final bal = await chain.erc20Balance(cfg.usdt!, addr);
      if (bal < o.advanceBase) {
        throw AppException('insufficient_balance', 'Insufficient USDT: you have ${fromBase(bal, o.decimals)}, funding needs ${o.advance}.');
      }

      setState(() => _step = 'Checking allowance');
      final allowance = await chain.erc20Allowance(cfg.usdt!, addr, cfg.financing!);
      if (allowance < o.advanceBase) {
        setState(() => _step = 'Approve ${o.advance} USDT in your wallet');
        final ah = await walletSend(ref, to: cfg.usdt!, data: encodeApprove(cfg.financing!, o.advanceBase), chainId: cfg.chainId, explorer: cfg.explorerUrl);
        setState(() => _step = 'Waiting for the approval to be mined');
        if (!await chain.waitForReceipt(ah)) throw AppException('approve_failed', 'The approval transaction failed on-chain. Nothing was funded.');
      }

      setState(() => _step = 'Confirm the funding transaction in your wallet');
      final hash = await walletSend(ref, to: cfg.financing!, data: encodeFund(onchainId), chainId: cfg.chainId, explorer: cfg.explorerUrl);
      setState(() {
        _tx = hash;
        _step = 'Submitted. Waiting for NEXA BILLFLOW to verify it on-chain';
      });
      final r = await pollVerification(() => ref.read(apiProvider).verifyFinancingTx(hash), onUpdate: (v) {
        if (mounted) setState(() => _result = v);
      });
      setState(() => _result = r);
      if (r.verified) widget.onDone();
    } on WalletException catch (e) {
      _error = e.userRejected ? 'You rejected the request in your wallet. Nothing was sent.' : e.message;
    } catch (e) {
      _error = errorText(e);
    }
    if (mounted) setState(() {
      _busy = false;
      _step = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.offer;
    final cfg = ref.watch(chainConfigProvider);
    final wallet = ref.watch(walletProvider);
    final deadlinePassed = o.fundingDeadline != null && o.fundingDeadline!.isBefore(DateTime.now());
    final can = o.status == 'LISTED' && o.onchainId != null && !deadlinePassed;

    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Fund this offer', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        if (!can)
          InfoBanner(deadlinePassed ? 'The funding deadline has passed.' : 'This offer is not open for funding (status: ${o.displayStatus}).', tone: BannerTone.warn)
        else ...[
          KeyValue('You pay', fmtUsdt(o.advance)),
          KeyValue('Face value', fmtUsdt(o.faceValue)),
          Text('If the debtor repays the face value at maturity, funders receive their share of it. This is not guaranteed: the debtor may pay late or not at all, and you can lose part or all of your funds.', style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12)),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _ack,
            onChanged: _busy ? null : (v) => setState(() => _ack = v ?? false),
            title: const Text('I understand the risks above and in the disclosure.'),
            controlAffinity: ListTileControlAffinity.leading,
          ),
          if (!wallet.connected) const Text('You will be asked to connect your wallet.'),
          const SizedBox(height: 4),
          cfg.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => ErrorState(e, onRetry: () => ref.invalidate(chainConfigProvider)),
            data: (c) => BusyButton(label: _busy ? (_step.isEmpty ? 'Working…' : _step) : 'Approve & fund ${fmtUsdt(o.advance)}', busy: _busy, onPressed: _ack ? () => _fund(c) : null),
          ),
        ],
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: InfoBanner(_error!, tone: BannerTone.error)),
        if (_tx != null) Padding(padding: const EdgeInsets.only(top: 10), child: Row(children: [const Text('Tx '), TxLink(_tx!)])),
        if (_result != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: InfoBanner(
              _result!.verified
                  ? 'Verified on-chain. Your investment is recorded.'
                  : _result!.terminalFailure
                      ? 'The transaction ${_result!.stage}. ${_result!.detail}'
                      : 'Waiting: ${_result!.stage} (${_result!.confirmations}/${_result!.required} confirmations). ${_result!.detail}',
              tone: _result!.verified ? BannerTone.success : (_result!.terminalFailure ? BannerTone.error : BannerTone.info),
            ),
          ),
      ]),
    );
  }
}
