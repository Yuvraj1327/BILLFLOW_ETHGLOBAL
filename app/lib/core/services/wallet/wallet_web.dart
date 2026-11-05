import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'wallet_service.dart';

extension type _Eth(JSObject _) implements JSObject {
  external JSPromise<JSAny?> request(JSObject args);
  external void on(JSString event, JSFunction handler);
}

/// EIP-1193 wallet via the injected `window.ethereum` (MetaMask and compatible). Flutter Web only.
/// Uses dart:js_interop; written without a compiler available in the build sandbox, so treat as untested until run in a browser.
class BrowserWalletService implements WalletService {
  _Eth? get _eth {
    if (!globalContext.has('ethereum')) return null;
    final e = globalContext['ethereum'];
    return e == null ? null : _Eth(e as JSObject);
  }

  @override
  bool get isAvailable => _eth != null;
  @override
  String get unavailableReason => 'No EVM wallet found in this browser. Install MetaMask (or another EIP-1193 wallet) and reload.';

  Future<Object?> _request(String method, [List<Object?> params = const []]) async {
    final eth = _eth;
    if (eth == null) throw WalletException(WalletErrorKind.unavailable, unavailableReason);
    final args = <String, Object?>{'method': method, 'params': params}.jsify() as JSObject;
    try {
      final res = await eth.request(args).toDart;
      return res.dartify();
    } catch (e) {
      throw _map(e);
    }
  }

  WalletException _map(Object e) {
    int? code;
    var msg = '$e';
    try {
      final o = e as JSObject;
      final c = o['code'];
      if (c != null) code = (c as JSNumber).toDartInt;
      final m = o['message'];
      if (m != null) msg = (m as JSString).toDart;
    } catch (_) {}
    if (code == 4001) return WalletException(WalletErrorKind.userRejected, 'You rejected the request in your wallet.');
    if (code == -32002) return WalletException(WalletErrorKind.pending, 'A wallet request is already open. Check your wallet window.');
    if (code == 4902) return WalletException(WalletErrorKind.wrongNetwork, 'The network is not added to your wallet yet.');
    return WalletException(WalletErrorKind.failed, msg);
  }

  @override
  Future<String> connect() async {
    final r = await _request('eth_requestAccounts') as List?;
    if (r == null || r.isEmpty) throw WalletException(WalletErrorKind.failed, 'The wallet returned no account.');
    return '${r.first}'.toLowerCase();
  }

  @override
  Future<String?> connectedAddress() async {
    if (_eth == null) return null;
    final r = await _request('eth_accounts') as List?;
    return (r == null || r.isEmpty) ? null : '${r.first}'.toLowerCase();
  }

  @override
  Future<int> chainId() async => int.parse('${await _request('eth_chainId')}'.substring(2), radix: 16);

  @override
  Future<void> switchToChain({required int chainId, required String name, required String rpcUrl, required String explorerUrl, required String symbol}) async {
    final hex = '0x${chainId.toRadixString(16)}';
    try {
      await _request('wallet_switchEthereumChain', [{'chainId': hex}]);
    } on WalletException catch (e) {
      if (e.kind != WalletErrorKind.wrongNetwork) rethrow;
      await _request('wallet_addEthereumChain', [
        {
          'chainId': hex,
          'chainName': name,
          'nativeCurrency': {'name': symbol, 'symbol': symbol, 'decimals': 18},
          'rpcUrls': [rpcUrl],
          'blockExplorerUrls': [explorerUrl],
        }
      ]);
    }
  }

  @override
  Future<String> sendTransaction({required String from, required String to, required String data}) async {
    final h = await _request('eth_sendTransaction', [
      {'from': from, 'to': to, 'data': data}
    ]);
    return '$h'.toLowerCase();
  }

  @override
  Future<String> personalSign({required String address, required String message}) async {
    // personal_sign takes the message as 0x-hex of its UTF-8 bytes.
    final hex = '0x${utf8.encode(message).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
    return '${await _request('personal_sign', [hex, address])}';
  }

  @override
  void listen({void Function(String? account)? onAccount, void Function(int chainId)? onChain}) {
    final eth = _eth;
    if (eth == null) return;
    if (onAccount != null) {
      eth.on('accountsChanged'.toJS, ((JSAny? a) {
        final l = a.dartify();
        onAccount(l is List && l.isNotEmpty ? '${l.first}'.toLowerCase() : null);
      }).toJS);
    }
    if (onChain != null) {
      eth.on('chainChanged'.toJS, ((JSAny? c) {
        final s = '${c.dartify()}';
        onChain(int.tryParse(s.startsWith('0x') ? s.substring(2) : s, radix: s.startsWith('0x') ? 16 : 10) ?? 0);
      }).toJS);
    }
  }
}

WalletService createWalletService() => BrowserWalletService();
