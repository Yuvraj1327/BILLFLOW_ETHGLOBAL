import 'package:billflow/features/invoices/invoice_pdf.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('line totals use exact decimal math', () {
    expect(lineTotal(LineItem(description: 'a', qty: '2', unitPrice: '10.25')), '20.5');
    expect(lineTotal(LineItem(description: 'a', qty: '0.5', unitPrice: '3')), '1.5');
    expect(lineTotal(LineItem(description: 'a', qty: 'x', unitPrice: '3')), '0');
    expect(itemsTotal([LineItem(qty: '1', unitPrice: '0.1'), LineItem(qty: '1', unitPrice: '0.2')]), '0.3'); // no float drift
  });
}
