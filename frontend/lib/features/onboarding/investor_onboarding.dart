import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme/app_theme.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/validators.dart' as v;
import '../../core/widgets/widgets.dart';
import '../../shared/models/json_helpers.dart';

/// Investors are routed here by the router while their BACKEND verification status is `unverified` (or `rejected`, to resubmit).
class InvestorOnboardingScreen extends ConsumerStatefulWidget {
  const InvestorOnboardingScreen({super.key});
  @override
  ConsumerState<InvestorOnboardingScreen> createState() => _OnboardingState();
}

class _OnboardingState extends ConsumerState<InvestorOnboardingScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(), _country = TextEditingController(), _org = TextEditingController(), _tax = TextEditingController();
  String _type = 'individual';
  bool _terms = false, _risk = false, _busy = false, _consentError = false;

  @override
  void dispose() {
    for (final c in [_name, _country, _org, _tax]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final valid = _form.currentState!.validate();
    setState(() => _consentError = !(_terms && _risk));
    if (!valid || !_terms || !_risk) return;
    setState(() => _busy = true);
    try {
      String? opt(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
      await ref.read(apiProvider).submitInvestorOnboarding({
        'full_name': _name.text.trim(),
        'country': _country.text.trim(),
        'investor_type': _type,
        if (opt(_org) != null) 'organization': opt(_org),
        if (opt(_tax) != null) 'tax_id': opt(_tax),
        'accept_terms': _terms,
        'accept_risk': _risk,
      });
      await ref.read(authProvider.notifier).reload(); // verification is now `pending`
      if (mounted) context.go('/investor/verification');
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final rejected = ref.watch(authProvider).valueOrNull?.investorVerification == 'rejected';
    return Scaffold(
      appBar: AppBar(title: const Text('Investor onboarding'), actions: [TextButton(onPressed: () => ref.read(authProvider.notifier).signOut(), child: const Text('Log out'))]),
      body: SingleChildScrollView(
        child: ResponsiveBody(
          maxWidth: 560,
          child: Form(
            key: _form,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              InfoBanner(rejected
                  ? 'Your previous submission was rejected. Update your details and submit again.'
                  : 'Tell us who you are. An admin reviews every investor before they can see or fund invoices.'),
              const SizedBox(height: 16),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'individual', label: Text('Individual'), icon: Icon(Icons.person_outline)),
                  ButtonSegment(value: 'institution', label: Text('Institution'), icon: Icon(Icons.apartment_outlined)),
                ],
                selected: {_type},
                onSelectionChanged: (s) => setState(() => _type = s.first),
              ),
              const SizedBox(height: 16),
              TextFormField(controller: _name, decoration: const InputDecoration(labelText: 'Full legal name *'), validator: (x) => v.required(x, 'Name')),
              const SizedBox(height: 12),
              TextFormField(controller: _country, decoration: const InputDecoration(labelText: 'Country of residence *'), validator: (x) => v.required(x, 'Country')),
              if (_type == 'institution') ...[
                const SizedBox(height: 12),
                TextFormField(controller: _org, decoration: const InputDecoration(labelText: 'Organization name *'), validator: (x) => v.required(x, 'Organization')),
              ],
              const SizedBox(height: 12),
              TextFormField(controller: _tax, decoration: const InputDecoration(labelText: 'Tax ID (optional)')),
              const SizedBox(height: 16),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading, value: _terms,
                onChanged: (x) => setState(() => _terms = x ?? false),
                title: const Text('I accept the NEXA BILLFLOW investor terms.'),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading, value: _risk,
                onChanged: (x) => setState(() => _risk = x ?? false),
                title: const Text('I understand invoice financing can lose value; returns are not guaranteed.'),
              ),
              if (_consentError) Text('Please accept both statements to continue.', style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
              const SizedBox(height: 16),
              BusyButton(label: 'Submit for verification', busy: _busy, onPressed: _submit),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Shown while an investor is `pending` (waiting for an admin) or `rejected` (may resubmit). Verified investors never see it.
class InvestorVerificationScreen extends ConsumerWidget {
  const InvestorVerificationScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(authProvider).valueOrNull?.investorVerification ?? 'pending';
    final rejected = status == 'rejected';
    final notes = ref.watch(_onboardingProvider).valueOrNull?.strN('review_notes');
    return Scaffold(
      appBar: AppBar(title: const Text('Verification'), actions: [TextButton(onPressed: () => ref.read(authProvider.notifier).signOut(), child: const Text('Log out'))]),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: ResponsiveBody(
              maxWidth: 480,
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(rejected ? Icons.cancel_outlined : Icons.hourglass_top_rounded, size: 64, color: rejected ? Tokens.danger : Tokens.blue),
                const SizedBox(height: 16),
                Text(rejected ? 'Verification rejected' : 'Verification in progress', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Text(
                  rejected ? 'An admin could not verify your details.' : 'An admin is reviewing your details. You will be able to browse and fund invoices once approved.',
                  textAlign: TextAlign.center,
                ),
                if (rejected && notes != null && notes.isNotEmpty) ...[const SizedBox(height: 12), InfoBanner('Reviewer notes: $notes', tone: BannerTone.warn)],
                const SizedBox(height: 24),
                if (rejected)
                  FilledButton(onPressed: () => context.go('/onboarding/investor'), child: const Text('Update and resubmit'))
                else
                  OutlinedButton.icon(
                    onPressed: () async {
                      await ref.read(authProvider.notifier).reload();
                      if (context.mounted && ref.read(authProvider).valueOrNull?.investorVerification == 'verified') context.go('/investor');
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('Check status'),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

final _onboardingProvider = FutureProvider.autoDispose<Json?>((ref) => ref.watch(apiProvider).investorOnboarding());
