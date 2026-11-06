import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';

import '../../app/providers.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/format.dart';
import '../../core/utils/validators.dart' as v;
import '../../core/widgets/widgets.dart';
import '../../shared/models/models.dart';
import 'invoice_pdf.dart';

/// Create or edit a DRAFT invoice. Line items are a client-side composer: the backend stores one amount + one description,
/// so the total becomes `amount` and the lines are written into `description`.
class InvoiceFormScreen extends ConsumerStatefulWidget {
  const InvoiceFormScreen({super.key, this.editId, this.customerId});
  final String? editId, customerId;
  @override
  ConsumerState<InvoiceFormScreen> createState() => _S();
}

class _Line {
  final desc = TextEditingController();
  final qty = TextEditingController(text: '1');
  final price = TextEditingController();
  void dispose() {
    desc.dispose();
    qty.dispose();
    price.dispose();
  }
  LineItem get item => LineItem(description: desc.text.trim(), qty: qty.text.trim(), unitPrice: price.text.trim());
}

class _S extends ConsumerState<InvoiceFormScreen> {
  final _form = GlobalKey<FormState>();
  final _number = TextEditingController();
  final _notes = TextEditingController();
  final _directAmount = TextEditingController();
  final List<_Line> _lines = [_Line()];
  bool _useLines = true;
  String? _customerId;
  DateTime _issue = DateTime.now();
  DateTime _due = DateTime.now().add(const Duration(days: 30));
  List<Customer> _customers = [];
  bool _loading = true, _busy = false;
  Object? _loadError;
  Extraction? _extraction;

  @override
  void initState() {
    super.initState();
    _customerId = widget.customerId;
    _load();
  }

  @override
  void dispose() {
    _number.dispose();
    _notes.dispose();
    _directAmount.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final api = ref.read(apiProvider);
      _customers = (await api.customers(page: 1)).items;
      if (widget.editId == null) {
        // Suggested number = count + 1. Editable; the backend enforces uniqueness and returns a clear error on a clash.
        final total = (await api.invoices(page: 1, pageSize: 1)).total;
        _number.text = 'INV-${DateTime.now().year}-${(total + 1).toString().padLeft(3, '0')}';
      }
      if (widget.editId != null) {
        final inv = await api.invoice(widget.editId!);
        if (!inv.isDraft) throw AppException('not_draft', 'Only DRAFT invoices can be edited.');
        _number.text = inv.number;
        _notes.text = inv.description ?? '';
        _directAmount.text = inv.amount;
        _useLines = false;
        _customerId = inv.customerId;
        _issue = inv.issueDate ?? _issue;
        _due = inv.dueDate ?? _due;
        if (!_customers.any((c) => c.id == inv.customerId)) _customers = [..._customers, Customer({'id': inv.customerId, 'name': inv.customerName ?? 'Customer'})];
      }
    } catch (e) {
      _loadError = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  String get _total => _useLines ? itemsTotal([for (final l in _lines) l.item]) : _directAmount.text.trim();

  String _composeDescription() {
    final extra = _notes.text.trim();
    if (!_useLines) return extra;
    final parts = <String>[
      for (final l in _lines)
        if (l.item.description.isNotEmpty) '${l.item.description} — ${l.item.qty} × ${fmtAmount(l.item.unitPrice)} = ${fmtAmount(lineTotal(l.item))} USDT',
    ];
    final s = [...parts, if (extra.isNotEmpty) extra].join('\n');
    return s.length > 2000 ? s.substring(0, 2000) : s;
  }

  Future<void> _pickDate(bool due) async {
    final d = await showDatePicker(context: context, initialDate: due ? _due : _issue, firstDate: DateTime(2020), lastDate: DateTime(2100));
    if (d != null) setState(() => due ? _due = d : _issue = d);
  }

  /// PDF → AI extraction (through FastAPI). Fields are only PREFILLED here; the user reviews and edits everything before saving.
  Future<void> _extract() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['pdf'], withData: true);
    final f = res?.files.single;
    if (f == null || f.bytes == null) return;
    setState(() => _busy = true);
    try {
      final ex = await ref.read(apiProvider).extractInvoice(f.bytes!, f.name);
      final x = ex.fields;
      setState(() {
        _extraction = ex;
        if ((x['invoice_number'] ?? '') != '') _number.text = '${x['invoice_number']}';
        if ((x['amount'] ?? '') != '') {
          _useLines = false;
          _directAmount.text = '${x['amount']}';
        }
        if ((x['description'] ?? '') != '') _notes.text = '${x['description']}';
        final due = DateTime.tryParse('${x['due_date'] ?? ''}');
        if (due != null) _due = due;
        final iss = DateTime.tryParse('${x['issue_date'] ?? ''}');
        if (iss != null) _issue = iss;
        final name = '${x['customer_name'] ?? ''}'.toLowerCase();
        if (name.isNotEmpty) {
          final m = _customers.where((c) => c.name.toLowerCase() == name);
          if (m.isNotEmpty) _customerId = m.first.id;
        }
      });
      if (mounted) toast(context, 'Fields extracted. Review every field before saving.');
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _save({required bool issue}) async {
    if (!_form.currentState!.validate()) return;
    if (_customerId == null) {
      toast(context, 'Choose a customer', error: true);
      return;
    }
    if (!_due.isAfter(DateTime(_issue.year, _issue.month, _issue.day).subtract(const Duration(days: 1)))) {
      toast(context, 'Due date cannot be before the issue date', error: true);
      return;
    }
    final total = _total;
    if (v.positiveDecimal(total) != null) {
      toast(context, 'Invoice total must be greater than 0', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final api = ref.read(apiProvider);
      final fmt = DateFormat('yyyy-MM-dd');
      final body = <String, dynamic>{
        'customer_id': _customerId,
        'invoice_number': _number.text.trim(),
        'description': _composeDescription().isEmpty ? null : _composeDescription(),
        'amount': total,
        'issue_date': fmt.format(_issue),
        'due_date': fmt.format(_due),
      };
      final Invoice inv;
      if (widget.editId == null) {
        inv = await api.createInvoice({...body, 'issue': issue});
      } else {
        inv = await api.updateInvoice(widget.editId!, body);
        if (issue) await api.issueInvoice(inv.id);
      }
      if (mounted) {
        toast(context, issue ? 'Invoice issued' : 'Draft saved');
        context.go('/merchant/invoices/${inv.id}');
      }
    } catch (e) {
      if (mounted) toast(context, errorText(e), error: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _previewPdf() async {
    final profile = ref.read(authProvider).valueOrNull;
    final cust = _customers.where((c) => c.id == _customerId);
    final draft = Invoice({
      'id': widget.editId ?? 'preview',
      'customer_id': _customerId ?? '',
      'customer_name': cust.isEmpty ? null : cust.first.name,
      'invoice_number': _number.text.trim().isEmpty ? '(number)' : _number.text.trim(),
      'description': _composeDescription(),
      'amount': _total,
      'amount_base': '0',
      'currency': 'USDT',
      'issue_date': DateFormat('yyyy-MM-dd').format(_issue),
      'due_date': DateFormat('yyyy-MM-dd').format(_due),
      'status': 'DRAFT',
    });
    String merchant = profile?.label ?? 'Merchant';
    String? wallet;
    try {
      final b = await ref.read(apiProvider).myBusiness();
      merchant = b.legalName;
      wallet = b.payoutWallet;
    } catch (_) {}
    final bytes = await buildInvoicePdf(invoice: draft, merchantName: merchant, merchantWallet: wallet, items: _useLines ? [for (final l in _lines) l.item] : const []);
    if (mounted) await Printing.layoutPdf(onLayout: (_) async => bytes, name: 'invoice-${draft.number}.pdf');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) return ErrorState(_loadError!, onRetry: () => setState(() { _loading = true; _loadError = null; _load(); }));
    final editing = widget.editId != null;
    return SingleChildScrollView(
      child: ResponsiveBody(
        maxWidth: 760,
        child: Form(
          key: _form,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(editing ? 'Edit draft invoice' : 'New invoice', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            AppCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Have a PDF invoice already?', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                const Text('Claude can pre-fill the fields. You review and edit everything before anything is saved. AI extraction is not legal verification.'),
                const SizedBox(height: 10),
                BusyButton(label: 'Extract from PDF with AI', icon: Icons.auto_awesome, outlined: true, busy: _busy, onPressed: _extract),
                if (_extraction != null) ...[
                  const SizedBox(height: 10),
                  InfoBanner('Confidence ${(_extraction!.confidence * 100).toStringAsFixed(0)}%. ${_extraction!.notice}', tone: _extraction!.confidence < 0.7 ? BannerTone.warn : BannerTone.info, icon: Icons.auto_awesome),
                  for (final w in [..._extraction!.warnings, ..._extraction!.duplicateWarnings]) Padding(padding: const EdgeInsets.only(top: 6), child: InfoBanner(w, tone: BannerTone.warn)),
                ],
              ]),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _customerId,
              decoration: const InputDecoration(labelText: 'Customer *'),
              items: [for (final c in _customers) DropdownMenuItem(value: c.id, child: Text(c.name))],
              onChanged: (x) => setState(() => _customerId = x),
              validator: (x) => x == null ? 'Choose a customer' : null,
            ),
            if (_customers.isEmpty) Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: () => context.push('/merchant/customers'), child: const Text('No customers yet — add one'))),
            const SizedBox(height: 12),
            TextFormField(controller: _number, decoration: InputDecoration(labelText: 'Invoice number *', helperText: editing ? null : 'Suggested automatically; you can change it'), validator: (x) => v.required(x, 'Invoice number')),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: OutlinedButton.icon(onPressed: () => _pickDate(false), icon: const Icon(Icons.event), label: Text('Issued ${fmtDate(_issue)}'))),
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton.icon(onPressed: () => _pickDate(true), icon: const Icon(Icons.event_available), label: Text('Due ${fmtDate(_due)}'))),
            ]),
            SectionTitle('Amount', trailing: SegmentedButton<bool>(
              segments: const [ButtonSegment(value: true, label: Text('Line items')), ButtonSegment(value: false, label: Text('Single amount'))],
              selected: {_useLines},
              onSelectionChanged: (s) => setState(() => _useLines = s.first),
            )),
            if (_useLines) ...[
              for (var i = 0; i < _lines.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: AppCard(
                    child: Column(children: [
                      TextFormField(controller: _lines[i].desc, decoration: InputDecoration(labelText: 'Item ${i + 1} description'), validator: (x) => v.required(x, 'Description'), onChanged: (_) => setState(() {})),
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(child: TextFormField(controller: _lines[i].qty, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Qty'), validator: (x) => v.positiveDecimal(x, label: 'Qty'), onChanged: (_) => setState(() {}))),
                        const SizedBox(width: 8),
                        Expanded(child: TextFormField(controller: _lines[i].price, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Unit price (USDT)'), validator: (x) => v.positiveDecimal(x, label: 'Price'), onChanged: (_) => setState(() {}))),
                        const SizedBox(width: 8),
                        SizedBox(width: 90, child: Text(fmtAmount(lineTotal(_lines[i].item)), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700))),
                        IconButton(
                          tooltip: 'Remove line',
                          onPressed: _lines.length == 1 ? null : () => setState(() => _lines.removeAt(i).dispose()),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ]),
                    ]),
                  ),
                ),
              Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: () => setState(() => _lines.add(_Line())), icon: const Icon(Icons.add), label: const Text('Add line'))),
            ] else
              TextFormField(controller: _directAmount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Amount (USDT) *'), validator: v.positiveDecimal, onChanged: (_) => setState(() {})),
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerRight, child: Text('Total  ${fmtUsdt(_total.isEmpty ? '0' : _total)}', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800))),
            const SizedBox(height: 8),
            TextFormField(controller: _notes, maxLines: 3, maxLength: 1500, decoration: const InputDecoration(labelText: 'Notes / description')),
            const SizedBox(height: 8),
            Wrap(spacing: 10, runSpacing: 10, children: [
              BusyButton(label: 'Save draft', busy: _busy, outlined: true, onPressed: () => _save(issue: false)),
              BusyButton(label: 'Issue invoice', busy: _busy, onPressed: () => _save(issue: true)),
              OutlinedButton.icon(onPressed: _previewPdf, icon: const Icon(Icons.picture_as_pdf_outlined), label: const Text('Preview PDF')),
            ]),
            const SizedBox(height: 8),
            Text('The invoice number is suggested automatically and must be unique per business. Issued invoices can no longer be edited, only cancelled.', style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12)),
          ]),
        ),
      ),
    );
  }
}
