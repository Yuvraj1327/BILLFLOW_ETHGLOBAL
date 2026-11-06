// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Read-only view of the (unchanged) BillFlowPayments contract.
interface IBillFlowPaymentsView {
    struct PaymentRecord {
        bytes32 invoiceId;
        address payer;
        address merchant;
        uint256 amount;
        uint64 paidAt;
    }

    function getPayment(uint256 paymentId) external view returns (PaymentRecord memory);
    function paymentCount() external view returns (uint256);
    function PAYMENT_TOKEN() external view returns (IERC20);
}

/// @title BillFlowRefunds
/// @notice Merchant-initiated full / partial refunds of BillFlowPayments payments.
/// @dev BillFlowPayments forwards funds straight to the merchant, so a refund has to be paid BY the
///      merchant. This contract holds NO funds: `refund` pulls tokens from the merchant (who must have
///      approved this contract) and sends them straight to the ORIGINAL payer recorded on-chain in
///      BillFlowPayments. Guarantees:
///        - only the merchant recorded for that payment can refund it (merchant authorisation);
///        - the recipient is always the recorded payer, never a caller-supplied address;
///        - sum of refunds for a payment can never exceed the amount paid;
///        - `refundRef` (a caller/backend idempotency key) can be used once, so a retried
///          transaction cannot refund twice;
///        - nonReentrant + pausable; fee-on-transfer tokens are rejected.
///      It never changes BillFlowPayments state: a payment's status there is unaffected, the refund
///      ledger lives here and is the source of truth for refund verification.
contract BillFlowRefunds is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IBillFlowPaymentsView public immutable PAYMENTS;
    IERC20 public immutable PAYMENT_TOKEN;

    struct RefundRecord {
        uint256 paymentId;
        address payer; // recipient
        address merchant; // refunder
        uint256 amount;
        bytes32 refundRef;
        bytes32 reasonHash; // hash of the (off-chain, private) reason text
        uint64 refundedAt;
    }

    mapping(uint256 refundId => RefundRecord) private _refunds;
    mapping(uint256 paymentId => uint256) public totalRefunded;
    mapping(bytes32 refundRef => uint256 refundId) public refundIdByRef;
    uint256 public refundCount;

    event PaymentRefunded(
        uint256 indexed refundId,
        uint256 indexed paymentId,
        address indexed payer,
        address merchant,
        uint256 amount,
        uint256 totalRefundedForPayment,
        uint256 paymentAmount,
        bytes32 refundRef,
        bytes32 reasonHash
    );

    error ZeroAddress();
    error InvalidAmount();
    error InvalidPayment();
    error NotMerchant();
    error RefundExceedsPayment(uint256 refundable);
    error RefundRefUsed();
    error InvalidRefundRef();
    error UnexpectedTransferAmount();

    constructor(IBillFlowPaymentsView payments, address admin, address pauser) {
        if (address(payments) == address(0) || admin == address(0) || pauser == address(0)) revert ZeroAddress();
        PAYMENTS = payments;
        PAYMENT_TOKEN = payments.PAYMENT_TOKEN();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);
    }

    /// @notice Refund `amount` of payment `paymentId` to its original payer. Caller = the payment's merchant.
    ///         The merchant must have approved this contract for at least `amount` of the payment token.
    function refund(uint256 paymentId, uint256 amount, bytes32 refundRef, bytes32 reasonHash)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 refundId)
    {
        if (amount == 0) revert InvalidAmount();
        if (refundRef == bytes32(0)) revert InvalidRefundRef();
        if (refundIdByRef[refundRef] != 0) revert RefundRefUsed();
        if (paymentId == 0 || paymentId > PAYMENTS.paymentCount()) revert InvalidPayment();

        IBillFlowPaymentsView.PaymentRecord memory p = PAYMENTS.getPayment(paymentId);
        if (p.merchant == address(0) || p.payer == address(0)) revert InvalidPayment();
        if (msg.sender != p.merchant) revert NotMerchant();

        uint256 already = totalRefunded[paymentId];
        uint256 remaining = p.amount - already; // already <= p.amount always (invariant)
        if (amount > remaining) revert RefundExceedsPayment(remaining);

        // ── effects ──
        uint256 newTotal = already + amount;
        totalRefunded[paymentId] = newTotal;
        refundId = ++refundCount;
        refundIdByRef[refundRef] = refundId;
        _refunds[refundId] = RefundRecord({
            paymentId: paymentId,
            payer: p.payer,
            merchant: p.merchant,
            amount: amount,
            refundRef: refundRef,
            reasonHash: reasonHash,
            refundedAt: uint64(block.timestamp)
        });

        // ── interaction: merchant -> original payer (exact amount, fee-on-transfer rejected) ──
        uint256 before = PAYMENT_TOKEN.balanceOf(p.payer);
        PAYMENT_TOKEN.safeTransferFrom(p.merchant, p.payer, amount);
        if (PAYMENT_TOKEN.balanceOf(p.payer) - before != amount) revert UnexpectedTransferAmount();

        emit PaymentRefunded(
            refundId, paymentId, p.payer, p.merchant, amount, newTotal, p.amount, refundRef, reasonHash
        );
    }

    // ───────────── views ─────────────
    function getRefund(uint256 refundId) external view returns (RefundRecord memory) {
        if (refundId == 0 || refundId > refundCount) revert InvalidPayment();
        return _refunds[refundId];
    }

    /// @notice Amount of `paymentId` still refundable (0 for unknown payments).
    function refundable(uint256 paymentId) external view returns (uint256) {
        if (paymentId == 0 || paymentId > PAYMENTS.paymentCount()) return 0;
        return PAYMENTS.getPayment(paymentId).amount - totalRefunded[paymentId];
    }

    // ───────────── admin ─────────────
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
