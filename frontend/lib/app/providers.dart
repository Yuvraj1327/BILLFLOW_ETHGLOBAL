import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../core/errors/app_exception.dart';
import '../core/network/api_client.dart';
import '../core/services/wallet/chain_reader.dart';
import '../core/services/wallet/wallet_factory.dart';
import '../core/services/wallet/wallet_service.dart';
import '../core/utils/format.dart';
import '../data/billflow_api.dart';
import '../shared/models/models.dart';

sb.SupabaseClient get supabase => sb.Supabase.instance.client;

// ───────────── infrastructure ─────────────
final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(
    tokenGetter: () async => supabase.auth.currentSession?.accessToken,
    refreshSession: () async {
      try {
        final r = await supabase.auth.refreshSession();
        return r.session != null;
      } catch (_) {
        await supabase.auth.signOut(); // session cannot be recovered -> router sends the user to login
        return false;
      }
    },
  );
});

final apiProvider = Provider<BillflowApi>((ref) => BillflowApi(ref.watch(apiClientProvider)));
final chainReaderProvider = Provider<ChainReader>((ref) => ChainReader());
final walletServiceProvider = Provider<WalletService>((ref) => createWalletService());

// ───────────── theme setting ─────────────
class ThemeModeController extends Notifier<ThemeMode> {
  static const _key = 'theme_mode';
  @override
  ThemeMode build() {
    _load();
    return ThemeMode.light; // light is the default
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_key);
    if (v == 'dark') state = ThemeMode.dark;
  }

  Future<void> set(ThemeMode m) async {
    state = m;
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, m == ThemeMode.dark ? 'dark' : 'light');
  }
}

final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(ThemeModeController.new);

// ───────────── authentication ─────────────
/// Holds the backend profile (role comes from GET /users/me, never from the token or the UI).
/// `null` data = signed out. Re-evaluates whenever Supabase reports a sign-in, sign-out or token refresh.
class AuthController extends AsyncNotifier<Profile?> {
  StreamSubscription<sb.AuthState>? _sub;

  @override
  Future<Profile?> build() async {
    _sub ??= supabase.auth.onAuthStateChange.listen((e) {
      if (e.event == sb.AuthChangeEvent.signedIn || e.event == sb.AuthChangeEvent.signedOut || e.event == sb.AuthChangeEvent.userUpdated) {
        ref.invalidateSelf();
      }
    });
    ref.onDispose(() => _sub?.cancel());
    if (supabase.auth.currentSession == null) return null;
    try {
      // Restores an existing session automatically. Bounded, so a dead API can never leave the user on the splash screen.
      final p = await ref.read(apiProvider).me().timeout(const Duration(seconds: 20));
      ref.read(authNoticeProvider.notifier).state = null;
      return p;
    } catch (e) {
      // Any failure ends here with a visible reason on the login screen instead of an endless spinner or a silent bounce.
      ref.read(authNoticeProvider.notifier).state = e is AppException && e.isUnauthorized
          ? 'Your session expired. Please log in again.'
          : e is TimeoutException ? 'The NEXA BILLFLOW server did not respond. Check that the backend is running, then log in again.'
          : 'Could not load your profile: ${errorText(e)}';
      await supabase.auth.signOut();
      return null;
    }
  }

  Future<void> reload() async {
    state = const AsyncLoading<Profile?>().copyWithPrevious(state);
    state = await AsyncValue.guard(() => ref.read(apiProvider).me().timeout(const Duration(seconds: 20)));
  }

  Future<void> signOut() async {
    await supabase.auth.signOut();
    ref.invalidateSelf();
  }
}

/// Why the user was sent back to the login screen (shown there once).
final authNoticeProvider = StateProvider<String?>((ref) => null);

final authProvider = AsyncNotifierProvider<AuthController, Profile?>(AuthController.new);

// ───────────── wallet ─────────────
class WalletState {
  const WalletState({this.address, this.chainId, this.busy = false, this.error});
  final String? address;
  final int? chainId;
  final bool busy;
  final String? error;
  bool get connected => address != null;
  WalletState copy({String? address, int? chainId, bool? busy, String? error, bool clearAddress = false, bool clearError = false}) => WalletState(
      address: clearAddress ? null : (address ?? this.address),
      chainId: chainId ?? this.chainId,
      busy: busy ?? this.busy,
      error: clearError ? null : (error ?? this.error));
}

class WalletController extends Notifier<WalletState> {
  WalletService get _w => ref.read(walletServiceProvider);

  @override
  WalletState build() {
    _w.listen(
      onAccount: (a) => state = a == null ? const WalletState() : state.copy(address: a),
      onChain: (c) => state = state.copy(chainId: c),
    );
    _restore();
    return const WalletState();
  }

  /// Re-attaches silently if the wallet is already authorised for this site (no popup).
  Future<void> _restore() async {
    if (!_w.isAvailable) return;
    try {
      final a = await _w.connectedAddress();
      if (a != null) state = state.copy(address: a, chainId: await _w.chainId());
    } catch (_) {}
  }

  Future<bool> connect() async {
    state = state.copy(busy: true, clearError: true);
    try {
      final a = await _w.connect();
      state = state.copy(address: a, chainId: await _w.chainId(), busy: false);
      return true;
    } on WalletException catch (e) {
      state = state.copy(busy: false, error: e.message);
      return false;
    }
  }

  /// A browser wallet cannot be disconnected programmatically; we forget it in the app and tell the user how to revoke access.
  void disconnect() => state = const WalletState();

  Future<bool> switchNetwork(int chainId, String explorer) async {
    state = state.copy(busy: true, clearError: true);
    try {
      await _w.switchToChain(chainId: chainId, name: 'Whitechain Sepolia', rpcUrl: ref.read(chainReaderProvider).rpcForWallet, explorerUrl: explorer, symbol: 'WBT');
      state = state.copy(chainId: await _w.chainId(), busy: false);
      return state.chainId == chainId;
    } on WalletException catch (e) {
      state = state.copy(busy: false, error: e.message);
      return false;
    }
  }
}

final walletProvider = NotifierProvider<WalletController, WalletState>(WalletController.new);

/// Backend-verified chain/contract configuration (authenticated roles). The public checkout uses the public invoice payload instead.
final chainConfigProvider = FutureProvider<ChainConfig>((ref) => ref.watch(apiProvider).chainConfig());

String walletShort(WalletState s) => shortAddr(s.address);
