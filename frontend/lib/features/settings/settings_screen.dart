import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme/app_theme.dart';
import '../../core/config/app_config.dart';
import '../../core/widgets/widgets.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final profile = ref.watch(authProvider).valueOrNull;
    return SingleChildScrollView(
      child: ResponsiveBody(
        maxWidth: 640,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (profile != null) ...[
            const SectionTitle('Account'),
            AppCard(
              child: Row(children: [
                CircleAvatar(radius: 24, backgroundColor: Tokens.blue, foregroundColor: Colors.white, child: Text(profile.label.isEmpty ? '?' : profile.label[0].toUpperCase(), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18))),
                const SizedBox(width: 14),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(profile.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  const SizedBox(height: 4),
                  StatusChip('ACTIVE', label: profile.role.toUpperCase()),
                ])),
              ]),
            ),
          ],
          const SectionTitle('Appearance'),
          AppCard(
            child: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_outlined), label: Text('Light')),
                ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_outlined), label: Text('Dark')),
                ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.settings_suggest_outlined), label: Text('System')),
              ],
              selected: {mode},
              onSelectionChanged: (s) => ref.read(themeModeProvider.notifier).set(s.first),
            ),
          ),
          const SectionTitle('Environment (public values only)'),
          AppCard(
            child: Column(children: [
              KeyValue('API', AppConfig.apiBaseUrl),
              KeyValue('Network', '${AppConfig.chainName} (${AppConfig.chainId})'),
              KeyValue('Explorer', AppConfig.explorerUrl),
            ]),
          ),
          const SectionTitle('Session'),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () async {
              if (await confirm(context, 'Log out?', 'You will need to sign in again to access your account.', action: 'Log out', destructive: true)) {
                await ref.read(authProvider.notifier).signOut();
              }
            },
            icon: const Icon(Icons.logout),
            label: const Text('Log out'),
          ),
        ]),
      ),
    );
  }
}
