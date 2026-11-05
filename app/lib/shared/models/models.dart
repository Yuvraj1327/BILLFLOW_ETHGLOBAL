import 'json_helpers.dart';
export 'json_helpers.dart';

/// Hand-written models mirroring the Step 3 Pydantic response schemas (no code generation needed).
/// Money is carried as the backend's decimal strings plus base-unit strings; never as doubles.

class Paged<T> {
  Paged(this.items, this.page, this.pageSize, this.total);
  final List<T> items;
  final int page, pageSize, total;
  bool get hasMore => page * pageSize < total;
  factory Paged.from(dynamic json, T Function(Json) f) {
    final j = asJson(json);
    return Paged((j['items'] as List).map((e) => f(asJson(e))).toList(), j.integer('page'), j.integer('page_size'), j.integer('total'));
  }
}

class Profile {
  Profile(Json j)
      : id = j.str('id'),
        email = j.strN('email'),
        role = j.str('role'),
        displayName = j.strN('display_name'),
        walletAddress = j.strN('wallet_address'),
        investorVerification = j.str('investor_verification'),
        businessId = j.strN('business_id'),
        createdAt = j.date('created_at');
  final String id, role, investorVerification;
  final String? email, displayName, walletAddress, businessId;
  final DateTime? createdAt;
  bool get isMerchant => role == 'merchant';
  bool get isInvestor => role == 'investor';
  bool get isAdmin => role == 'admin';
  String get label => (displayName?.isNotEmpty ?? false) ? displayName! : (email ?? 'Account');
}

class Business {
  Business(Json j)
      : id = j.str('id'),
        legalName = j.str('legal_name'),
        country = j.strN('country'),
        taxId = j.strN('tax_id'),
        payoutWallet = j.strN('payout_wallet'),
        verificationStatus = j.str('verification_status'),
        verifiedAt = j.date('verified_at');
  final String id, legalName, verificationStatus;
  final String? country, taxId, payoutWallet;
  final DateTime? verifiedAt;
  bool get isVerified => verificationStatus == 'verified';
}

class Member {
  Member(Json j) : userId = j.str('user_id'), email = j.strN('email'), displayName = j.strN('display_name'), role = j.str('member_role');
  final String userId, role;
  final String? email, displayName;
}

class Customer {
  Customer(Json j)
      : id = j.str('id'),
        name = j.str('name'),
        email = j.strN('email'),
        walletAddress = j.strN('wallet_address'),
        archived = j['archived_at'] != null;
  final String id, name;
  final String? email, walletAddress;
  final bool archived;
}

class Invoice {
  Invoice(Json j)
      : id = j.str('id'),
        customerId = j.str('customer_id'),
        customerName = j.strN('customer_name'),
        number = j.str('invoice_number'),
        description = j.strN('description'),
        amount = j.str('amount'),
        amountBase = BigInt.tryParse(j.str('amount_base')) ?? BigInt.zero,
        decimals = j.integer('token_decimals'),
        currency = j.str('currency'),
        issueDate = j.date('issue_date'),
        dueDate = j.date('due_date'),
        status = j.str('status'),
        paidAmount = j.str('paid_amount'),
        paidBase = BigInt.tryParse(j.str('paid_amount_base')) ?? BigInt.zero,
        reviewStatus = j.str('review_status'),
        invoiceHash = j.strN('invoice_hash'),
        documentHash = j.strN('document_hash'),
        paymentTxHash = j.strN('payment_tx_hash'),
        paymentExplorerUrl = j.strN('payment_explorer_url'),
        financingStatus = j.strN('financing_status'),
        financingOfferId = j.strN('financing_offer_id'),
        createdAt = j.date('created_at');
  final String id, customerId, number, amount, currency, status, paidAmount, reviewStatus;
  final String? customerName, description, invoiceHash, documentHash, paymentTxHash, paymentExplorerUrl, financingStatus, financingOfferId;
  final BigInt amountBase, paidBase;
  final int decimals;
  final DateTime? issueDate, dueDate, createdAt;
  BigInt get remainingBase => amountBase - paidBase;
  bool get isDraft => status == 'DRAFT';
  bool get hasActiveFinancing => const {'REQUESTED', 'UNDER_REVIEW', 'APPROVED', 'LISTED', 'FUNDED', 'DEFAULTED'}.contains(financingStatus);
  /// Mirrors the backend rule (POST /financing/submit): unpaid PENDING invoice, due in the future, no existing financing row.
  String? get financingBlocker {
    if (status != 'PENDING') return 'Only unpaid PENDING invoices can be financed (this one is $status).';
    if (paidBase > BigInt.zero) return 'Invoices with payments cannot be financed.';
    if (financingStatus != null) return 'A financing request already exists for this invoice (${financingStatus!}).';
    if (dueDate != null && !dueDate!.isAfter(DateTime.now())) return 'The invoice is already due.';
    return null;
  }
}

class InvoiceDoc {
  InvoiceDoc(Json j)
      : id = j.str('id'),
        sha256 = j.str('sha256'),
        documentHash = j.str('document_hash'),
        sizeBytes = j.integer('size_bytes'),
        createdAt = j.date('created_at'),
        duplicateWarnings = (j['duplicate_warnings'] as List? ?? const []).map((e) => '$e').toList();
  final String id, sha256, documentHash;
  final int sizeBytes;
  final DateTime? createdAt;
  final List<String> duplicateWarnings;
}

class PaymentLink {
  PaymentLink(Json j) : id = j.str('id'), token = j.str('token'), url = j.str('url'), expiresAt = j.date('expires_at');
  final String id, token, url;
  final DateTime? expiresAt;
}

class PaymentRecord {
  PaymentRecord(Json j)
      : payerWallet = j.str('payer_wallet'),
        amount = j.str('amount'),
        txHash = j.str('tx_hash'),
        explorerUrl = j.strN('explorer_url'),
        status = j.strN('status'),
        confirmedAt = j.date('confirmed_at');
  final String payerWallet, amount, txHash;
  final String? explorerUrl, status;
  final DateTime? confirmedAt;
}

class PaymentStatus {
  PaymentStatus(Json j)
      : status = j.str('status'),
        amount = j.str('amount'),
        paidAmount = j.str('paid_amount'),
        remainingAmount = j.str('remaining_amount'),
        financingStatus = j.strN('financing_status'),
        payable = j.flag('payable'),
        payableReason = j.strN('payable_reason'),
        payments = (j['payments'] as List? ?? const []).map((e) => PaymentRecord(asJson(e))).toList();
  final String status, amount, paidAmount, remainingAmount;
  final String? financingStatus, payableReason;
  final bool payable;
  final List<PaymentRecord> payments;
}

class Payment {
  Payment(Json j)
      : id = j.str('id'),
        invoiceId = j.str('invoice_id'),
        invoiceNumber = j.strN('invoice_number'),
        payerWallet = j.str('payer_wallet'),
        amount = j.str('amount'),
        txHash = j.str('tx_hash'),
        blockNumber = j.integerN('block_number'),
        status = j.str('status'),
        confirmedAt = j.date('confirmed_at'),
        explorerUrl = j.str('explorer_url');
  final String id, invoiceId, payerWallet, amount, txHash, status, explorerUrl;
  final String? invoiceNumber;
  final int? blockNumber;
  final DateTime? confirmedAt;
}

class TxVerification {
  TxVerification(Json j)
      : txHash = j.str('tx_hash'),
        stage = j.str('stage'),
        detail = j.str('detail'),
        confirmations = j.integer('confirmations'),
        required = j.integer('required_confirmations'),
        explorerUrl = j.str('explorer_url'),
        events = (j['events'] as List? ?? const []).map((e) => asJson(e)).toList();
  final String txHash, stage, detail, explorerUrl;
  final int confirmations, required;
  final List<Json> events;
  bool get verified => stage == 'verified';
  bool get terminalFailure => stage == 'failed' || stage == 'rejected';
}

class Offer {
  Offer(Json j)
      : id = j.str('id'),
        invoiceId = j.str('invoice_id'),
        invoiceNumber = j.str('invoice_number'),
        businessName = j.strN('business_name'),
        businessVerified = j.flag('business_verified'),
        status = j.str('status'),
        displayStatus = j.str('display_status'),
        isOverdue = j.flag('is_overdue'),
        faceValue = j.str('face_value'),
        faceBase = BigInt.tryParse(j.str('face_value_base')) ?? BigInt.zero,
        advance = j.str('advance'),
        advanceBase = BigInt.tryParse(j.str('advance_base')) ?? BigInt.zero,
        discountBps = j.integer('discount_bps'),
        decimals = j.integer('token_decimals'),
        maturityDate = j.date('maturity_date'),
        fundingDeadline = j.date('funding_deadline'),
        onchainId = j.strN('onchain_offer_id'),
        registeredAt = j.date('onchain_registered_at'),
        verifiedOnchainAt = j.date('onchain_verified_at'),
        contract = j.strN('contract_address'),
        debtorAck = j.obj('debtor_ack'),
        assignmentNotice = j.obj('assignment_notice'),
        reviewNotes = j.strN('review_notes'),
        disclosure = j.str('disclosure');
  final String id, invoiceId, invoiceNumber, status, displayStatus, faceValue, advance, disclosure;
  final String? businessName, onchainId, contract, reviewNotes;
  final bool businessVerified, isOverdue;
  final BigInt faceBase, advanceBase;
  final int discountBps, decimals;
  final DateTime? maturityDate, fundingDeadline, registeredAt, verifiedOnchainAt;
  final Json? debtorAck, assignmentNotice;
  String get discountPercent => (discountBps / 100).toStringAsFixed(2);
}

class OnchainStep {
  OnchainStep(Json j)
      : step = j.str('step'),
        contract = j.str('contract'),
        function = j.str('function'),
        signer = j.str('signer'),
        args = asJson(j['args']),
        note = j.strN('note');
  final String step, contract, function, signer;
  final Json args;
  final String? note;
}

class PublishPlan {
  PublishPlan(Json j)
      : status = j.str('status'),
        next = j['next_step'] == null ? null : OnchainStep(asJson(j['next_step'])),
        remaining = (j['remaining_steps'] as List? ?? const []).map((e) => '$e').toList(),
        message = j.str('message');
  final String status, message;
  final OnchainStep? next;
  final List<String> remaining;
}

class Investment {
  Investment(Json j)
      : id = j.str('id'),
        offerId = j.str('offer_id'),
        invoiceId = j.str('invoice_id'),
        invoiceNumber = j.str('invoice_number'),
        investorWallet = j.str('investor_wallet'),
        amount = j.str('amount'),
        expectedRepayment = j.str('expected_repayment'),
        status = j.str('status'),
        offerStatus = j.str('offer_status'),
        maturityDate = j.date('maturity_date'),
        fundedAt = j.date('funded_at'),
        repaymentAmount = j.strN('repayment_amount'),
        repaymentTxHash = j.strN('repayment_tx_hash'),
        settledAt = j.date('settled_at'),
        txHash = j.str('tx_hash'),
        explorerUrl = j.str('explorer_url');
  final String id, offerId, invoiceId, invoiceNumber, investorWallet, amount, expectedRepayment, status, offerStatus, txHash, explorerUrl;
  final String? repaymentAmount, repaymentTxHash;
  final DateTime? maturityDate, fundedAt, settledAt;
}

class Extraction {
  Extraction(Json j)
      : fields = asJson(j['extracted']),
        sha256 = j.str('sha256'),
        pages = j.integerN('pages'),
        duplicateWarnings = (j['duplicate_warnings'] as List? ?? const []).map((e) => '$e').toList(),
        notice = j.str('notice');
  final Json fields;
  final String sha256, notice;
  final int? pages;
  final List<String> duplicateWarnings;
  double get confidence => fields.dbl('confidence');
  List<String> get warnings => (fields['warnings'] as List? ?? const []).map((e) => '$e').toList();
}

class AiNote {
  AiNote(this.title, this.body, {this.items = const [], this.notice = ''});
  final String title, body, notice;
  final List<String> items;
}

class Validation {
  Validation(Json j)
      : issues = (j['issues'] as List).map((e) => '$e').toList(),
        duplicates = (j['duplicate_warnings'] as List).map((e) => '$e').toList(),
        aiWarnings = (j['ai_warnings'] as List).map((e) => '$e').toList(),
        confidence = j.dbl('confidence'),
        aiUsed = j.flag('ai_used');
  final List<String> issues, duplicates, aiWarnings;
  final double confidence;
  final bool aiUsed;
}

class PublicInvoice {
  PublicInvoice(Json j)
      : merchantName = j.str('merchant_name'),
        number = j.str('invoice_number'),
        description = j.strN('description'),
        amount = j.str('amount'),
        paidAmount = j.str('paid_amount'),
        remainingAmount = j.str('remaining_amount'),
        currency = j.str('currency'),
        dueDate = j.date('due_date'),
        status = j.str('status'),
        payable = j.flag('payable'),
        payableReason = j.strN('payable_reason'),
        chainId = j.integer('chain_id'),
        usdt = j.str('usdt_address'),
        decimals = j.integer('usdt_decimals'),
        paymentsContract = j.str('payments_contract'),
        linkExpiresAt = j.date('link_expires_at');
  final String merchantName, number, amount, paidAmount, remainingAmount, currency, status, usdt, paymentsContract;
  final String? description, payableReason;
  final DateTime? dueDate, linkExpiresAt;
  final bool payable;
  final int chainId, decimals;
}

class PaymentIntent {
  PaymentIntent(Json j)
      : chainId = j.integer('chain_id'),
        paymentsContract = j.str('payments_contract'),
        usdt = j.str('usdt_address'),
        decimals = j.integer('usdt_decimals'),
        approveBase = BigInt.parse(j.str('approve_amount_base')),
        quote = asJson(j['quote']),
        signature = j.str('signature'),
        expiresAt = j.date('quote_expires_at');
  final int chainId, decimals;
  final String paymentsContract, usdt, signature;
  final BigInt approveBase;
  final Json quote;
  final DateTime? expiresAt;
}

class NotificationItem {
  NotificationItem(Json j)
      : id = j.str('id'),
        type = j.str('type'),
        title = j.str('title'),
        body = j.strN('body'),
        read = j['read_at'] != null,
        createdAt = j.date('created_at');
  final String id, type, title;
  final String? body;
  final bool read;
  final DateTime? createdAt;
}

class ChainConfig {
  ChainConfig(Json j)
      : chainId = j.integer('chain_id'),
        explorerUrl = j.str('explorer_url'),
        usdt = j.strN('usdt_address'),
        decimals = j.integerN('usdt_decimals'),
        payments = j.strN('payments_contract'),
        financing = j.strN('financing_contract'),
        minConfirmations = j.integer('min_confirmations'),
        configured = j.flag('configured');
  final int chainId;
  final String explorerUrl;
  final String? usdt, payments, financing;
  final int? decimals;
  final int minConfirmations;
  final bool configured;
}
