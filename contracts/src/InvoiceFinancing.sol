// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title InvoiceFinancing
/// @notice Registry + financing lifecycle + restricted claim token for BillFlow's "Tokenize" module.
///
/// ┌──────────────────────────────── WHAT THE TOKEN IS (AND IS NOT) ────────────────────────────────┐
/// │ Each invoice gets one ERC-721 (tokenId == invoiceId). The token is a RESTRICTED, NON-TRANSFERABLE │
/// │ record of who is entitled to the REPAYMENT of this financing under the rules of this contract:    │
/// │   • while the offer is listed it is held by this contract;                                        │
/// │   • when an investor funds it, the contract moves it to that investor;                            │
/// │   • on repayment, the face value is paid to the current holder.                                   │
/// │ It is NOT a legal assignment of the invoice and does not by itself make the holder the legal      │
/// │ owner of the receivable. Legal assignment and debtor acknowledgement are separate off-chain       │
/// │ requirements (only an evidence hash is recorded here). This is a disclosed TESTNET PROTOTYPE.     │
/// └────────────────────────────────────────────────────────────────────────────────────────────────┘
///
/// Funds are never custodied: the investor's advance goes straight to the business at `fund`, and the
/// debtor's repayment goes straight to the investor at `repay`. The contract therefore has no balance
/// to withdraw, and there is no admin path that can move user funds.
///
/// Lifecycle: Registered → Verified → Listed → Funded → Settled
///            side exits: Rejected, Cancelled, Expired, Defaulted (can still be repaid → Settled)
contract InvoiceFinancing is ERC721, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ───────────────────────────── roles ─────────────────────────────
    /// Registers invoices on behalf of (already approved) businesses.
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    /// Human verification: approves businesses/investors, verifies/rejects invoices.
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    /// Operational actions: publish/cancel offers on behalf of a business, mark defaults.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ───────────────────────────── types ─────────────────────────────
    enum Status {
        None,
        Registered,
        Verified,
        Listed,
        Funded,
        Settled,
        Rejected,
        Cancelled,
        Expired,
        Defaulted
    }

    struct Invoice {
        bytes32 invoiceHash; // hash of canonical invoice data; unique key (anti-duplication)
        bytes32 documentHash; // hash of the supporting PDF (the PDF itself stays off-chain)
        bytes32 debtorRef; // hash/reference of debtor identity (no personal data on-chain)
        bytes32 debtorAckRef; // hash of debtor-acknowledgement evidence (set at verification)
        address business; // issuer of the invoice and recipient of the advance
        address debtor; // expected payer (informational; zero = any payer may repay)
        address investor; // set at funding
        uint256 faceValue; // amount the debtor owes (token base units)
        uint256 advance; // amount the investor pays the business now
        uint64 issueDate;
        uint64 dueDate; // maturity
        uint64 fundingDeadline;
        uint64 fundedAt;
        uint64 settledAt;
        Status status;
    }

    struct RegisterParams {
        bytes32 invoiceHash;
        bytes32 documentHash;
        bytes32 debtorRef;
        address business;
        address debtor;
        uint256 faceValue;
        uint64 issueDate;
        uint64 dueDate;
    }

    // ───────────────────────────── storage ─────────────────────────────
    uint256 public constant MAX_DISCOUNT_BPS_LIMIT = 5000; // hard ceiling on the configurable cap (50%)
    uint256 public constant MAX_GRACE_LIMIT = 90 days;

    IERC20 public immutable PAYMENT_TOKEN;

    uint256 public invoiceCount;
    mapping(uint256 invoiceId => Invoice) private _invoices;
    mapping(bytes32 invoiceHash => uint256 invoiceId) public invoiceIdByHash; // non-zero ⇒ hash used

    mapping(address business => bool) public businessApproved;
    mapping(address investor => bool) public investorApproved;
    bool public investorAllowlistEnabled = true;

    uint256 public maxDiscountBps = 2000; // 20% max (face - advance) / face
    uint256 public gracePeriod = 7 days; // after dueDate before an unpaid funded invoice can be defaulted

    bool private _internalMove; // true only while this contract itself mints/moves/burns the claim token

    // ───────────────────────────── events ─────────────────────────────
    event InvoiceRegistered(
        uint256 indexed invoiceId,
        bytes32 indexed invoiceHash,
        address indexed business,
        address debtor,
        bytes32 debtorRef,
        bytes32 documentHash,
        uint256 faceValue,
        uint64 issueDate,
        uint64 dueDate,
        address registeredBy
    );
    event InvoiceVerified(uint256 indexed invoiceId, address indexed verifier, bytes32 debtorAckRef);
    event InvoiceRejected(uint256 indexed invoiceId, address indexed verifier, bytes32 reasonRef);
    event InvoiceCancelled(uint256 indexed invoiceId, address indexed by);
    event OfferCreated(
        uint256 indexed invoiceId,
        address indexed business,
        uint256 faceValue,
        uint256 advance,
        uint256 discountBps,
        uint64 dueDate,
        uint64 fundingDeadline
    );
    event OfferFunded(uint256 indexed invoiceId, address indexed investor, address indexed business, uint256 advance);
    event OfferRepaid(uint256 indexed invoiceId, address indexed payer, address indexed investor, uint256 amount);
    event OfferSettled(uint256 indexed invoiceId, address indexed investor);
    event OfferCancelled(uint256 indexed invoiceId, address indexed by);
    event OfferExpired(uint256 indexed invoiceId);
    event OfferDefaulted(uint256 indexed invoiceId, address indexed by);
    event BusinessApprovalUpdated(address indexed business, bool approved);
    event InvestorApprovalUpdated(address indexed investor, bool approved);
    event InvestorAllowlistToggled(bool enabled);
    event MaxDiscountUpdated(uint256 maxDiscountBps);
    event GracePeriodUpdated(uint256 gracePeriod);

    // ───────────────────────────── errors ─────────────────────────────
    error ZeroAddress();
    error InvalidAmount();
    error InvalidDates();
    error InvalidReference();
    error DuplicateInvoice(uint256 existingInvoiceId);
    error UnknownInvoice();
    error InvalidStatus(Status current);
    error BusinessNotApproved();
    error InvestorNotApproved();
    error NotAuthorised();
    error FundingClosed();
    error FundingStillOpen();
    error NotYetDefaultable();
    error DiscountTooHigh(uint256 discountBps, uint256 maxBps);
    error SelfDealing();
    error TransfersRestricted();
    error UnexpectedTransferAmount();
    error InvalidConfig();
    error CannotRescuePaymentToken();

    constructor(IERC20 token, address admin) ERC721("BillFlow Invoice Claim", "BFINV") {
        if (address(token) == address(0) || admin == address(0)) revert ZeroAddress();
        PAYMENT_TOKEN = token;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ═════════════════════════ 1. REGISTRATION ═════════════════════════

    /// @notice Register an unpaid invoice for financing. Callable by an approved business for itself,
    ///         or by an ISSUER_ROLE holder on its behalf. Hash + document hash are stored; the PDF is not.
    function registerInvoice(RegisterParams calldata p) external whenNotPaused returns (uint256 invoiceId) {
        if (p.business == address(0)) revert ZeroAddress();
        if (!businessApproved[p.business]) revert BusinessNotApproved();
        if (msg.sender != p.business && !hasRole(ISSUER_ROLE, msg.sender)) revert NotAuthorised();
        if (p.faceValue == 0) revert InvalidAmount();
        if (p.invoiceHash == bytes32(0) || p.documentHash == bytes32(0) || p.debtorRef == bytes32(0)) {
            revert InvalidReference();
        }
        if (p.issueDate > block.timestamp || p.dueDate <= block.timestamp || p.dueDate <= p.issueDate) {
            revert InvalidDates();
        }
        uint256 existing = invoiceIdByHash[p.invoiceHash];
        if (existing != 0) revert DuplicateInvoice(existing);

        invoiceId = ++invoiceCount;
        invoiceIdByHash[p.invoiceHash] = invoiceId;

        Invoice storage inv = _invoices[invoiceId];
        inv.invoiceHash = p.invoiceHash;
        inv.documentHash = p.documentHash;
        inv.debtorRef = p.debtorRef;
        inv.business = p.business;
        inv.debtor = p.debtor;
        inv.faceValue = p.faceValue;
        inv.issueDate = p.issueDate;
        inv.dueDate = p.dueDate;
        inv.status = Status.Registered;

        emit InvoiceRegistered(
            invoiceId,
            p.invoiceHash,
            p.business,
            p.debtor,
            p.debtorRef,
            p.documentHash,
            p.faceValue,
            p.issueDate,
            p.dueDate,
            msg.sender
        );
    }

    // ═════════════════════════ 2. VERIFICATION ═════════════════════════

    /// @notice Record human verification of the invoice plus a hash of the debtor-acknowledgement
    ///         evidence. AI output alone must never trigger this — it is a VERIFIER_ROLE human action.
    function verifyInvoice(uint256 invoiceId, bytes32 debtorAckRef) external onlyRole(VERIFIER_ROLE) whenNotPaused {
        Invoice storage inv = _get(invoiceId);
        if (inv.status != Status.Registered) revert InvalidStatus(inv.status);
        if (debtorAckRef == bytes32(0)) revert InvalidReference();
        if (block.timestamp >= inv.dueDate) revert InvalidDates();
        inv.debtorAckRef = debtorAckRef;
        inv.status = Status.Verified;
        emit InvoiceVerified(invoiceId, msg.sender, debtorAckRef);
    }

    /// @notice Reject a registered invoice. Its hash stays used (no re-registration of the same data).
    function rejectInvoice(uint256 invoiceId, bytes32 reasonRef) external onlyRole(VERIFIER_ROLE) {
        Invoice storage inv = _get(invoiceId);
        if (inv.status != Status.Registered) revert InvalidStatus(inv.status);
        inv.status = Status.Rejected;
        emit InvoiceRejected(invoiceId, msg.sender, reasonRef);
    }

    /// @notice Withdraw a not-yet-listed invoice (business, issuer or operator).
    function cancelInvoice(uint256 invoiceId) external {
        Invoice storage inv = _get(invoiceId);
        if (inv.status != Status.Registered && inv.status != Status.Verified) revert InvalidStatus(inv.status);
        _requireBusinessOrOperator(inv.business);
        inv.status = Status.Cancelled;
        emit InvoiceCancelled(invoiceId, msg.sender);
    }

    // ═════════════════════ 3 + 4. TOKENIZATION + OFFER ═════════════════════

    /// @notice Publish the financing offer for a VERIFIED invoice and mint its restricted claim token
    ///         (held by this contract until funded). Callable by the invoice's business or an operator.
    function createOffer(uint256 invoiceId, uint256 advance, uint64 fundingDeadline)
        external
        whenNotPaused
        returns (uint256 discountBps)
    {
        Invoice storage inv = _get(invoiceId);
        if (inv.status != Status.Verified) revert InvalidStatus(inv.status);
        _requireBusinessOrOperator(inv.business);
        if (!businessApproved[inv.business]) revert BusinessNotApproved();
        if (advance == 0 || advance >= inv.faceValue) revert InvalidAmount();
        if (fundingDeadline <= block.timestamp || fundingDeadline > inv.dueDate) revert InvalidDates();

        // Exact comparison (no rounding slack): (face - advance) / face must be <= maxDiscountBps / 10_000.
        discountBps = ((inv.faceValue - advance) * 10_000) / inv.faceValue; // floored, for reporting only
        if ((inv.faceValue - advance) * 10_000 > maxDiscountBps * inv.faceValue) {
            revert DiscountTooHigh(discountBps, maxDiscountBps);
        }

        inv.advance = advance;
        inv.fundingDeadline = fundingDeadline;
        inv.status = Status.Listed;

        _internalMove = true;
        _mint(address(this), invoiceId); // plain _mint: no receiver callback
        _internalMove = false;

        emit OfferCreated(invoiceId, inv.business, inv.faceValue, advance, discountBps, inv.dueDate, fundingDeadline);
    }

    /// @notice Cancel a listed offer (business or operator). Burns the unclaimed token.
    function cancelOffer(uint256 invoiceId) external {
        Invoice storage inv = _get(invoiceId);
        if (inv.status != Status.Listed) revert InvalidStatus(inv.status);
        _requireBusinessOrOperator(inv.business);
        inv.status = Status.Cancelled;
        _burnClaim(invoiceId);
        emit OfferCancelled(invoiceId, msg.sender);
    }

    /// @notice Anyone may expire an offer whose funding deadline passed unfunded.
    function expireOffer(uint256 invoiceId) external {
        Invoice storage inv = _get(invoiceId);
        if (inv.status != Status.Listed) revert InvalidStatus(inv.status);
        if (block.timestamp <= inv.fundingDeadline) revert FundingStillOpen();
        inv.status = Status.Expired;
        _burnClaim(invoiceId);
        emit OfferExpired(invoiceId);
    }

    // ═════════════════════════ 5. FUNDING ═════════════════════════

    /// @notice Fund a listed offer in full. The advance goes straight to the business and the claim
    ///         token moves to the investor. Caller must have approved this contract for `advance`.
    function fund(uint256 invoiceId) external nonReentrant whenNotPaused {
        Invoice storage inv = _get(invoiceId);
        if (inv.status != Status.Listed) revert InvalidStatus(inv.status); // also blocks double funding
        if (block.timestamp > inv.fundingDeadline) revert FundingClosed();
        if (investorAllowlistEnabled && !investorApproved[msg.sender]) revert InvestorNotApproved();
        if (msg.sender == inv.business || msg.sender == address(this)) revert SelfDealing();

        // ── effects ──
        uint256 advance = inv.advance;
        address business = inv.business;
        inv.status = Status.Funded;
        inv.investor = msg.sender;
        inv.fundedAt = uint64(block.timestamp);
        _moveClaim(msg.sender, invoiceId);

        // ── interaction ──
        uint256 balanceBefore = PAYMENT_TOKEN.balanceOf(business);
        PAYMENT_TOKEN.safeTransferFrom(msg.sender, business, advance);
        if (PAYMENT_TOKEN.balanceOf(business) - balanceBefore != advance) revert UnexpectedTransferAmount();

        emit OfferFunded(invoiceId, msg.sender, business, advance);
    }

    // ═════════════════════════ 6. REPAYMENT & SETTLEMENT ═════════════════════════

    /// @notice Repay the full face value. The debtor or ANY third party may pay; funds go straight to
    ///         the current claim holder (the investor). Allowed early, on time, or late (including after
    ///         `Defaulted`). Not pausable on purpose: completing an existing obligation must stay possible.
    function repay(uint256 invoiceId) external nonReentrant {
        Invoice storage inv = _get(invoiceId);
        if (inv.status != Status.Funded && inv.status != Status.Defaulted) revert InvalidStatus(inv.status);

        address investor = ownerOf(invoiceId);
        if (msg.sender == investor) revert SelfDealing();
        uint256 amount = inv.faceValue;

        // ── effects ──
        inv.status = Status.Settled;
        inv.settledAt = uint64(block.timestamp);

        // ── interaction ──
        uint256 balanceBefore = PAYMENT_TOKEN.balanceOf(investor);
        PAYMENT_TOKEN.safeTransferFrom(msg.sender, investor, amount);
        if (PAYMENT_TOKEN.balanceOf(investor) - balanceBefore != amount) revert UnexpectedTransferAmount();

        emit OfferRepaid(invoiceId, msg.sender, investor, amount);
        emit OfferSettled(invoiceId, investor);
    }

    /// @notice Flag a funded invoice as defaulted once maturity + grace has passed. Informational state
    ///         for investors/UI; it does not move funds and does not prevent a later repayment.
    function markDefaulted(uint256 invoiceId) external onlyRole(OPERATOR_ROLE) {
        Invoice storage inv = _get(invoiceId);
        if (inv.status != Status.Funded) revert InvalidStatus(inv.status);
        if (block.timestamp <= uint256(inv.dueDate) + gracePeriod) revert NotYetDefaultable();
        inv.status = Status.Defaulted;
        emit OfferDefaulted(invoiceId, msg.sender);
    }

    // ═════════════════════════ views ═════════════════════════

    function getInvoice(uint256 invoiceId) external view returns (Invoice memory) {
        return _get(invoiceId);
    }

    /// @notice Current holder of the repayment claim (this contract while listed, the investor once funded).
    function claimHolder(uint256 invoiceId) external view returns (address) {
        return ownerOf(invoiceId);
    }

    function isOverdue(uint256 invoiceId) external view returns (bool) {
        Invoice storage inv = _get(invoiceId);
        return (inv.status == Status.Funded || inv.status == Status.Defaulted) && block.timestamp > inv.dueDate;
    }

    function discountBpsOf(uint256 invoiceId) external view returns (uint256) {
        Invoice storage inv = _get(invoiceId);
        if (inv.advance == 0) return 0;
        return ((inv.faceValue - inv.advance) * 10_000) / inv.faceValue;
    }

    // ═════════════════════════ admin / configuration ═════════════════════════

    function setBusinessApproved(address business, bool approved) external onlyRole(VERIFIER_ROLE) {
        if (business == address(0)) revert ZeroAddress();
        businessApproved[business] = approved;
        emit BusinessApprovalUpdated(business, approved);
    }

    function setInvestorApproved(address investor, bool approved) external onlyRole(VERIFIER_ROLE) {
        if (investor == address(0)) revert ZeroAddress();
        investorApproved[investor] = approved;
        emit InvestorApprovalUpdated(investor, approved);
    }

    function setInvestorAllowlistEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        investorAllowlistEnabled = enabled;
        emit InvestorAllowlistToggled(enabled);
    }

    function setMaxDiscountBps(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps == 0 || bps > MAX_DISCOUNT_BPS_LIMIT) revert InvalidConfig();
        maxDiscountBps = bps;
        emit MaxDiscountUpdated(bps);
    }

    function setGracePeriod(uint256 seconds_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (seconds_ > MAX_GRACE_LIMIT) revert InvalidConfig();
        gracePeriod = seconds_;
        emit GracePeriodUpdated(seconds_);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Recover OTHER tokens sent here by mistake. The payment token can never be rescued, so this
    ///         cannot be used to touch any party's USDT (the contract holds none by design).
    function rescueERC20(IERC20 token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(token) == address(PAYMENT_TOKEN)) revert CannotRescuePaymentToken();
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
    }

    // ═════════════════════════ restricted claim token ═════════════════════════

    /// @dev Only this contract's own lifecycle logic may mint, move or burn the token.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (!_internalMove) revert TransfersRestricted();
        return super._update(to, tokenId, auth);
    }

    function approve(address, uint256) public pure override {
        revert TransfersRestricted();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert TransfersRestricted();
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // ═════════════════════════ internals ═════════════════════════

    function _moveClaim(address to, uint256 tokenId) private {
        _internalMove = true;
        _update(to, tokenId, address(0));
        _internalMove = false;
    }

    function _burnClaim(uint256 tokenId) private {
        _internalMove = true;
        _update(address(0), tokenId, address(0));
        _internalMove = false;
    }

    function _get(uint256 invoiceId) private view returns (Invoice storage inv) {
        inv = _invoices[invoiceId];
        if (inv.status == Status.None) revert UnknownInvoice();
    }

    function _requireBusinessOrOperator(address business) private view {
        if (msg.sender != business && !hasRole(OPERATOR_ROLE, msg.sender)) revert NotAuthorised();
    }
}
