/// Abstraction over an EIP-1193 wallet. The app NEVER sees a private key: it only asks the wallet to connect, switch
/// network, sign a message, or sign+send a transaction, and receives an address / signature / tx hash back.
abstract class WalletService {
  /// True when a wallet provider is present (browser extension on web). False on platforms without one.
  bool get isAvailable;
  String get unavailableReason;

  Future<String> connect();
  Future<String?> connectedAddress();
  Future<int> chainId();
  Future<void> switchToChain({required int chainId, required String name, required String rpcUrl, required String explorerUrl, required String symbol});
  Future<String> sendTransaction({required String from, required String to, required String data});
  Future<String> personalSign({required String address, required String message});

  /// Fires with the (possibly null) account / chain id whenever the user changes them in the wallet.
  void listen({void Function(String? account)? onAccount, void Function(int chainId)? onChain});
}

enum WalletErrorKind { unavailable, userRejected, wrongNetwork, pending, failed }

class WalletException implements Exception {
  WalletException(this.kind, this.message);
  final WalletErrorKind kind;
  final String message;
  bool get userRejected => kind == WalletErrorKind.userRejected;
  @override
  String toString() => message;
}
