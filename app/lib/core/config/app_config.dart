/// Public, compile-time configuration (`--dart-define-from-file=env.json`). No secrets belong here.
class AppConfig {
  static const apiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'http://localhost:8000/api/v1');
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  // Whitechain Sepolia (OP Stack L2). Values from the approved Step 1 docs; override via defines if Whitechain changes them.
  static const chainId = int.fromEnvironment('CHAIN_ID', defaultValue: 1874);
  static const rpcUrl = String.fromEnvironment('RPC_URL', defaultValue: 'https://rpc.testnet.whitechain.io');
  static const explorerUrl = String.fromEnvironment('EXPLORER_URL', defaultValue: 'https://explorer.testnet.whitechain.io');
  static const checkoutBaseUrl = String.fromEnvironment('CHECKOUT_BASE_URL', defaultValue: '');

  static const chainName = 'Whitechain Sepolia';
  static const nativeSymbol = 'WBT';

  static bool get isConfigured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty && apiBaseUrl.isNotEmpty;

  static String txUrl(String hash) => '${explorerUrl.replaceAll(RegExp(r'/+$'), '')}/tx/$hash';
  static String addressUrl(String a) => '${explorerUrl.replaceAll(RegExp(r'/+$'), '')}/address/$a';
}
