import '../core/network/api_client.dart';
import '../shared/models/models.dart';

/// Typed wrapper over the Step 3 endpoints (paths copied from docs/BACKEND_API.md; nothing invented).
class BillflowApi {
  BillflowApi(this._c);
  final ApiClient _c;

  // ── profile / notifications ──
  Future<Profile> me() async => Profile(asJson(await _c.get('/users/me')));
  Future<Profile> updateMe(String displayName) async => Profile(asJson(await _c.patch('/users/me', data: {'display_name': displayName})));
  Future<Paged<NotificationItem>> notifications({int page = 1, bool unreadOnly = false}) async =>
      Paged.from(await _c.get('/notifications', query: {'page': page, 'page_size': 30, 'unread_only': unreadOnly}), NotificationItem.new);
  Future<void> markRead(String id) => _c.post('/notifications/$id/read');
  Future<void> markAllRead() => _c.post('/notifications/read-all');

  // ── wallet linking (EIP-191 proof of ownership) ──
  Future<Json> walletChallenge(String wallet) async => asJson(await _c.post('/auth/wallet/challenge', data: {'wallet_address': wallet}));
  Future<Profile> walletVerify(String wallet, String nonce, String signature) async =>
      Profile(asJson(await _c.post('/auth/wallet/verify', data: {'wallet_address': wallet, 'nonce': nonce, 'signature': signature})));

  // ── chain config (backend-verified addresses) ──
  Future<ChainConfig> chainConfig() async => ChainConfig(asJson(await _c.get('/blockchain/config')));

  // ── business & customers ──
  Future<Business> createBusiness(Json body) async => Business(asJson(await _c.post('/businesses', data: body)));
  Future<Business> myBusiness() async => Business(asJson(await _c.get('/businesses/me')));
  Future<Business> updateBusiness(Json body) async => Business(asJson(await _c.patch('/businesses/me', data: body)));
  Future<List<Member>> members() async => asJsonList(await _c.get('/businesses/me/members')).map(Member.new).toList();
  Future<Member> addMember(String email) async => Member(asJson(await _c.post('/businesses/me/members', data: {'email': email})));
  Future<void> removeMember(String userId) => _c.delete('/businesses/me/members/$userId');

  Future<Paged<Customer>> customers({int page = 1, String? q, bool archived = false}) async =>
      Paged.from(await _c.get('/customers', query: {'page': page, 'page_size': 50, 'q': q, 'include_archived': archived}), Customer.new);
  Future<Customer> customer(String id) async => Customer(asJson(await _c.get('/customers/$id')));
  Future<Customer> createCustomer(Json body) async => Customer(asJson(await _c.post('/customers', data: body)));
  Future<Customer> updateCustomer(String id, Json body) async => Customer(asJson(await _c.patch('/customers/$id', data: body)));
  Future<void> archiveCustomer(String id) => _c.delete('/customers/$id');

  // ── invoices ──
  Future<Paged<Invoice>> invoices({int page = 1, int pageSize = 20, String? status, String? customerId, String? q}) async =>
      Paged.from(await _c.get('/invoices', query: {'page': page, 'page_size': pageSize, 'status': status, 'customer_id': customerId, 'q': q}), Invoice.new);
  Future<Invoice> invoice(String id) async => Invoice(asJson(await _c.get('/invoices/$id')));
  Future<Invoice> createInvoice(Json body) async => Invoice(asJson(await _c.post('/invoices', data: body)));
  Future<Invoice> updateInvoice(String id, Json body) async => Invoice(asJson(await _c.patch('/invoices/$id', data: body)));
  Future<void> deleteInvoice(String id) => _c.delete('/invoices/$id');
  Future<Invoice> issueInvoice(String id) async => Invoice(asJson(await _c.post('/invoices/$id/issue')));
  Future<Invoice> cancelInvoice(String id, {String? reason}) async => Invoice(asJson(await _c.post('/invoices/$id/cancel', data: {'reason': reason})));
  Future<InvoiceDoc> uploadInvoicePdf(String id, List<int> bytes, String name) async =>
      InvoiceDoc(asJson(await _c.uploadPdf('/invoices/$id/upload', bytes, name)));
  Future<List<InvoiceDoc>> invoiceDocs(String id) async => asJsonList(await _c.get('/invoices/$id/documents')).map(InvoiceDoc.new).toList();
  Future<String> invoiceDocUrl(String id, String docId) async => asJson(await _c.get('/invoices/$id/documents/$docId/url')).str('url');
  Future<PaymentLink> createPaymentLink(String id) async => PaymentLink(asJson(await _c.post('/invoices/$id/payment-link')));
  Future<PaymentStatus> paymentStatus(String id) async => PaymentStatus(asJson(await _c.get('/invoices/$id/payment-status')));

  // ── payments ──
  Future<Paged<Payment>> payments({int page = 1, int pageSize = 20, String? invoiceId}) async =>
      Paged.from(await _c.get('/payments', query: {'page': page, 'page_size': pageSize, 'invoice_id': invoiceId}), Payment.new);
  Future<Payment> payment(String id) async => Payment(asJson(await _c.get('/payments/$id')));
  Future<TxVerification> verifyPayment(String txHash) async => TxVerification(asJson(await _c.post('/payments/verify', data: {'tx_hash': txHash})));

  // ── financing ──
  Future<Offer> submitFinancing(String invoiceId, String advance, {int? windowHours}) async => Offer(asJson(await _c.post('/financing/submit',
      data: {'invoice_id': invoiceId, 'advance': advance, if (windowHours != null) 'funding_window_hours': windowHours})));
  Future<Paged<Offer>> offers({int page = 1, String? status}) async =>
      Paged.from(await _c.get('/financing/offers', query: {'page': page, 'page_size': 30, 'status': status}), Offer.new);
  Future<Offer> offer(String id) async => Offer(asJson(await _c.get('/financing/offers/$id')));
  Future<Offer> offerForInvoice(String invoiceId) async => Offer(asJson(await _c.get('/financing/invoices/$invoiceId')));
  Future<Offer> reviewOffer(String id, Json body) async => Offer(asJson(await _c.post('/financing/offers/$id/verify', data: body)));
  Future<Offer> cancelOffer(String id) async => Offer(asJson(await _c.post('/financing/offers/$id/cancel')));
  Future<PublishPlan> publishPlan(String id) async => PublishPlan(asJson(await _c.post('/financing/offers/$id/publish')));
  Future<TxVerification> verifyFinancingTx(String txHash) async =>
      TxVerification(asJson(await _c.post('/financing/verify-transaction', data: {'tx_hash': txHash})));
  Future<Paged<Investment>> investments({int page = 1}) async =>
      Paged.from(await _c.get('/financing/investments', query: {'page': page, 'page_size': 50}), Investment.new);
  Future<Paged<Investment>> settlements({int page = 1}) async =>
      Paged.from(await _c.get('/financing/settlements', query: {'page': page, 'page_size': 50}), Investment.new);
  Future<Json> portfolio() async => asJson(await _c.get('/investors/me/portfolio'));

  // ── AI (always through FastAPI; Flutter never talks to Anthropic) ──
  Future<Extraction> extractInvoice(List<int> bytes, String name) async =>
      Extraction(asJson(await _c.uploadPdf('/ai/extract-invoice', bytes, name, receiveTimeout: const Duration(seconds: 150))));
  Future<AiNote> aiSummary(String invoiceId) async {
    final j = asJson(await _c.post('/ai/invoice-summary', data: {'invoice_id': invoiceId}, receiveTimeout: const Duration(seconds: 120)));
    return AiNote('Summary', j.str('summary'), items: [
      if (j.str('status_explanation').isNotEmpty) 'Status: ${j.str('status_explanation')}',
      ...(j['missing_fields'] as List? ?? const []).map((e) => 'Missing: $e'),
      if (j.strN('suggested_category') != null) 'Suggested category: ${j.str('suggested_category')}',
    ], notice: j.str('notice'));
  }
  Future<AiNote> aiReminder(String invoiceId, String tone) async {
    final j = asJson(await _c.post('/ai/payment-reminder', data: {'invoice_id': invoiceId, 'tone': tone}, receiveTimeout: const Duration(seconds: 120)));
    return AiNote(j.str('subject'), j.str('body'), notice: j.str('notice'));
  }
  Future<Validation> aiValidate(String invoiceId) async =>
      Validation(asJson(await _c.post('/ai/validate-invoice', data: {'invoice_id': invoiceId}, receiveTimeout: const Duration(seconds: 120))));

  // ── public checkout (no auth) ──
  Future<PublicInvoice> publicInvoice(String token) async => PublicInvoice(asJson(await _c.get('/public/invoices/$token', auth: false)));
  Future<PaymentIntent> paymentIntent(String token, String payer, {String? amount}) async => PaymentIntent(asJson(await _c.post(
      '/public/invoices/$token/payment-intent', auth: false, data: {'payer_wallet': payer, if (amount != null) 'amount': amount})));
  Future<PaymentStatus> publicStatus(String token) async => PaymentStatus(asJson(await _c.get('/public/invoices/$token/status', auth: false)));

  // ── admin ──
  Future<Json> adminList(String path, {int page = 1, Map<String, dynamic>? query}) async =>
      asJson(await _c.get('/admin/$path', query: {'page': page, 'page_size': 30, ...?query}));
  Future<Profile> adminSetRole(String userId, String role) async => Profile(asJson(await _c.patch('/admin/users/$userId/role', data: {'role': role})));
  Future<void> adminInvestorVerification(String userId, String decision) => _c.patch('/admin/users/$userId/investor-verification', data: {'decision': decision});
  Future<Paged<Business>> adminBusinesses({int page = 1, String? status}) async =>
      Paged.from(await _c.get('/admin/businesses', query: {'page': page, 'page_size': 30, 'status': status}), Business.new);
  Future<void> adminReviewBusiness(String id, String decision, {String? notes}) =>
      _c.post('/admin/businesses/$id/review', data: {'decision': decision, 'notes': notes});
  Future<void> adminReviewInvoice(String id, String decision, {String? notes}) =>
      _c.post('/admin/invoices/$id/review', data: {'decision': decision, 'notes': notes});
  Future<List<InvoiceDoc>> adminInvoiceDocs(String id) async => asJsonList(await _c.get('/admin/invoices/$id/documents')).map(InvoiceDoc.new).toList();
  Future<String> adminDocUrl(String id, String docId) async => asJson(await _c.get('/admin/invoices/$id/documents/$docId/url')).str('url');
  Future<dynamic> adminSettings() => _c.get('/admin/settings');
  Future<Json> adminIndexer() async => asJson(await _c.get('/admin/indexer'));
  Future<Json> adminRetryIndexer() async => asJson(await _c.post('/admin/indexer/retry'));
  Future<Json> chainHealth() async => asJson(await _c.get('/blockchain/health'));
}
