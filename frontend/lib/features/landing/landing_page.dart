import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_theme.dart';
import '../../core/widgets/brand_logo.dart';

/// Public marketing page (shown to signed-out visitors). Fully responsive: desktop nav + two-column hero,
/// tablet 2-column grids, mobile single column with a menu.
class LandingPage extends StatefulWidget {
  const LandingPage({super.key});
  @override
  State<LandingPage> createState() => _LandingPageState();
}

class _LandingPageState extends State<LandingPage> {
  final _scroll = ScrollController();
  final _features = GlobalKey(), _how = GlobalKey(), _benefits = GlobalKey();

  void _to(GlobalKey k) {
    final c = k.currentContext;
    if (c != null) Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 450), curve: Curves.easeOutCubic);
  }

  @override
  void dispose() { _scroll.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final desktop = w >= 960, mobile = w < 700;
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(children: [
        _NavBar(desktop: w >= 1100, onFeatures: () => _to(_features), onHow: () => _to(_how), onBenefits: () => _to(_benefits)),
        Expanded(
          child: SingleChildScrollView(
            controller: _scroll,
            child: Column(children: [
              _Hero(desktop: desktop, mobile: mobile),
              const _TrustStrip(),
              _Section(key: _features, id: 'FEATURES', title: 'Everything you need to get paid and fund growth', subtitle: 'One platform for invoicing, USDT payments, financing and reporting, with every payment verified on-chain.', child: _FeatureGrid(width: w)),
              _Section(key: _how, id: 'HOW IT WORKS', tint: true, title: 'From invoice to cash in four steps', child: _Workflow(desktop: desktop)),
              _Section(key: _benefits, id: 'BENEFITS', title: 'Built for every side of the invoice', child: _Benefits(width: w)),
              const _CtaBand(),
              const _Footer(),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _Wrap extends StatelessWidget {
  const _Wrap({required this.child, this.padding = const EdgeInsets.symmetric(horizontal: 24)});
  final Widget child;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1180), child: Padding(padding: padding, child: child)));
}

class _NavBar extends StatelessWidget {
  const _NavBar({required this.desktop, required this.onFeatures, required this.onHow, required this.onBenefits});
  final bool desktop;
  final VoidCallback onFeatures, onHow, onBenefits;
  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white,
        elevation: 0,
        child: Container(
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB)))),
          height: 68,
          child: _Wrap(
            child: Row(children: [
              const Expanded(child: Align(alignment: Alignment.centerLeft, child: BrandLockup(height: 34))),
              if (desktop) ...[
                TextButton(onPressed: onFeatures, child: const Text('Features')),
                TextButton(onPressed: onHow, child: const Text('How it works')),
                TextButton(onPressed: onBenefits, child: const Text('Benefits')),
                TextButton(onPressed: () => context.go('/pay'), child: const Text('Pay an invoice')),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: () => context.go('/login'), child: const Text('Log in')),
                const SizedBox(width: 8),
                FilledButton(onPressed: () => context.go('/register'), child: const Text('Get started')),
              ] else ...[
                TextButton(onPressed: () => context.go('/login'), child: const Text('Log in')),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.menu),
                  tooltip: 'Menu',
                  onSelected: (v) {
                    switch (v) {
                      case 'f': onFeatures();
                      case 'h': onHow();
                      case 'b': onBenefits();
                      default: context.go(v);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'f', child: Text('Features')),
                    PopupMenuItem(value: 'h', child: Text('How it works')),
                    PopupMenuItem(value: 'b', child: Text('Benefits')),
                    PopupMenuItem(value: '/pay', child: Text('Pay an invoice')),
                    PopupMenuItem(value: '/register', child: Text('Get started')),
                    PopupMenuItem(value: '/admin-login', child: Text('Admin sign in')),
                  ],
                ),
              ],
            ]),
          ),
        ),
      );
}

class _Hero extends StatelessWidget {
  const _Hero({required this.desktop, required this.mobile});
  final bool desktop, mobile;
  @override
  Widget build(BuildContext context) {
    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: .12), borderRadius: BorderRadius.circular(30), border: Border.all(color: Colors.white24)),
        child: const Text('USDT payments · Invoice financing · AI insights', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12.5)),
      ),
      const SizedBox(height: 20),
      Text('Get paid in USDT.\nFinance your unpaid invoices.',
          style: TextStyle(color: Colors.white, fontSize: mobile ? 34 : (desktop ? 54 : 44), fontWeight: FontWeight.w900, height: 1.08, letterSpacing: -1)),
      const SizedBox(height: 18),
      Text('NEXA BILLFLOW lets businesses invoice customers, collect on-chain payments through a simple link, and unlock cash from unpaid invoices through a marketplace of investors.',
          style: TextStyle(color: Colors.white.withValues(alpha: .86), fontSize: mobile ? 16 : 18, height: 1.5)),
      const SizedBox(height: 28),
      Wrap(spacing: 12, runSpacing: 12, children: [
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: Tokens.teal, foregroundColor: Colors.white, minimumSize: const Size(0, 52), padding: const EdgeInsets.symmetric(horizontal: 26)),
          onPressed: () => context.go('/register'), icon: const Icon(Icons.rocket_launch_outlined), label: const Text('Create free account')),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white54), minimumSize: const Size(0, 52), padding: const EdgeInsets.symmetric(horizontal: 26)),
          onPressed: () => context.go('/pay'), icon: const Icon(Icons.payments_outlined), label: const Text('Pay an invoice')),
      ]),
      const SizedBox(height: 14),
      Text('No account needed to pay an invoice.', style: TextStyle(color: Colors.white.withValues(alpha: .7), fontSize: 13)),
    ]);
    return Container(
      decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Tokens.blueDeep, Tokens.blue, Color(0xFF01575F)])),
      child: _Wrap(
        padding: EdgeInsets.symmetric(horizontal: 24, vertical: mobile ? 44 : 84),
        child: desktop
            ? Row(crossAxisAlignment: CrossAxisAlignment.center, children: [Expanded(flex: 6, child: text), const SizedBox(width: 56), const Expanded(flex: 5, child: _InvoicePreview())])
            : Column(children: [text, const SizedBox(height: 36), const _InvoicePreview()]),
      ),
    );
  }
}

/// Illustration of the product (static artwork, labelled as an example).
class _InvoicePreview extends StatelessWidget {
  const _InvoicePreview();
  @override
  Widget build(BuildContext context) {
    Widget row(String a, String b, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [Text(a, style: const TextStyle(color: Tokens.slate)), const SizedBox(width: 12), Expanded(child: Text(b, textAlign: TextAlign.right, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w600, color: Tokens.ink)))]),
        );
    return Container(
      constraints: const BoxConstraints(maxWidth: 460),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22), boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 40, offset: Offset(0, 20))]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const BillflowLogo(height: 30),
          const SizedBox(width: 10),
          const Expanded(child: Text('Invoice INV-2041', overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w800, color: Tokens.ink, fontSize: 16))),
          const SizedBox(width: 8),
          Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: Tokens.success.withValues(alpha: .12), borderRadius: BorderRadius.circular(20)),
              child: const Text('PAID', style: TextStyle(color: Tokens.success, fontWeight: FontWeight.w800, fontSize: 12))),
        ]),
        const Divider(height: 28),
        row('Customer', 'Acme Ltd'),
        row('Due', '30 Nov'),
        row('Network', 'Whitechain Sepolia'),
        const Divider(height: 28),
        row('Amount', '1,200.00 USDT', bold: true),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Tokens.teal.withValues(alpha: .1), borderRadius: BorderRadius.circular(12)),
          child: const Row(children: [Icon(Icons.verified, color: Tokens.tealDeep, size: 20), SizedBox(width: 10), Expanded(child: Text('Verified on-chain', style: TextStyle(color: Tokens.tealDeep, fontWeight: FontWeight.w700)))]),
        ),
        const SizedBox(height: 10),
        const Text('Illustration', style: TextStyle(fontSize: 11, color: Tokens.slate)),
      ]),
    );
  }
}

class _TrustStrip extends StatelessWidget {
  const _TrustStrip();
  @override
  Widget build(BuildContext context) {
    const items = [(Icons.link, 'Whitechain Sepolia'), (Icons.attach_money, 'USDT payments'), (Icons.verified_user_outlined, 'Verified on-chain'), (Icons.auto_awesome_outlined, 'AI-assisted')];
    return Container(
      color: const Color(0xFFF4F6F8),
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: _Wrap(child: Wrap(alignment: WrapAlignment.center, spacing: 36, runSpacing: 12, children: [
        for (final i in items) Row(mainAxisSize: MainAxisSize.min, children: [Icon(i.$1, size: 18, color: Tokens.blue), const SizedBox(width: 8), Text(i.$2, style: const TextStyle(fontWeight: FontWeight.w700, color: Tokens.ink))]),
      ])),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({super.key, required this.id, required this.title, required this.child, this.subtitle, this.tint = false});
  final String id, title;
  final String? subtitle;
  final Widget child;
  final bool tint;
  @override
  Widget build(BuildContext context) {
    final mobile = MediaQuery.sizeOf(context).width < 700;
    return Container(
      color: tint ? const Color(0xFFF4F6F8) : Colors.white,
      child: _Wrap(
        padding: EdgeInsets.symmetric(horizontal: 24, vertical: mobile ? 48 : 84),
        child: Column(children: [
          Text(id, style: const TextStyle(color: Tokens.teal, fontWeight: FontWeight.w800, letterSpacing: 1.6, fontSize: 12.5)),
          const SizedBox(height: 12),
          ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: mobile ? 26 : 38, fontWeight: FontWeight.w900, height: 1.15, letterSpacing: -.6, color: Tokens.ink))),
          if (subtitle != null) ...[
            const SizedBox(height: 14),
            ConstrainedBox(constraints: const BoxConstraints(maxWidth: 680), child: Text(subtitle!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 17, height: 1.5, color: Tokens.slate))),
          ],
          SizedBox(height: mobile ? 28 : 48),
          child,
        ]),
      ),
    );
  }
}

int _cols(double w) => w >= 960 ? 3 : (w >= 640 ? 2 : 1);

class _Cards extends StatelessWidget {
  const _Cards({required this.width, required this.children});
  final double width;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (c, box) {
        final cols = _cols(width);
        final w = (box.maxWidth - (cols - 1) * 20) / cols;
        return Wrap(spacing: 20, runSpacing: 20, children: [for (final x in children) SizedBox(width: w, child: x)]);
      });
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard(this.icon, this.title, this.body);
  final IconData icon;
  final String title, body;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFFE5E7EB))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(gradient: const LinearGradient(colors: [Tokens.blue, Tokens.teal]), borderRadius: BorderRadius.circular(14)), child: Icon(icon, color: Colors.white, size: 24)),
          const SizedBox(height: 18),
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Tokens.ink)),
          const SizedBox(height: 8),
          Text(body, style: const TextStyle(color: Tokens.slate, height: 1.5, fontSize: 15)),
        ]),
      );
}

class _FeatureGrid extends StatelessWidget {
  const _FeatureGrid({required this.width});
  final double width;
  @override
  Widget build(BuildContext context) => _Cards(width: width, children: const [
        _FeatureCard(Icons.receipt_long_outlined, 'Invoice management', 'Create, edit, issue and track invoices and customers. Upload PDFs and keep every status in one place.'),
        _FeatureCard(Icons.link, 'Payment links', 'Share a link. Your customer pays from their own wallet with no account and no sign-up.'),
        _FeatureCard(Icons.currency_exchange, 'USDT checkout on Whitechain', 'Stablecoin payments are confirmed on-chain, and a payment counts only after the backend verifies it.'),
        _FeatureCard(Icons.account_balance_outlined, 'Invoice financing', 'Request an advance on unpaid invoices. Approved offers are listed on-chain for investors to fund.'),
        _FeatureCard(Icons.storefront_outlined, 'Investor marketplace', 'Verified investors browse offers, fund invoices and follow their portfolio and settlements.'),
        _FeatureCard(Icons.auto_awesome_outlined, 'AI invoice analysis', 'Claude extracts invoice data from PDFs, validates it and drafts reminders. Advisory only: you decide.'),
        _FeatureCard(Icons.notifications_none, 'Notifications & history', 'Stay informed on payments, reviews and offers, with a transaction history linked to the explorer.'),
        _FeatureCard(Icons.insert_chart_outlined, 'Reports & export', 'Filter by date and export verified payments and refunds as CSV for your accountant.'),
        _FeatureCard(Icons.admin_panel_settings_outlined, 'Role-based security', 'Merchants, investors and admins each see only what they should, enforced by the backend.'),
      ]);
}

class _Workflow extends StatelessWidget {
  const _Workflow({required this.desktop});
  final bool desktop;
  @override
  Widget build(BuildContext context) {
    const steps = [
      (Icons.edit_note, 'Create an invoice', 'Add a customer and amount, or let AI read your PDF.'),
      (Icons.share_outlined, 'Share the payment link', 'Send one link. No login needed for your customer.'),
      (Icons.account_balance_wallet_outlined, 'Customer pays in USDT', 'They connect a wallet and confirm the transaction on Whitechain.'),
      (Icons.verified_outlined, 'Verified & settled', 'The payment is verified on-chain, or finance the invoice early for instant cash.'),
    ];
    Widget step(int i) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(radius: 22, backgroundColor: Tokens.blue, child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 17))),
            const SizedBox(width: 12),
            Icon(steps[i].$1, color: Tokens.teal, size: 26),
          ]),
          const SizedBox(height: 16),
          Text(steps[i].$2, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Tokens.ink)),
          const SizedBox(height: 6),
          Text(steps[i].$3, style: const TextStyle(color: Tokens.slate, height: 1.5, fontSize: 15)),
        ]);
    return desktop
        ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [for (var i = 0; i < steps.length; i++) ...[Expanded(child: step(i)), if (i < steps.length - 1) const SizedBox(width: 28)]])
        : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [for (var i = 0; i < steps.length; i++) Padding(padding: const EdgeInsets.only(bottom: 28), child: step(i))]);
  }
}

class _Benefits extends StatelessWidget {
  const _Benefits({required this.width});
  final double width;
  Widget _card(IconData icon, String title, List<String> points) => Container(
        padding: const EdgeInsets.all(26),
        decoration: BoxDecoration(color: Tokens.ink, borderRadius: BorderRadius.circular(22)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: const Color(0xFF2CC4B7), size: 30),
          const SizedBox(height: 14),
          Text(title, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          for (final p in points)
            Padding(padding: const EdgeInsets.only(bottom: 10), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.check_circle, size: 18, color: Color(0xFF2CC4B7)), const SizedBox(width: 10), Expanded(child: Text(p, style: const TextStyle(color: Colors.white70, height: 1.4))),
            ])),
        ]),
      );
  @override
  Widget build(BuildContext context) => _Cards(width: width, children: [
        _card(Icons.storefront_outlined, 'Merchants', ['Get paid faster with payment links', 'Unlock cash from unpaid invoices', 'Clean reports for your accountant']),
        _card(Icons.trending_up, 'Investors', ['Browse verified invoice offers', 'Fund on-chain with full transparency', 'Track portfolio and settlements']),
        _card(Icons.person_outline, 'Customers', ['Pay from your own wallet', 'No account or sign-up', 'Get a verified receipt']),
      ]);
}

class _CtaBand extends StatelessWidget {
  const _CtaBand();
  @override
  Widget build(BuildContext context) {
    final mobile = MediaQuery.sizeOf(context).width < 700;
    return Container(
      decoration: const BoxDecoration(gradient: LinearGradient(colors: [Tokens.blueDeep, Tokens.blue, Tokens.tealDeep])),
      child: _Wrap(
        padding: EdgeInsets.symmetric(horizontal: 24, vertical: mobile ? 44 : 72),
        child: Column(children: [
          Text('Ready to move your invoices on-chain?', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: mobile ? 26 : 38, fontWeight: FontWeight.w900, letterSpacing: -.5)),
          const SizedBox(height: 12),
          const Text('Create a merchant or investor account in under a minute.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, fontSize: 17)),
          const SizedBox(height: 26),
          Wrap(alignment: WrapAlignment.center, spacing: 12, runSpacing: 12, children: [
            FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Tokens.blue, minimumSize: const Size(0, 52), padding: const EdgeInsets.symmetric(horizontal: 30)), onPressed: () => context.go('/register'), child: const Text('Get started')),
            OutlinedButton(style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white54), minimumSize: const Size(0, 52), padding: const EdgeInsets.symmetric(horizontal: 30)), onPressed: () => context.go('/login'), child: const Text('Log in')),
          ]),
        ]),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer();
  @override
  Widget build(BuildContext context) {
    final mobile = MediaQuery.sizeOf(context).width < 960; // stacked below desktop width
    Widget link(String t, String path) => TextButton(onPressed: () => context.go(path), style: TextButton.styleFrom(foregroundColor: Colors.white70, padding: EdgeInsets.zero, minimumSize: const Size(0, 32), alignment: Alignment.centerLeft), child: Text(t));
    final brand = Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
      BrandLockup(height: 32, onDark: true),
      SizedBox(height: 12),
      SizedBox(width: 320, child: Text('USDT invoice payments and invoice financing on Whitechain Sepolia.', style: TextStyle(color: Colors.white60, height: 1.5))),
    ]);
    final links = Wrap(spacing: 48, runSpacing: 20, children: [
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Product', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)), const SizedBox(height: 8), link('Create account', '/register'), link('Log in', '/login'), link('Pay an invoice', '/pay')]),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Access', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)), const SizedBox(height: 8), link('Merchant & investor login', '/login'), link('Admin sign in', '/admin-login')]),
    ]);
    return Container(
      color: Tokens.ink,
      child: _Wrap(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          mobile ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [brand, const SizedBox(height: 28), links]) : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [brand, const Spacer(), links]),
          const Divider(height: 48, color: Colors.white12),
          const Text('Testnet demo. Illustrative terms only; nothing here is a guaranteed return. Financing carries credit risk.', style: TextStyle(color: Colors.white54, fontSize: 12.5)),
          const SizedBox(height: 6),
          const Text('© NEXA BILLFLOW', style: TextStyle(color: Colors.white38, fontSize: 12.5)),
        ]),
      ),
    );
  }
}
