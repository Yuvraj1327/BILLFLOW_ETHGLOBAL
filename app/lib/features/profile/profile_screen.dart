import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/widgets.dart';
import '../wallet/wallet_actions.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});
  @override
  ConsumerState<ProfileScreen> createState() => _S();
}

class _S extends ConsumerState<ProfileScreen> {
  final _name = TextEditingController();
  bool _busy = false, _init = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().length < 2) {
      toast(context, 'Enter your name (at least 2 characters).', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(apiProvider).updateMe(_name.text.trim());
      await ref.read(authProvider.notifier).reload();
      if (mounted) toast(context, 'Profile saved');
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(authProvider).valueOrNull;
    if (p == null) return const SizedBox.shrink();
    if (!_init) {
      _name.text = p.displayName ?? '';
      _init = true;
    }
    return SingleChildScrollView(
      child: ResponsiveBody(
        maxWidth: 640,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              KeyValue('Email', p.email),
              KeyValue('Role', titleCase(p.role)),
              if (p.isInvestor) KeyValue('Investor status', titleCase(p.investorVerification)),
              KeyValue('Linked wallet', p.walletAddress, copy: true, mono: true),
              const SizedBox(height: 8),
              TextField(controller: _name, decoration: const InputDecoration(labelText: 'Display name')),
              const SizedBox(height: 12),
              Align(alignment: Alignment.centerLeft, child: BusyButton(label: 'Save', busy: _busy, onPressed: _save)),
              const SizedBox(height: 4),
              Text('Your role is assigned and enforced by the BillFlow backend; it cannot be changed from the app.', style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12)),
            ]),
          ),
          const SizedBox(height: 12),
          const WalletPanel(),
        ]),
      ),
    );
  }
}
