import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/utils/file_download.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/widgets.dart';

/// Parses RFC-4180-ish CSV (quoted cells, doubled quotes, embedded commas/newlines) into rows.
List<List<String>> parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[], cell = StringBuffer(), quoted = false;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') { cell.write('"'); i++; } else { quoted = false; }
      } else { cell.write(ch); }
    } else if (ch == '"') { quoted = true; }
    else if (ch == ',') { row.add(cell.toString()); cell = StringBuffer(); }
    else if (ch == '\n') { row.add(cell.toString()); cell = StringBuffer(); rows.add(row); row = <String>[]; }
    else if (ch != '\r') { cell.write(ch); }
  }
  if (cell.isNotEmpty || row.isNotEmpty) { row.add(cell.toString()); rows.add(row); }
  return rows;
}

class _Range {
  const _Range(this.from, this.to);
  final DateTime? from, to;
  @override
  bool operator ==(Object o) => o is _Range && o.from == from && o.to == to;
  @override
  int get hashCode => Object.hash(from, to);
}

final _rangeProvider = StateProvider<_Range>((ref) => const _Range(null, null));
final _reportProvider = FutureProvider.autoDispose<String>((ref) {
  final r = ref.watch(_rangeProvider);
  final f = DateFormat('yyyy-MM-dd');
  return ref.watch(apiProvider).paymentsCsv(from: r.from == null ? null : f.format(r.from!), to: r.to == null ? null : f.format(r.to!));
});

class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  Future<void> _pick(BuildContext context, WidgetRef ref, bool from) async {
    final r = ref.read(_rangeProvider);
    final d = await showDatePicker(context: context, initialDate: (from ? r.from : r.to) ?? DateTime.now(), firstDate: DateTime(2024), lastDate: DateTime.now().add(const Duration(days: 1)));
    if (d != null) ref.read(_rangeProvider.notifier).state = from ? _Range(d, r.to) : _Range(r.from, d);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final range = ref.watch(_rangeProvider);
    final report = ref.watch(_reportProvider);
    final df = DateFormat.yMMMd();
    return SingleChildScrollView(
      child: ResponsiveBody(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          PageHeader('Reports', subtitle: 'Verified on-chain payments and refunds, ready for your accountant.', actions: [
            OutlinedButton.icon(onPressed: () => _pick(context, ref, true), icon: const Icon(Icons.event), label: Text(range.from == null ? 'From' : df.format(range.from!))),
            OutlinedButton.icon(onPressed: () => _pick(context, ref, false), icon: const Icon(Icons.event), label: Text(range.to == null ? 'To' : df.format(range.to!))),
            if (range.from != null || range.to != null) TextButton(onPressed: () => ref.read(_rangeProvider.notifier).state = const _Range(null, null), child: const Text('Clear')),
            FilledButton.icon(
              onPressed: report.hasValue
                  ? () async {
                      final csv = report.value!;
                      if (!downloadTextFile('nexa-billflow-payments.csv', csv)) await copyText(context, csv, 'CSV copied to clipboard');
                    }
                  : null,
              icon: const Icon(Icons.download),
              label: const Text('Export CSV'),
            ),
          ]),
          AsyncView<String>(
            value: report,
            onRetry: () => ref.invalidate(_reportProvider),
            builder: (csv) {
              final rows = parseCsv(csv);
              if (rows.length < 2) {
                return const AppCard(child: EmptyState(icon: Icons.insert_chart_outlined, title: 'No verified payments in this period', message: 'Payments and refunds appear here once they are confirmed on-chain.'));
              }
              final head = rows.first, data = rows.skip(1).where((r) => r.length >= head.length).toList();
              int col(String n) => head.indexOf(n);
              // Exact sums with no decimals assumption: parse the backend's formatted `amount` into a scale-18 integer.
              const scale = 18;
              BigInt scaled(String v) {
                final neg = v.startsWith('-');
                final parts = v.replaceFirst('-', '').split('.');
                final frac = (parts.length > 1 ? parts[1] : '').padRight(scale, '0').substring(0, scale);
                final n = BigInt.tryParse('${parts[0].isEmpty ? '0' : parts[0]}$frac') ?? BigInt.zero;
                return neg ? -n : n;
              }
              var received = BigInt.zero, refunded = BigInt.zero, n = 0;
              for (final r in data) {
                final base = scaled(r[col('amount')]);
                if (r[col('type')] == 'refund') { refunded += -base; } else { received += base; n++; }
              }
              const dec = scale;
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                StatGrid([
                  StatTile(label: 'Received', value: fmtUsdt(fromBase(received, dec)), icon: Icons.south_west, color: Colors.green),
                  StatTile(label: 'Refunded', value: fmtUsdt(fromBase(refunded, dec)), icon: Icons.undo, color: Colors.orange),
                  StatTile(label: 'Net', value: fmtUsdt(fromBase(received - refunded, dec)), icon: Icons.account_balance_wallet_outlined),
                  StatTile(label: 'Payments', value: '$n', sub: '${data.length - n} refunds', icon: Icons.receipt_long_outlined),
                ]),
                const SectionTitle('Transactions'),
                AppCard(
                  padding: EdgeInsets.zero,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columns: const [DataColumn(label: Text('TYPE')), DataColumn(label: Text('INVOICE')), DataColumn(label: Text('DATE (UTC)')), DataColumn(label: Text('PAYER')), DataColumn(label: Text('AMOUNT (USDT)'), numeric: true), DataColumn(label: Text('TX'))],
                      rows: [
                        for (final r in data)
                          DataRow(cells: [
                            DataCell(StatusChip(r[col('type')] == 'refund' ? 'CANCELLED' : 'CONFIRMED', label: titleCase(r[col('type')]))),
                            DataCell(Text(r[col('invoice_number')])),
                            DataCell(Text(r[col('confirmed_at_utc')].split('T').first)),
                            DataCell(Text(shortAddr(r[col('counterparty_wallet')]))),
                            DataCell(Text(r[col('amount')], style: const TextStyle(fontWeight: FontWeight.w700))),
                            DataCell(r[col('tx_hash')].isEmpty ? const Text('—') : TxLink(r[col('tx_hash')], url: r[col('explorer_url')].isEmpty ? null : r[col('explorer_url')])),
                          ]),
                      ],
                    ),
                  ),
                ),
              ]);
            },
          ),
        ]),
      ),
    );
  }
}
