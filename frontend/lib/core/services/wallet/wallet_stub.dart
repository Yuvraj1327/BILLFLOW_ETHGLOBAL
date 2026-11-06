import 'wallet_service.dart';

/// Used on platforms without an injected EIP-1193 provider (Android/iOS builds, tests).
/// Mobile wallet connectivity (WalletConnect/Reown) is NOT implemented; use the web checkout in a wallet-enabled browser.
class UnsupportedWalletService implements WalletService {
  @override
  bool get isAvailable => false;
  @override
  String get unavailableReason =>
      'No browser wallet is available on this platform. Open NEXA BILLFLOW in a desktop browser with MetaMask (or another EVM wallet). '
      'Mobile WalletConnect is not implemented in this build.';

  Never _no() => throw WalletException(WalletErrorKind.unavailable, unavailableReason);

  @override
  Future<String> connect() async => _no();
  @override
  Future<String?> connectedAddress() async => null;
  @override
  Future<int> chainId() async => _no();
  @override
  Future<void> switchToChain({required int chainId, required String name, required String rpcUrl, required String explorerUrl, required String symbol}) async => _no();
  @override
  Future<String> sendTransaction({required String from, required String to, required String data}) async => _no();
  @override
  Future<String> personalSign({required String address, required String message}) async => _no();
  @override
  void listen({void Function(String? account)? onAccount, void Function(int chainId)? onChain}) {}
}

WalletService createWalletService() => UnsupportedWalletService();
