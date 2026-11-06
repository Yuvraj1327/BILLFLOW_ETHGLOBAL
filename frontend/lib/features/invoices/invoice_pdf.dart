import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/utils/format.dart';
import '../../shared/models/models.dart';

class LineItem {
  LineItem({this.description = '', this.qty = '1', this.unitPrice = ''});
  String description, qty, unitPrice;
}

/// Client-side invoice PDF (the backend has no PDF generator). Contains only data that is on the invoice.
Future<Uint8List> buildInvoicePdf({
  required Invoice invoice,
  required String merchantName,
  required String? merchantWallet,
  List<LineItem> items = const [],
}) async {
  final doc = pw.Document(title: 'Invoice ${invoice.number}', author: merchantName);
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(40),
    build: (c) => [
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text('INVOICE', style: pw.TextStyle(fontSize: 28, fontWeight: pw.FontWeight.bold, color: PdfColors.blue800)),
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [pw.Text(invoice.number, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)), pw.Text('Status: ${invoice.status}')]),
      ]),
      pw.SizedBox(height: 24),
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [pw.Text('From', style: const pw.TextStyle(color: PdfColors.grey700)), pw.Text(merchantName, style: pw.TextStyle(fontWeight: pw.FontWeight.bold))])),
        pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [pw.Text('Bill to', style: const pw.TextStyle(color: PdfColors.grey700)), pw.Text(invoice.customerName ?? '—', style: pw.TextStyle(fontWeight: pw.FontWeight.bold))])),
        pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [pw.Text('Issued ${fmtDate(invoice.issueDate)}'), pw.Text('Due ${fmtDate(invoice.dueDate)}')])),
      ]),
      pw.SizedBox(height: 24),
      if (items.isNotEmpty)
        pw.TableHelper.fromTextArray(
          headers: ['Description', 'Qty', 'Unit price (USDT)', 'Amount (USDT)'],
          data: [for (final i in items) [i.description, i.qty, fmtAmount(i.unitPrice), fmtAmount(lineTotal(i))]],
          headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.blue800),
          cellAlignments: {1: pw.Alignment.centerRight, 2: pw.Alignment.centerRight, 3: pw.Alignment.centerRight},
        )
      else
        pw.Text(invoice.description ?? 'Services'),
      pw.SizedBox(height: 16),
      pw.Align(alignment: pw.Alignment.centerRight, child: pw.Text('Total: ${fmtUsdt(invoice.amount)}', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold))),
      pw.SizedBox(height: 24),
      pw.Text('Payable in USDT on Whitechain Sepolia via the BillFlow payment link. A payment is confirmed only after on-chain verification.', style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
      if (merchantWallet != null) pw.Text('Merchant payout wallet: $merchantWallet', style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
    ],
  ));
  return doc.save();
}

/// qty * unit price as an exact decimal string (6 dp) without floating point.
String lineTotal(LineItem i) {
  final q = toBase(i.qty.trim().isEmpty ? '0' : i.qty, 6);
  final u = toBase(i.unitPrice.trim().isEmpty ? '0' : i.unitPrice, 6);
  if (q == null || u == null) return '0';
  return fromBase((q * u) ~/ BigInt.from(1000000), 6);
}

String itemsTotal(List<LineItem> items) {
  var sum = BigInt.zero;
  for (final i in items) {
    sum += toBase(lineTotal(i), 6) ?? BigInt.zero;
  }
  return fromBase(sum, 6);
}

Future<Uint8List> buildReceiptPdf({
  required String merchantName,
  required String invoiceNumber,
  required String amount,
  required String payer,
  required String txHash,
  required String explorerUrl,
  required DateTime? confirmedAt,
}) async {
  final doc = pw.Document(title: 'Receipt $invoiceNumber');
  doc.addPage(pw.Page(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(40),
    build: (c) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Text('PAYMENT RECEIPT', style: pw.TextStyle(fontSize: 26, fontWeight: pw.FontWeight.bold, color: PdfColors.blue800)),
      pw.SizedBox(height: 6),
      pw.Text('Verified on-chain by BillFlow', style: const pw.TextStyle(color: PdfColors.green800)),
      pw.SizedBox(height: 24),
      for (final r in [
        ['Merchant', merchantName],
        ['Invoice', invoiceNumber],
        ['Amount', fmtUsdt(amount)],
        ['Payer wallet', payer],
        ['Confirmed', fmtDateTime(confirmedAt)],
        ['Network', 'Whitechain Sepolia'],
        ['Transaction', txHash],
        ['Explorer', explorerUrl],
      ])
        pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 4), child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.SizedBox(width: 110, child: pw.Text(r[0], style: const pw.TextStyle(color: PdfColors.grey700))),
          pw.Expanded(child: pw.Text(r[1], style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
        ])),
      pw.SizedBox(height: 24),
      pw.Text('Testnet payment. This receipt reflects chain data verified by the BillFlow backend at the time shown.', style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
    ]),
  ));
  return doc.save();
}
