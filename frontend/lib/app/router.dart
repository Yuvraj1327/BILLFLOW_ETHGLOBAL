import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/config/app_config.dart';
import '../features/admin/admin_screens.dart';
import '../features/authentication/auth_screens.dart';
import '../features/checkout/checkout_screen.dart';
import '../features/checkout/pay_invoice_screen.dart';
import '../features/checkout/receipt_screen.dart';
import '../features/customers/customer_screens.dart';
import '../features/dashboard/merchant_dashboard.dart';
import '../features/financing/financing_screens.dart';
import '../features/invoices/invoice_detail_screen.dart';
import '../features/invoices/invoice_form_screen.dart';
import '../features/invoices/invoice_list_screen.dart';
import '../features/marketplace/marketplace_screens.dart';
import '../features/investments/portfolio_screen.dart';
import '../features/landing/landing_page.dart';
import '../features/notifications/notifications_screen.dart';
import '../features/onboarding/business_onboarding.dart';
import '../features/reports/reports_screen.dart';
import '../features/onboarding/investor_onboarding.dart';
import '../features/business/business_profile_screen.dart';
import '../features/profile/profile_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/transactions/transactions_screen.dart';
import '../features/customers/customer_home.dart';
import '../shared/models/models.dart';
import 'providers.dart';
import 'shell.dart';

String homeFor(Profile p) => switch (p.role) {
      'merchant' => '/merchant',
      'investor' => '/investor',
      'admin' => '/admin',
      _ => '/customer',
    };

const _authRoutes = {'/welcome', '/login', '/admin-login', '/register', '/forgot', '/splash'};

/// Pure redirect function (also used by tests). Roles come from the BACKEND profile only.
String? computeRedirect({required String loc, required bool configured, required AsyncValue<Profile?> auth}) {
  if (!configured) return loc == '/setup-error' ? null : '/setup-error';
  if (loc == '/pay' || loc.startsWith('/pay/') || loc.startsWith('/receipt/')) return null; // public checkout works without login
  if (auth.isLoading && !auth.hasValue) return loc == '/splash' ? null : '/splash';
  final p = auth.valueOrNull;
  if (p == null) return (_authRoutes.contains(loc) && loc != '/splash') ? null : '/welcome';
  final home = homeFor(p);
  if (_authRoutes.contains(loc)) return home;
  // No forced onboarding: merchants and investors land on their dashboard; business setup / investor verification are
  // optional prompts there (the backend still enforces verification where it matters, e.g. funding).
  if (loc == '/onboarding/investor' && !p.isInvestor) return home;
  if (loc == '/onboarding/business' && !p.isMerchant) return home;
  const guards = {'/merchant': 'merchant', '/investor': 'investor', '/admin': 'admin', '/customer': 'customer'};
  for (final e in guards.entries) {
    if ((loc == e.key || loc.startsWith('${e.key}/')) && p.role != e.value) return home;
  }
  return null;
}

class _RouterRefresh extends ChangeNotifier {
  void ping() => notifyListeners();
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh();
  ref.listen(authProvider, (_, __) => refresh.ping());
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) => computeRedirect(loc: state.matchedLocation, configured: AppConfig.isConfigured, auth: ref.read(authProvider)),
    routes: [
      GoRoute(path: '/splash', builder: (_, __) => const Splash()),
      GoRoute(path: '/setup-error', builder: (_, __) => const ConfigErrorScreen()),
      GoRoute(path: '/welcome', builder: (_, __) => const LandingPage()),
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/admin-login', builder: (_, __) => const AdminLoginScreen()),
      GoRoute(path: '/register', builder: (_, __) => const RegisterScreen()),
      GoRoute(path: '/forgot', builder: (_, __) => const ForgotScreen()),
      // Public routes: no login required.
      GoRoute(path: '/pay', builder: (_, __) => const PayInvoiceScreen()),
      GoRoute(path: '/pay/:token', builder: (_, s) => CheckoutScreen(token: s.pathParameters['token']!)),
      GoRoute(path: '/receipt/:token/:tx', builder: (_, s) => ReceiptScreen(token: s.pathParameters['token']!, txHash: s.pathParameters['tx']!)),
      GoRoute(path: '/onboarding/investor', builder: (_, __) => const InvestorOnboardingScreen()),
      GoRoute(path: '/investor/verification', builder: (_, __) => const InvestorVerificationScreen()),
      GoRoute(path: '/onboarding/business', builder: (_, __) => const BusinessOnboardingScreen()),
      ShellRoute(
        builder: (_, state, child) => AppShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(path: '/merchant', builder: (_, __) => const MerchantDashboard(), routes: [
            GoRoute(path: 'invoices', builder: (_, __) => const InvoiceListScreen(), routes: [
              GoRoute(path: 'new', builder: (_, s) => InvoiceFormScreen(customerId: s.uri.queryParameters['customer'])),
              GoRoute(path: ':id', builder: (_, s) => InvoiceDetailScreen(id: s.pathParameters['id']!), routes: [
                GoRoute(path: 'edit', builder: (_, s) => InvoiceFormScreen(editId: s.pathParameters['id'])),
              ]),
            ]),
            GoRoute(path: 'customers', builder: (_, __) => const CustomerListScreen(), routes: [
              GoRoute(path: ':id', builder: (_, s) => CustomerDetailScreen(id: s.pathParameters['id']!)),
            ]),
            GoRoute(path: 'financing', builder: (_, __) => const MerchantFinancingScreen(), routes: [
              GoRoute(path: 'new', builder: (_, s) => FinancingRequestScreen(invoiceId: s.uri.queryParameters['invoice'])),
              GoRoute(path: ':id', builder: (_, s) => OfferDetailScreen(id: s.pathParameters['id']!)),
            ]),
            GoRoute(path: 'business', builder: (_, __) => const BusinessProfileScreen()),
            GoRoute(path: 'reports', builder: (_, __) => const ReportsScreen()),
          ]),
          GoRoute(path: '/investor', builder: (_, __) => const MarketplaceScreen(), routes: [
            GoRoute(path: 'offers/:id', builder: (_, s) => OfferDetailScreen(id: s.pathParameters['id']!)),
            GoRoute(path: 'portfolio', builder: (_, __) => const PortfolioScreen()),
          ]),
          GoRoute(path: '/customer', builder: (_, __) => const CustomerHome()),
          GoRoute(path: '/admin', builder: (_, __) => const AdminDashboard(), routes: [
            GoRoute(path: 'users', builder: (_, __) => const AdminUsers()),
            GoRoute(path: 'businesses', builder: (_, __) => const AdminBusinesses()),
            GoRoute(path: 'financing', builder: (_, __) => const AdminFinancing(), routes: [
              GoRoute(path: ':id', builder: (_, s) => AdminOfferReview(id: s.pathParameters['id']!)),
            ]),
            GoRoute(path: 'monitoring', builder: (_, __) => const AdminMonitoring()),
          ]),
          GoRoute(path: '/transactions', builder: (_, __) => const TransactionsScreen()),
          GoRoute(path: '/notifications', builder: (_, __) => const NotificationsScreen()),
          GoRoute(path: '/profile', builder: (_, __) => const ProfileScreen()),
          GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
        ],
      ),
    ],
    errorBuilder: (_, s) => Scaffold(body: EmptyState2(path: s.uri.toString())),
  );
});

class EmptyState2 extends StatelessWidget {
  const EmptyState2({super.key, required this.path});
  final String path;
  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.explore_off_outlined, size: 48),
          const SizedBox(height: 12),
          Text('No page at $path'),
          const SizedBox(height: 12),
          FilledButton(onPressed: () => context.go('/splash'), child: const Text('Go home')),
        ]),
      );
}
