import 'package:dio/dio.dart';

import '../../config/app_config.dart';
import '../../errors/app_exception.dart';
import '../../utils/abi.dart';

/// Read-only JSON-RPC access to Whitechain Sepolia (public RPC from config). Used for balances, allowances and receipt waiting.
/// It never decides that a PAYMENT succeeded - only the backend verification does. Receipts here only gate the approve->pay sequence.
class ChainReader {
  ChainReader({Dio? dio, String? rpcUrl})
      : _dio = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 15), receiveTimeout: const Duration(seconds: 20))),
        _rpc = rpcUrl ?? AppConfig.rpcUrl;
  final Dio _dio;
  final String _rpc;
  int _id = 0;
  String get rpcForWallet => _rpc;

  Future<dynamic> _call(String method, List<Object?> params) async {
    try {
      final r = await _dio.post<dynamic>(_rpc, data: {'jsonrpc': '2.0', 'id': ++_id, 'method': method, 'params': params});
      final d = r.data;
      if (d is Map && d['error'] != null) throw AppException('rpc_error', 'RPC error: ${(d['error'] as Map)['message']}');
      return (d as Map)['result'];
    } on DioException catch (e) {
      throw AppException('network', 'Cannot reach the Whitechain RPC (${e.type.name}).');
    }
  }

  Future<int> chainId() async => int.parse('${await _call('eth_chainId', [])}'.substring(2), radix: 16);

  Future<BigInt> _uintCall(String to, String data) async => decodeUint('${await _call('eth_call', [{'to': to, 'data': data}, 'latest'])}');

  Future<BigInt> erc20Balance(String token, String owner) => _uintCall(token, encodeBalanceOf(owner));
  Future<BigInt> erc20Allowance(String token, String owner, String spender) => _uintCall(token, encodeAllowance(owner, spender));
  Future<int> erc20Decimals(String token) async => (await _uintCall(token, encodeDecimals())).toInt();

  /// Native gas balance (WBT) - used to warn before sending when the wallet cannot pay gas.
  Future<BigInt> nativeBalance(String owner) async => decodeUint('${await _call('eth_getBalance', [owner, 'latest'])}');

  /// null = not mined yet; true = status 1; false = reverted.
  Future<bool?> receiptStatus(String txHash) async {
    final r = await _call('eth_getTransactionReceipt', [txHash]);
    if (r == null) return null;
    return '${(r as Map)['status']}' == '0x1';
  }

  Future<bool> waitForReceipt(String txHash, {Duration timeout = const Duration(minutes: 3), Duration every = const Duration(seconds: 3)}) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      final s = await receiptStatus(txHash);
      if (s != null) return s;
      await Future<void>.delayed(every);
    }
    throw AppException('timeout', 'The transaction was not mined within ${timeout.inMinutes} minutes. It may still confirm - check the explorer.');
  }
}
