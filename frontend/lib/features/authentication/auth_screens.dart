import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../app/providers.dart';
import '../../app/theme/app_theme.dart';
import '../../core/config/app_config.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/validators.dart' as v;
import '../../core/widgets/brand_logo.dart';
import '../../core/widgets/widgets.dart';

class Splash extends StatelessWidget {
  const Splash({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        BrandLockup(height: 72, stacked: true), SizedBox(height: 32), CircularProgressIndicator()])));
}

class ConfigErrorScreen extends StatelessWidget {
  const ConfigErrorScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        body: EmptyState(icon: Icons.settings_suggest, title: 'App is not configured',
            message: '${AppConfig.problem ?? 'Configuration is missing.'}\nCopy frontend/.env.example to frontend/.env and fill in the public values (see frontend/README.md).'));
}

class _AuthScaffold extends StatelessWidget {
  const _AuthScaffold({required this.title, required this.child, this.footer});
  final String title;
  final Widget child;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final desktop = MediaQuery.sizeOf(context).width >= 960;
    final form = SafeArea(
      child: Center(
        child: SingleChildScrollView(
          child: ResponsiveBody(
            maxWidth: 460,
            padding: const EdgeInsets.all(24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (desktop) ...[
                Text(title, style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 24),
              ],
              child,
              if (footer != null) ...[const SizedBox(height: 16), Center(child: footer!)],
            ]),
          ),
        ),
      ),
    );
    if (!desktop) {
      return Scaffold(
        appBar: AppBar(title: BrandTitle(title), leading: BackButton(onPressed: () => context.canPop() ? context.pop() : context.go('/welcome'))),
        body: form,
      );
    }
    return Scaffold(
      body: Row(children: [
        Expanded(
          flex: 5,
          child: Container(
            decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Tokens.blueDeep, Tokens.blue, Color(0xFF01575F)])),
            padding: const EdgeInsets.all(56),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              InkWell(onTap: () => context.go('/welcome'), child: const BrandLockup(height: 40, onDark: true)),
              const Spacer(),
              const Text('Get paid in USDT.\nFinance your invoices.', style: TextStyle(color: Colors.white, fontSize: 42, fontWeight: FontWeight.w900, height: 1.1, letterSpacing: -1)),
              const SizedBox(height: 16),
              Text('Payment links, on-chain verification and an investor marketplace in one place.', style: TextStyle(color: Colors.white.withValues(alpha: .8), fontSize: 17, height: 1.5)),
              const SizedBox(height: 32),
              for (final t in const ['No account needed to pay an invoice', 'Every payment verified on-chain', 'Role-based, secure access'])
                Padding(padding: const EdgeInsets.only(bottom: 10), child: Row(children: [const Icon(Icons.check_circle, color: Color(0xFF2CC4B7), size: 20), const SizedBox(width: 10), Text(t, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600))])),
              const Spacer(),
              Text('Testnet demo on ${AppConfig.chainName}.', style: TextStyle(color: Colors.white.withValues(alpha: .6), fontSize: 12.5)),
            ]),
          ),
        ),
        Expanded(flex: 6, child: form),
      ]),
    );
  }
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
      // Load the BACKEND profile now so a failure (API down, wrong URL, no profile) is shown here instead of the
      // router silently bouncing back to the welcome screen. On success the router sends the user to their dashboard.
      ref.read(authNoticeProvider.notifier).state = null;
      try {
        await ref.read(authProvider.notifier).reload();
        final st = ref.read(authProvider);
        if (st.hasError) throw st.error!;
      } catch (e) {
        await supabase.auth.signOut();
        if (mounted) setState(() => _error = 'Signed in, but your profile could not be loaded: ${errorText(e)}');
      }
    } on sb.AuthException catch (e) {
      setState(() => _error = authErrorText(e));
    } catch (e) {
      setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final notice = widget.notice ?? ref.watch(authNoticeProvider);
    return _AuthScaffold(
        title: 'Log in',
        footer: Column(children: [
          TextButton(onPressed: () => context.go('/forgot'), child: const Text('Forgot password?')),
          TextButton(onPressed: () => context.go('/register'), child: const Text('New here? Create an account')),
        ]),
        child: Form(
          key: _form,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (notice != null) ...[InfoBanner(notice, tone: BannerTone.warn), const SizedBox(height: 14)],
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
}

/// Admin accounts are created by an existing admin (never self-service). This screen only signs in, then verifies the
/// BACKEND role: a non-admin account is signed straight back out.
class AdminLoginScreen extends ConsumerStatefulWidget {
  const AdminLoginScreen({super.key});
  @override
  ConsumerState<AdminLoginScreen> createState() => _AdminLoginState();
}

class _AdminLoginState extends ConsumerState<AdminLoginScreen> {
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
      final me = await ref.read(apiProvider).me();
      if (!me.isAdmin) {
        await supabase.auth.signOut();
        if (mounted) setState(() => _error = 'This account does not have admin access.');
      }
    } on sb.AuthException catch (e) {
      setState(() => _error = authErrorText(e));
    } catch (e) {
      await supabase.auth.signOut();
      setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _AuthScaffold(
        title: 'Admin sign in',
        footer: TextButton(onPressed: () => context.go('/login'), child: const Text('Back to regular sign in')),
        child: Form(
          key: _form,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const InfoBanner('Restricted area. Admin accounts are created by an existing administrator.', icon: Icons.lock_outline),
            const SizedBox(height: 14),
            TextFormField(controller: _email, keyboardType: TextInputType.emailAddress, autofillHints: const [AutofillHints.email], decoration: const InputDecoration(labelText: 'Admin email'), validator: v.email),
            const SizedBox(height: 14),
            TextFormField(
              controller: _pass, obscureText: !_show, autofillHints: const [AutofillHints.password], onFieldSubmitted: (_) => _submit(),
              decoration: InputDecoration(labelText: 'Password', suffixIcon: IconButton(icon: Icon(_show ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => _show = !_show))),
              validator: (x) => v.required(x, 'Password'),
            ),
            if (_error != null) ...[const SizedBox(height: 14), InfoBanner(_error!, tone: BannerTone.error)],
            const SizedBox(height: 20),
            BusyButton(label: 'Sign in', busy: _busy, onPressed: _submit),
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
      // The backend creates the Supabase user + profile (role is only a REQUEST: merchant / investor; admin is impossible).
      // In development the account is pre-confirmed, so we can log in immediately and the router sends the user to their dashboard.
      final out = await ref.read(apiProvider).signup(_email.text.trim(), _pass.text, _role, _name.text.trim());
      if (out['confirmation_required'] == true) {
        if (mounted) setState(() => _sent = true); // production project with e-mail confirmation enabled
        return;
      }
      await supabase.auth.setSession(out['refresh_token'] as String);
      await ref.read(authProvider.notifier).reload(); // verified role from the backend -> router redirects
    } on sb.AuthException catch (e) {
      setState(() => _error = authErrorText(e));
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
            ],
            selected: {_role},
            onSelectionChanged: (s) => setState(() => _role = s.first),
          ),
          const SizedBox(height: 6),
          Text(switch (_role) {
            'merchant' => 'Issue invoices, get paid in USDT, request financing.',
            _ => 'Fund verified invoices on-chain. You will complete a short verification first.',
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
          const Text('Paying an invoice? No account needed: just open the payment link you were sent.', style: TextStyle(fontSize: 12)),
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
      setState(() => _error = authErrorText(e));
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
