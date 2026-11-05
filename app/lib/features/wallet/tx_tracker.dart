import 'package:shared_preferences/shared_preferences.dart';

import '../../shared/models/models.dart';

/// Polls a backend verification endpoint until the tx is verified / terminally failed / the timeout passes.
/// The BACKEND decides the outcome; the client only waits and displays.
Future<TxVerification> pollVerification(
  Future<TxVerification> Function() check, {
  Duration every = const Duration(seconds: 4),
  Duration timeout = const Duration(minutes: 4),
  void Function(TxVerification)? onUpdate,
  bool Function()? cancelled,
}) async {
  final end = DateTime.now().add(timeout);
  var errors = 0;
  TxVerification? last;
  while (true) {
    try {
      last = await check();
      errors = 0;
      onUpdate?.call(last);
      if (last.verified || last.terminalFailure) return last;
    } catch (_) {
      if (++errors >= 3) rethrow; // tolerate brief network blips
    }
    if (last != null && DateTime.now().isAfter(end)) return last;
    if (last == null && DateTime.now().isAfter(end)) throw StateError('Verification timed out');
    await Future<void>.delayed(every);
    if (cancelled?.call() ?? false) {
      if (last != null) return last;
      throw StateError('Cancelled');
    }
  }
}

/// Remembers a submitted-but-unconfirmed tx hash per scope (e.g. a payment link) so a refresh cannot trigger a second payment.
class PendingTx {
  static String _k(String scope) => 'pending_tx_$scope';
  static Future<String?> load(String scope) async => (await SharedPreferences.getInstance()).getString(_k(scope));
  static Future<void> save(String scope, String hash) async => (await SharedPreferences.getInstance()).setString(_k(scope), hash);
  static Future<void> clear(String scope) async => (await SharedPreferences.getInstance()).remove(_k(scope));
}
