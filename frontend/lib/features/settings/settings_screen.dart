import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/config/app_config.dart';
import '../../core/widgets/widgets.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return SingleChildScrollView(
      child: ResponsiveBody(
        maxWidth: 640,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
            onPressed: () => ref.read(authProvider.notifier).signOut(),
            icon: const Icon(Icons.logout),
            label: const Text('Log out'),
          ),
        ]),
      ),
    );
  }
}
