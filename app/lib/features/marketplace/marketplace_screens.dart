import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/widgets/widgets.dart';
import '../../shared/models/models.dart';
import '../../shared/widgets/paged_list.dart';
import '../financing/financing_screens.dart';

/// Investor marketplace: approved offers that are open for funding. Data comes only from GET /financing/offers.
class MarketplaceScreen extends ConsumerStatefulWidget {
  const MarketplaceScreen({super.key});
  @override
  ConsumerState<MarketplaceScreen> createState() => _S();
}

class _S extends ConsumerState<MarketplaceScreen> {
  String? _status = 'LISTED';
  int _token = 0;

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(authProvider).valueOrNull;
    return ResponsiveBody(
      padding: EdgeInsets.zero,
      child: PagedList<Offer>(
        reloadToken: _token,
        load: (p) => ref.read(apiProvider).offers(page: p, status: _status),
        header: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const InfoBanner('Invoice financing carries credit risk. Discounts are not guaranteed returns: the debtor may pay late or not at all and you can lose funds. Read each disclosure before funding.', tone: BannerTone.warn, icon: Icons.gpp_maybe_outlined),
          if (profile != null && profile.investorVerification != 'verified')
            Padding(padding: const EdgeInsets.only(top: 8), child: InfoBanner('Investor status: ${profile.investorVerification}. Funding may be restricted until an admin verifies your profile.')),
          const SizedBox(height: 10),
          Wrap(spacing: 8, children: [
            ChoiceChip(label: const Text('Open for funding'), selected: _status == 'LISTED', onSelected: (_) => setState(() { _status = 'LISTED'; _token++; })),
            ChoiceChip(label: const Text('Funded'), selected: _status == 'FUNDED', onSelected: (_) => setState(() { _status = 'FUNDED'; _token++; })),
            ChoiceChip(label: const Text('Settled'), selected: _status == 'SETTLED', onSelected: (_) => setState(() { _status = 'SETTLED'; _token++; })),
          ]),
          const SizedBox(height: 12),
        ]),
        empty: const EmptyState(icon: Icons.storefront_outlined, title: 'No offers here right now', message: 'Offers appear once BillFlow has approved them and they are listed on-chain.'),
        itemBuilder: (c, o) => OfferCard(o, onTap: () => c.push('/investor/offers/${o.id}')),
      ),
    );
  }
}
