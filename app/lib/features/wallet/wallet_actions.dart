import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme/app_theme.dart';
import '../../core/errors/app_exception.dart';
import '../../core/services/wallet/wallet_service.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/widgets.dart';

/// Connects the wallet and switches to [chainId] if needed. Throws [WalletException] with a user-readable message.
Future<String> ensureWallet(WidgetRef ref, {required int chainId, required String explorer}) async {
  final ctl = ref.read(walletProvider.notifier);
  if (!ref.read(walletServiceProvider).isAvailable) {
    throw WalletException(WalletErrorKind.unavailable, ref.read(walletServiceProvider).unavailableReason);
  }
  if (!ref.read(walletProvider).connected) {
    if (!await ctl.connect()) throw WalletException(WalletErrorKind.failed, ref.read(walletProvider).error ?? 'Wallet connection failed.');
  }
  if (ref.read(walletProvider).chainId != chainId) {
    if (!await ctl.switchNetwork(chainId, explorer)) {
      throw WalletException(WalletErrorKind.wrongNetwork, ref.read(walletProvider).error ?? 'Please switch your wallet to Whitechain Sepolia.');
    }
  }
  return ref.read(walletProvider).address!;
}

/// Asks the USER'S wallet to sign and broadcast. The app never holds a key. Returns the tx hash (NOT a success signal).
Future<String> walletSend(WidgetRef ref, {required String to, required String data, required int chainId, required String explorer}) async {
  final from = await ensureWallet(ref, chainId: chainId, explorer: explorer);
  return ref.read(walletServiceProvider).sendTransaction(from: from, to: to, data: data);
}

/// Proves ownership of the connected wallet (EIP-191 personal_sign) and links it to the signed-in profile.
Future<bool> linkConnectedWallet(BuildContext context, WidgetRef ref) async {
  try {
    final addr = ref.read(walletProvider).address;
    if (addr == null) throw WalletException(WalletErrorKind.failed, 'Connect a wallet first.');
    final api = ref.read(apiProvider);
    final ch = await api.walletChallenge(addr);
    final sig = await ref.read(walletServiceProvider).personalSign(address: addr, message: ch['message'] as String);
    await api.walletVerify(addr, ch['nonce'] as String, sig);
    await ref.read(authProvider.notifier).reload();
    if (context.mounted) toast(context, 'Wallet ${shortAddr(addr)} linked to your account.');
    return true;
  } catch (e) {
    if (context.mounted) toast(context, errorText(e), error: true);
    return false;
  }
}

/// Connect / network / disconnect card used on the profile and funding screens.
class WalletPanel extends ConsumerWidget {
  const WalletPanel({super.key, this.showLink = true});
  final bool showLink;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final w = ref.watch(walletProvider);
    final svc = ref.watch(walletServiceProvider);
    final cfg = ref.watch(chainConfigProvider);
    final profile = ref.watch(authProvider).valueOrNull;
    final target = cfg.valueOrNull;
    final wrongNet = w.connected && target != null && w.chainId != target.chainId;
    final linked = profile?.walletAddress != null && w.address != null && profile!.walletAddress!.toLowerCase() == w.address!.toLowerCase();

    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.account_balance_wallet_outlined),
          const SizedBox(width: 8),
          Text('Wallet', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 10),
        if (!svc.isAvailable)
          InfoBanner(svc.unavailableReason, tone: BannerTone.warn)
        else if (!w.connected) ...[
          const Text('Connect an EVM wallet (e.g. MetaMask). BillFlow never sees your private key; every transaction is signed in your wallet.'),
          const SizedBox(height: 10),
          BusyButton(label: 'Connect wallet', icon: Icons.link, busy: w.busy, onPressed: () => ref.read(walletProvider.notifier).connect()),
        ] else ...[
          KeyValue('Address', w.address, copy: true, mono: true),
          KeyValue('Network', w.chainId == null ? '—' : (target != null && w.chainId == target.chainId ? 'Whitechain Sepolia (${w.chainId})' : 'Chain ${w.chainId}')),
          if (wrongNet) ...[
            const SizedBox(height: 6),
            const InfoBanner('Your wallet is on a different network than BillFlow uses.', tone: BannerTone.warn),
            const SizedBox(height: 8),
            BusyButton(label: 'Switch to Whitechain Sepolia', busy: w.busy, onPressed: () => ref.read(walletProvider.notifier).switchNetwork(target.chainId, target.explorerUrl)),
          ],
          if (showLink && profile != null) KeyValue('Linked to account', linked ? 'Yes' : (profile.walletAddress == null ? 'No wallet linked' : 'Different wallet linked (${shortAddr(profile.walletAddress)})')),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (showLink && !linked) FilledButton.icon(onPressed: () => linkConnectedWallet(context, ref), icon: const Icon(Icons.verified_user_outlined), label: const Text('Link wallet (sign message)')),
            OutlinedButton(
              onPressed: () {
                ref.read(walletProvider.notifier).disconnect();
                toast(context, 'Wallet forgotten in BillFlow. To revoke site access, disconnect it in your wallet extension.');
              },
              child: const Text('Disconnect'),
            ),
          ]),
        ],
        if (w.error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(w.error!, style: const TextStyle(color: Tokens.danger))),
      ]),
    );
  }
}
