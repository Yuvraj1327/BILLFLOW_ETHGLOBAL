// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title BillFlowPayments
/// @notice Invoice-linked stablecoin payments (BillFlow "Operate" module).
/// @dev The contract NEVER holds funds: `payInvoice` moves tokens straight from the payer to the
///      merchant. Each payment must be authorised by a short-lived EIP-712 quote signed by the
///      BillFlow backend, which binds the invoice id, invoice hash, merchant, payer, amount and the
///      invoice total, so a payer cannot redirect funds or change the amount. Partial payments are
///      supported through a cumulative cap (`totalPaid <= invoiceTotal`); once the cap is reached the
///      invoice is `Paid` and no further payment is accepted (no duplicate full payment).
///      Token decimals are irrelevant to the logic: amounts are raw token base units.
contract BillFlowPayments is AccessControl, Pausable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    // ───────────────────────────── roles ─────────────────────────────
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ───────────────────────────── types ─────────────────────────────
    enum PaymentStatus {
        None, // never paid
        PartiallyPaid,
        Paid
    }

    /// @notice Backend-signed payment authorisation (EIP-712).
    struct Quote {
        bytes32 invoiceId; // keccak256(invoice uuid) — set by backend
        bytes32 invoiceHash; // hash of canonical invoice data (metadata binding)
        address merchant; // payment receiver
        address payer; // must equal msg.sender
        uint256 amount; // base units to pay now
        uint256 invoiceTotal; // full invoice amount in base units
        uint256 nonce; // single-use
        uint64 expiry; // unix seconds
    }

    struct InvoicePayment {
        address merchant;
        bytes32 invoiceHash;
        uint256 invoiceTotal;
        uint256 totalPaid;
        uint32 paymentCount;
        PaymentStatus status;
    }

    struct PaymentRecord {
        bytes32 invoiceId;
        address payer;
        address merchant;
        uint256 amount;
        uint64 paidAt;
    }

    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "Quote(bytes32 invoiceId,bytes32 invoiceHash,address merchant,address payer,uint256 amount,uint256 invoiceTotal,uint256 nonce,uint64 expiry)"
    );

    // ───────────────────────────── storage ─────────────────────────────
    IERC20 public immutable PAYMENT_TOKEN;
    address public quoteSigner;

    mapping(bytes32 invoiceId => InvoicePayment) private _invoices;
    mapping(uint256 paymentId => PaymentRecord) private _payments;
    mapping(uint256 nonce => bool) public usedNonce;
    uint256 public paymentCount;

    // ───────────────────────────── events ─────────────────────────────
    event InvoicePaid(
        bytes32 indexed invoiceId,
        uint256 indexed paymentId,
        address indexed payer,
        address merchant,
        uint256 amount,
        uint256 totalPaid,
        uint256 invoiceTotal,
        bytes32 invoiceHash
    );
    event QuoteSignerUpdated(address indexed previousSigner, address indexed newSigner);
    event QuoteNonceRevoked(uint256 indexed nonce, address indexed by);

    // ───────────────────────────── errors ─────────────────────────────
    error ZeroAddress();
    error InvalidAmount();
    error InvalidInvoice();
    error NotPayer();
    error SelfPayment();
    error QuoteExpired();
    error NonceUsed();
    error InvalidSignature();
    error AlreadyPaid();
    error Overpayment(uint256 remaining);
    error InvoiceMismatch();
    error UnexpectedTransferAmount();
    error NotAuthorised();

    constructor(IERC20 token, address admin, address signer, address pauser) EIP712("BillFlowPayments", "1") {
        if (address(token) == address(0) || admin == address(0) || signer == address(0) || pauser == address(0)) {
            revert ZeroAddress();
        }
        PAYMENT_TOKEN = token;
        quoteSigner = signer;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);
        emit QuoteSignerUpdated(address(0), signer);
    }

    // ───────────────────────────── payment ─────────────────────────────

    /// @notice Pay (part of) an invoice with the payment token. Caller must have approved this
    ///         contract for at least `q.amount`. Funds go directly to `q.merchant`.
    function payInvoice(Quote calldata q, bytes calldata signature)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 paymentId)
    {
        _validateQuote(q, signature);
        uint256 newTotal;
        (paymentId, newTotal) = _recordPayment(q);

        // ── interaction ── (reverts on fee-on-transfer / short-delivering tokens)
        uint256 balanceBefore = PAYMENT_TOKEN.balanceOf(q.merchant);
        PAYMENT_TOKEN.safeTransferFrom(msg.sender, q.merchant, q.amount); // msg.sender == q.payer (checked)
        if (PAYMENT_TOKEN.balanceOf(q.merchant) - balanceBefore != q.amount) revert UnexpectedTransferAmount();

        emit InvoicePaid(
            q.invoiceId, paymentId, q.payer, q.merchant, q.amount, newTotal, q.invoiceTotal, q.invoiceHash
        );
    }

    function _validateQuote(Quote calldata q, bytes calldata signature) private view {
        if (msg.sender != q.payer) revert NotPayer();
        if (q.merchant == address(0)) revert ZeroAddress();
        if (q.merchant == q.payer) revert SelfPayment();
        if (q.amount == 0 || q.invoiceTotal == 0) revert InvalidAmount();
        if (q.invoiceId == bytes32(0) || q.invoiceHash == bytes32(0)) revert InvalidInvoice();
        if (block.timestamp > q.expiry) revert QuoteExpired();
        if (usedNonce[q.nonce]) revert NonceUsed();
        if (ECDSA.recover(hashQuote(q), signature) != quoteSigner) revert InvalidSignature();
    }

    /// @dev Effects only (checks-effects-interactions): updates invoice state and stores the payment record.
    function _recordPayment(Quote calldata q) private returns (uint256 paymentId, uint256 newTotal) {
        InvoicePayment storage inv = _invoices[q.invoiceId];
        if (inv.status == PaymentStatus.None) {
            // First payment fixes the invoice terms; later quotes must match exactly.
            inv.merchant = q.merchant;
            inv.invoiceHash = q.invoiceHash;
            inv.invoiceTotal = q.invoiceTotal;
        } else {
            if (inv.status == PaymentStatus.Paid) revert AlreadyPaid();
            if (inv.merchant != q.merchant || inv.invoiceHash != q.invoiceHash || inv.invoiceTotal != q.invoiceTotal) {
                revert InvoiceMismatch();
            }
        }

        uint256 remaining = inv.invoiceTotal - inv.totalPaid;
        if (q.amount > remaining) revert Overpayment(remaining);

        usedNonce[q.nonce] = true;
        newTotal = inv.totalPaid + q.amount;
        inv.totalPaid = newTotal;
        inv.paymentCount += 1;
        inv.status = newTotal == inv.invoiceTotal ? PaymentStatus.Paid : PaymentStatus.PartiallyPaid;

        paymentId = ++paymentCount;
        _payments[paymentId] = PaymentRecord({
            invoiceId: q.invoiceId,
            payer: q.payer,
            merchant: q.merchant,
            amount: q.amount,
            paidAt: uint64(block.timestamp)
        });
    }

    // ───────────────────────────── views ─────────────────────────────

    function getPayment(uint256 paymentId) external view returns (PaymentRecord memory) {
        if (paymentId == 0 || paymentId > paymentCount) revert InvalidInvoice();
        return _payments[paymentId];
    }

    function getInvoicePaymentStatus(bytes32 invoiceId) external view returns (InvoicePayment memory) {
        return _invoices[invoiceId];
    }

    function isInvoicePaid(bytes32 invoiceId) external view returns (bool) {
        return _invoices[invoiceId].status == PaymentStatus.Paid;
    }

    function remainingAmount(bytes32 invoiceId) external view returns (uint256) {
        InvoicePayment storage inv = _invoices[invoiceId];
        return inv.invoiceTotal - inv.totalPaid; // 0 when never paid (both zero)
    }

    /// @notice EIP-712 digest the quote signer must sign (also useful for off-chain tests).
    function hashQuote(Quote calldata q) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    QUOTE_TYPEHASH,
                    q.invoiceId,
                    q.invoiceHash,
                    q.merchant,
                    q.payer,
                    q.amount,
                    q.invoiceTotal,
                    q.nonce,
                    q.expiry
                )
            )
        );
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ───────────────────────────── admin ─────────────────────────────

    function setQuoteSigner(address newSigner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSigner == address(0)) revert ZeroAddress();
        emit QuoteSignerUpdated(quoteSigner, newSigner);
        quoteSigner = newSigner;
    }

    /// @notice Invalidate an outstanding quote (e.g. invoice cancelled after the quote was issued).
    function revokeNonce(uint256 nonce) external {
        if (msg.sender != quoteSigner && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotAuthorised();
        usedNonce[nonce] = true;
        emit QuoteNonceRevoked(nonce, msg.sender);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
