import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../app/providers.dart';
import '../../app/theme/app_theme.dart';
import '../../core/config/app_config.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/validators.dart' as v;
import '../../core/widgets/widgets.dart';

class Splash extends StatelessWidget {
  const Splash({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        _Logo(size: 64), SizedBox(height: 24), CircularProgressIndicator()])));
}

class _Logo extends StatelessWidget {
  const _Logo({this.size = 40});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
        width: size, height: size,
        decoration: BoxDecoration(gradient: const LinearGradient(colors: [Tokens.blue, Tokens.blueDeep]), borderRadius: BorderRadius.circular(size * .28)),
        child: Icon(Icons.receipt_long, color: Colors.white, size: size * .55),
      );
}

class ConfigErrorScreen extends StatelessWidget {
  const ConfigErrorScreen({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(
        body: EmptyState(icon: Icons.settings_suggest, title: 'App is not configured',
            message: 'Build with --dart-define-from-file=env.json containing API_BASE_URL, SUPABASE_URL and SUPABASE_ANON_KEY (see app/README.md).'));
}

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final points = const [
      (Icons.payments_outlined, 'Get paid in USDT', 'Share a payment link. Customers pay with their own wallet on Whitechain.'),
      (Icons.account_balance_outlined, 'Finance unpaid invoices', 'Request an advance; verified investors fund it on-chain.'),
      (Icons.auto_awesome_outlined, 'AI-assisted invoices', 'Claude extracts and checks invoice data. You always confirm.'),
    ];
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: ResponsiveBody(
            maxWidth: 560,
            padding: const EdgeInsets.all(24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const SizedBox(height: 32),
              const _Logo(size: 56),
              const SizedBox(height: 24),
              Text('BillFlow', style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text('Business payments and invoice financing on ${AppConfig.chainName}.', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 28),
              for (final p in points)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: AppCard(child: Row(children: [
                    Icon(p.$1, color: Tokens.blue, size: 28),
                    const SizedBox(width: 14),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(p.$2, style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(p.$3, style: TextStyle(color: Theme.of(context).hintColor)),
                    ])),
                  ])),
                ),
              const SizedBox(height: 12),
              SizedBox(width: double.infinity, child: FilledButton(onPressed: () => context.go('/register'), child: const Text('Create account'))),
              const SizedBox(height: 10),
              SizedBox(width: double.infinity, child: OutlinedButton(onPressed: () => context.go('/login'), child: const Text('Log in'))),
              const SizedBox(height: 16),
              const Text('Testnet demo. Illustrative terms only; nothing here is a guaranteed return.', style: TextStyle(fontSize: 12)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _AuthScaffold extends StatelessWidget {
  const _AuthScaffold({required this.title, required this.child, this.footer});
  final String title;
  final Widget child;
  final Widget? footer;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title), leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/welcome'))),
        body: SafeArea(child: SingleChildScrollView(child: ResponsiveBody(maxWidth: 480, padding: const EdgeInsets.all(24), child: Column(children: [child, if (footer != null) ...[const SizedBox(height: 16), footer!]])))),
      );
}

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, this.notice});
  final String? notice;
  @override
  ConsumerState<LoginScreen> createState() => _LoginState();
}

class _LoginState extends ConsumerState<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController(), _pass = TextEditingController();
  bool _busy = false, _show = false;
  String? _error;

  @override
  void dispose() { _email.dispose(); _pass.dispose(); super.dispose(); }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() { _busy = true; _error = null; });
    try {
      await supabase.auth.signInWithPassword(email: _email.text.trim(), password: _pass.text);
      // The router redirect takes over once the auth provider has loaded the backend profile.
    } on sb.AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _AuthScaffold(
        title: 'Log in',
        footer: Column(children: [
          TextButton(onPressed: () => context.go('/forgot'), child: const Text('Forgot password?')),
          TextButton(onPressed: () => context.go('/register'), child: const Text('New here? Create an account')),
        ]),
        child: Form(
          key: _form,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (widget.notice != null) ...[InfoBanner(widget.notice!, tone: BannerTone.warn), const SizedBox(height: 14)],
            TextFormField(controller: _email, keyboardType: TextInputType.emailAddress, autofillHints: const [AutofillHints.email], decoration: const InputDecoration(labelText: 'Email'), validator: v.email),
            const SizedBox(height: 14),
            TextFormField(
              controller: _pass, obscureText: !_show, autofillHints: const [AutofillHints.password], onFieldSubmitted: (_) => _submit(),
              decoration: InputDecoration(labelText: 'Password', suffixIcon: IconButton(icon: Icon(_show ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => _show = !_show))),
              validator: (x) => v.required(x, 'Password'),
            ),
            if (_error != null) ...[const SizedBox(height: 14), InfoBanner(_error!, tone: BannerTone.error)],
            const SizedBox(height: 20),
            BusyButton(label: 'Log in', busy: _busy, onPressed: _submit),
          ]),
        ),
      );
}

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});
  @override
  ConsumerState<RegisterScreen> createState() => _RegisterState();
}

class _RegisterState extends ConsumerState<RegisterScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(), _email = TextEditingController(), _pass = TextEditingController();
  String _role = 'merchant';
  bool _busy = false, _sent = false;
  String? _error;

  @override
  void dispose() { _name.dispose(); _email.dispose(); _pass.dispose(); super.dispose(); }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() { _busy = true; _error = null; });
    try {
      // `role` is only a REQUEST (merchant / investor / customer). The database trigger clamps it; admin is impossible here.
      final res = await supabase.auth.signUp(email: _email.text.trim(), password: _pass.text, data: {'role': _role, 'display_name': _name.text.trim()});
      if (res.session == null && mounted) setState(() => _sent = true); // email confirmation is enabled in Supabase
    } on sb.AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_sent) {
      return _AuthScaffold(
        title: 'Verify your email',
        child: Column(children: [
          const Icon(Icons.mark_email_read_outlined, size: 56, color: Tokens.blue),
          const SizedBox(height: 16),
          Text('We sent a confirmation link to ${_email.text.trim()}. Open it, then log in.', textAlign: TextAlign.center),
          const SizedBox(height: 20),
          FilledButton(onPressed: () => context.go('/login'), child: const Text('Go to log in')),
        ]),
      );
    }
    return _AuthScaffold(
      title: 'Create account',
      footer: TextButton(onPressed: () => context.go('/login'), child: const Text('Already have an account? Log in')),
      child: Form(
        key: _form,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'merchant', label: Text('Merchant'), icon: Icon(Icons.storefront_outlined)),
              ButtonSegment(value: 'investor', label: Text('Investor'), icon: Icon(Icons.trending_up)),
              ButtonSegment(value: 'customer', label: Text('Customer'), icon: Icon(Icons.person_outline)),
            ],
            selected: {_role},
            onSelectionChanged: (s) => setState(() => _role = s.first),
          ),
          const SizedBox(height: 6),
          Text(switch (_role) {
            'merchant' => 'Issue invoices, get paid in USDT, request financing.',
            'investor' => 'Fund verified invoices on-chain. Requires a linked wallet.',
            _ => 'View your payments. You can also pay any invoice link without an account.',
          }, style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13)),
          const SizedBox(height: 16),
          TextFormField(controller: _name, decoration: const InputDecoration(labelText: 'Your name'), validator: (x) => v.required(x, 'Name')),
          const SizedBox(height: 14),
          TextFormField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email'), validator: v.email),
          const SizedBox(height: 14),
          TextFormField(controller: _pass, obscureText: true, decoration: const InputDecoration(labelText: 'Password'), validator: v.password),
          if (_error != null) ...[const SizedBox(height: 14), InfoBanner(_error!, tone: BannerTone.error)],
          const SizedBox(height: 20),
          BusyButton(label: 'Create account', busy: _busy, onPressed: _submit),
          const SizedBox(height: 10),
          const Text('Admin accounts cannot be created here.', style: TextStyle(fontSize: 12)),
        ]),
      ),
    );
  }
}

class ForgotScreen extends StatefulWidget {
  const ForgotScreen({super.key});
  @override
  State<ForgotScreen> createState() => _ForgotState();
}

class _ForgotState extends State<ForgotScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  bool _busy = false, _sent = false;
  String? _error;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() { _busy = true; _error = null; });
    try {
      await supabase.auth.resetPasswordForEmail(_email.text.trim());
      setState(() => _sent = true);
    } on sb.AuthException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _AuthScaffold(
        title: 'Reset password',
        child: _sent
            ? const InfoBanner('If an account exists for that email, a reset link is on its way.', tone: BannerTone.success, icon: Icons.check_circle_outline)
            : Form(
                key: _form,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  TextFormField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email'), validator: v.email),
                  if (_error != null) ...[const SizedBox(height: 14), InfoBanner(_error!, tone: BannerTone.error)],
                  const SizedBox(height: 20),
                  BusyButton(label: 'Send reset link', busy: _busy, onPressed: _submit),
                ]),
              ),
      );
}
