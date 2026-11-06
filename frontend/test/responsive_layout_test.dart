import 'package:billflow/app/providers.dart';
import 'package:billflow/app/shell.dart';
import 'package:billflow/app/theme/app_theme.dart';
import 'package:billflow/features/landing/landing_page.dart';
import 'package:billflow/features/reports/reports_screen.dart';
import 'package:billflow/shared/models/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const sizes = {'phone': Size(390, 844), 'tablet': Size(820, 1180), 'desktop': Size(1440, 900)};

class _FakeAuth extends AuthController {
  _FakeAuth(this.p);
  final Profile p;
  @override
  Future<Profile?> build() async => p;
}

Profile profile(String role) => Profile({'id': 'u', 'role': role, 'display_name': 'Ada Lovelace', 'investor_verification': 'verified', 'business_id': 'b'});

Future<void> pump(WidgetTester t, Size size, Widget w, {List<Override> overrides = const []}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(ProviderScope(overrides: overrides, child: MaterialApp(theme: lightTheme(), darkTheme: darkTheme(), home: w)));
  await t.pump(const Duration(milliseconds: 300));
}

void main() {
  for (final e in sizes.entries) {
    testWidgets('landing page lays out without overflow on ${e.key}', (t) async {
      await pump(t, e.value, const LandingPage());
      expect(t.takeException(), isNull);
      expect(find.text('NEXA '), findsNothing); // brand is a rich-text span, not a plain Text
      expect(find.textContaining('Get paid in USDT'), findsWidgets);
      // scroll to the bottom: every section must lay out
      await t.drag(find.byType(SingleChildScrollView).first, const Offset(0, -20000));
      await t.pump();
      expect(t.takeException(), isNull);
      expect(find.textContaining('guaranteed return'), findsOneWidget);
    });

    for (final role in ['merchant', 'investor', 'admin']) {
      testWidgets('$role shell renders on ${e.key}', (t) async {
        await pump(t, e.value, const AppShell(location: '/${'x'}', child: Center(child: Text('content'))), overrides: [
          authProvider.overrideWith(() => _FakeAuth(profile(role))),
          unreadCountProvider.overrideWith((ref) async => 3),
        ]);
        await t.pump(const Duration(milliseconds: 300));
        expect(t.takeException(), isNull);
        expect(find.text('content'), findsOneWidget);
        // phone = bottom navigation, desktop = sidebar, tablet = rail
        expect(find.byType(NavigationBar), e.key == 'phone' ? findsOneWidget : findsNothing);
        expect(find.byType(NavigationRail), e.key == 'tablet' ? findsOneWidget : findsNothing);
        if (e.key == 'desktop') expect(find.text('Settings'), findsOneWidget);
      });
    }
  }

  test('parseCsv handles quotes, commas and blank trailing line', () {
    final rows = parseCsv('a,b,c\n1,"x, y",3\n"he said ""hi""",,\n');
    expect(rows, [['a', 'b', 'c'], ['1', 'x, y', '3'], ['he said "hi"', '', '']]);
  });
}
