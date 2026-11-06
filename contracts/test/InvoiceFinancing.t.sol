// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {InvoiceFinancing} from "../src/InvoiceFinancing.sol";
import {MockERC20, ReentrantERC20, FeeERC20} from "./mocks/Mocks.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract InvoiceFinancingTest is Test {
    InvoiceFinancing fin;
    MockERC20 usdt;

    address admin = makeAddr("admin");
    address issuer = makeAddr("issuer");
    address verifier = makeAddr("verifier");
    address operator = makeAddr("operator");
    address pauser = makeAddr("pauser");
    address business = makeAddr("business");
    address debtor = makeAddr("debtor");
    address investor = makeAddr("investor");
    address stranger = makeAddr("stranger");

    uint256 constant FACE = 10_000e6; // illustrative demo numbers (6 decimals in tests only)
    uint256 constant ADVANCE = 9_500e6;
    uint64 T0 = 1_700_000_000;

    bytes32 constant HASH = keccak256("invoice-data");
    bytes32 constant DOC = keccak256("invoice-pdf");
    bytes32 constant DEBTOR_REF = keccak256("debtor-ref");
    bytes32 constant ACK = keccak256("debtor-ack-evidence");

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

    function setUp() public {
        vm.warp(T0);
        usdt = new MockERC20(6);
        fin = new InvoiceFinancing(usdt, admin);
        vm.startPrank(admin);
        fin.grantRole(fin.ISSUER_ROLE(), issuer);
        fin.grantRole(fin.VERIFIER_ROLE(), verifier);
        fin.grantRole(fin.OPERATOR_ROLE(), operator);
        fin.grantRole(fin.PAUSER_ROLE(), pauser);
        vm.stopPrank();

        vm.startPrank(verifier);
        fin.setBusinessApproved(business, true);
        fin.setInvestorApproved(investor, true);
        vm.stopPrank();

        usdt.mint(investor, 100_000e6);
        usdt.mint(debtor, 100_000e6);
        vm.prank(investor);
        usdt.approve(address(fin), type(uint256).max);
        vm.prank(debtor);
        usdt.approve(address(fin), type(uint256).max);
    }

    // ───────── helpers ─────────
    function _params(bytes32 h) internal view returns (InvoiceFinancing.RegisterParams memory p) {
        p = InvoiceFinancing.RegisterParams({
            invoiceHash: h,
            documentHash: DOC,
            debtorRef: DEBTOR_REF,
            business: business,
            debtor: debtor,
            faceValue: FACE,
            issueDate: T0 - 1 days,
            dueDate: T0 + 30 days
        });
    }

    function _register() internal returns (uint256 id) {
        InvoiceFinancing.RegisterParams memory p = _params(HASH);
        vm.prank(business);
        id = fin.registerInvoice(p);
    }

    function _verified() internal returns (uint256 id) {
        id = _register();
        vm.prank(verifier);
        fin.verifyInvoice(id, ACK);
    }

    function _listed() internal returns (uint256 id) {
        id = _verified();
        vm.prank(business);
        fin.createOffer(id, ADVANCE, T0 + 7 days);
    }

    function _funded() internal returns (uint256 id) {
        id = _listed();
        vm.prank(investor);
        fin.fund(id);
    }

    function _status(uint256 id) internal view returns (InvoiceFinancing.Status) {
        return fin.getInvoice(id).status;
    }

    // ═════════ full lifecycle (the 10,000 / 9,500 / 30-day example) ═════════
    function test_fullLifecycle_registerVerifyListFundRepaySettle() public {
        uint256 bBefore = usdt.balanceOf(business);
        uint256 iBefore = usdt.balanceOf(investor);
        uint256 dBefore = usdt.balanceOf(debtor);

        InvoiceFinancing.RegisterParams memory p = _params(HASH);
        vm.expectEmit(true, true, true, true, address(fin));
        emit InvoiceRegistered(1, HASH, business, debtor, DEBTOR_REF, DOC, FACE, p.issueDate, p.dueDate, business);
        vm.prank(business);
        uint256 id = fin.registerInvoice(p);
        assertEq(id, 1);
        assertEq(fin.invoiceIdByHash(HASH), 1);

        vm.expectEmit(true, true, false, true, address(fin));
        emit InvoiceVerified(id, verifier, ACK);
        vm.prank(verifier);
        fin.verifyInvoice(id, ACK);

        vm.expectEmit(true, true, false, true, address(fin));
        emit OfferCreated(id, business, FACE, ADVANCE, 500, p.dueDate, T0 + 7 days);
        vm.prank(business);
        uint256 bps = fin.createOffer(id, ADVANCE, T0 + 7 days);
        assertEq(bps, 500); // 5.00% discount
        assertEq(fin.claimHolder(id), address(fin), "token held by contract while listed");
        assertEq(uint8(_status(id)), uint8(InvoiceFinancing.Status.Listed));

        vm.expectEmit(true, true, true, true, address(fin));
        emit OfferFunded(id, investor, business, ADVANCE);
        vm.prank(investor);
        fin.fund(id);
        assertEq(usdt.balanceOf(business), bBefore + ADVANCE);
        assertEq(usdt.balanceOf(investor), iBefore - ADVANCE);
        assertEq(fin.claimHolder(id), investor, "claim token moved to investor");
        assertEq(usdt.balanceOf(address(fin)), 0, "no custody");

        vm.warp(T0 + 30 days);
        assertFalse(fin.isOverdue(id));

        vm.expectEmit(true, true, true, true, address(fin));
        emit OfferRepaid(id, debtor, investor, FACE);
        vm.expectEmit(true, true, false, true, address(fin));
        emit OfferSettled(id, investor);
        vm.prank(debtor);
        fin.repay(id);

        assertEq(uint8(_status(id)), uint8(InvoiceFinancing.Status.Settled));
        assertEq(usdt.balanceOf(investor), iBefore - ADVANCE + FACE); // +500 discount earned
        assertEq(usdt.balanceOf(debtor), dBefore - FACE);
        assertEq(usdt.balanceOf(address(fin)), 0);
        assertEq(fin.getInvoice(id).settledAt, T0 + 30 days);
    }

    // ═════════ registration ═════════
    function test_register_byIssuerOnBehalfOfApprovedBusiness() public {
        InvoiceFinancing.RegisterParams memory p = _params(HASH);
        vm.prank(issuer);
        uint256 id = fin.registerInvoice(p);
        assertEq(fin.getInvoice(id).business, business);
    }

    function test_register_revert_duplicateHash() public {
        _register();
        InvoiceFinancing.RegisterParams memory p = _params(HASH);
        vm.prank(business);
        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancing.DuplicateInvoice.selector, 1));
        fin.registerInvoice(p);
    }

    function test_register_revert_unauthorisedCaller() public {
        InvoiceFinancing.RegisterParams memory p = _params(HASH);
        vm.prank(stranger);
        vm.expectRevert(InvoiceFinancing.NotAuthorised.selector);
        fin.registerInvoice(p);
    }

    function test_register_revert_unapprovedBusiness() public {
        InvoiceFinancing.RegisterParams memory p = _params(HASH);
        p.business = stranger;
        vm.prank(stranger);
        vm.expectRevert(InvoiceFinancing.BusinessNotApproved.selector);
        fin.registerInvoice(p);
    }

    function test_register_revert_invalidInputs() public {
        InvoiceFinancing.RegisterParams memory p = _params(HASH);
        p.faceValue = 0;
        vm.prank(business);
        vm.expectRevert(InvoiceFinancing.InvalidAmount.selector);
        fin.registerInvoice(p);

        p = _params(bytes32(0));
        vm.prank(business);
        vm.expectRevert(InvoiceFinancing.InvalidReference.selector);
        fin.registerInvoice(p);

        p = _params(HASH);
        p.documentHash = bytes32(0);
        vm.prank(business);
        vm.expectRevert(InvoiceFinancing.InvalidReference.selector);
        fin.registerInvoice(p);

        p = _params(HASH);
        p.debtorRef = bytes32(0);
        vm.prank(business);
        vm.expectRevert(InvoiceFinancing.InvalidReference.selector);
        fin.registerInvoice(p);

        p = _params(HASH);
        p.dueDate = T0 - 1; // already due
        vm.prank(business);
        vm.expectRevert(InvoiceFinancing.InvalidDates.selector);
        fin.registerInvoice(p);

        p = _params(HASH);
        p.issueDate = T0 + 1 days; // issued in the future
        vm.prank(business);
        vm.expectRevert(InvoiceFinancing.InvalidDates.selector);
        fin.registerInvoice(p);

        p = _params(HASH);
        p.business = address(0);
        vm.prank(business);
        vm.expectRevert(InvoiceFinancing.ZeroAddress.selector);
        fin.registerInvoice(p);
    }

    function test_register_revert_whenPaused() public {
        vm.prank(pauser);
        fin.pause();
        InvoiceFinancing.RegisterParams memory p = _params(HASH);
        vm.prank(business);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        fin.registerInvoice(p);
    }

    // ═════════ verification ═════════
    function test_verify_onlyVerifier_andOnlyOnce() public {
        uint256 id = _register();
        vm.prank(stranger);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        fin.verifyInvoice(id, ACK);

        vm.prank(verifier);
        vm.expectRevert(InvoiceFinancing.InvalidReference.selector);
        fin.verifyInvoice(id, bytes32(0));

        vm.prank(verifier);
        fin.verifyInvoice(id, ACK);
        assertEq(fin.getInvoice(id).debtorAckRef, ACK);

        vm.prank(verifier);
        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancing.InvalidStatus.selector, InvoiceFinancing.Status.Verified));
        fin.verifyInvoice(id, ACK);
    }

    function test_verify_revert_unknownInvoice() public {
        vm.prank(verifier);
        vm.expectRevert(InvoiceFinancing.UnknownInvoice.selector);
        fin.verifyInvoice(99, ACK);
    }

    function test_reject_keepsHashUsed_andBlocksFinancing() public {
        uint256 id = _register();
        vm.prank(verifier);
        fin.rejectInvoice(id, keccak256("reason"));
        assertEq(uint8(_status(id)), uint8(InvoiceFinancing.Status.Rejected));

        vm.prank(business);
        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancing.InvalidStatus.selector, InvoiceFinancing.Status.Rejected));
        fin.createOffer(id, ADVANCE, T0 + 1 days);

        InvoiceFinancing.RegisterParams memory p = _params(HASH);
        vm.prank(business);
        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancing.DuplicateInvoice.selector, id));
        fin.registerInvoice(p);
    }

    function test_unverifiedInvoice_cannotBeListed() public {
        uint256 id = _register();
        vm.prank(business);
        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancing.InvalidStatus.selector, InvoiceFinancing.Status.Registered));
        fin.createOffer(id, ADVANCE, T0 + 1 days);
    }

    function test_cancelInvoice_beforeListing() public {
        uint256 id = _verified();
        vm.prank(stranger);
        vm.expectRevert(InvoiceFinancing.NotAuthorised.selector);
        fin.cancelInvoice(id);

        vm.prank(business);
        fin.cancelInvoice(id);
        assertEq(uint8(_status(id)), uint8(InvoiceFinancing.Status.Cancelled));
    }

    // ═════════ offer creation ═════════
    function test_createOffer_byOperatorOnBehalf() public {
        uint256 id = _verified();
        vm.prank(operator);
        fin.createOffer(id, ADVANCE, T0 + 7 days);
        assertEq(uint8(_status(id)), uint8(InvoiceFinancing.Status.Listed));
        assertEq(fin.ownerOf(id), address(fin));
    }

    function test_createOffer_revert_unauthorised() public {
        uint256 id = _verified();
        vm.prank(stranger);
        vm.expectRevert(InvoiceFinancing.NotAuthorised.selector);
        fin.createOffer(id, ADVANCE, T0 + 7 days);
    }

    function test_createOffer_revert_badTerms() public {
        uint256 id = _verified();
        vm.startPrank(business);
        vm.expectRevert(InvoiceFinancing.InvalidAmount.selector);
        fin.createOffer(id, 0, T0 + 7 days);
        vm.expectRevert(InvoiceFinancing.InvalidAmount.selector);
        fin.createOffer(id, FACE, T0 + 7 days);
        vm.expectRevert(InvoiceFinancing.InvalidDates.selector);
        fin.createOffer(id, ADVANCE, T0); // deadline not in the future
        vm.expectRevert(InvoiceFinancing.InvalidDates.selector);
        fin.createOffer(id, ADVANCE, T0 + 31 days); // deadline after maturity
        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancing.DiscountTooHigh.selector, 5000, 2000));
        fin.createOffer(id, 5_000e6, T0 + 7 days);
        vm.stopPrank();
    }

    function test_createOffer_revert_twice() public {
        uint256 id = _listed();
        vm.prank(business);
        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancing.InvalidStatus.selector, InvoiceFinancing.Status.Listed));
        fin.createOffer(id, ADVANCE, T0 + 7 days);
    }

    // ═════════ funding ═════════
    function test_fund_revert_twice_oneTimeFunding() public {
        uint256 id = _funded();
        address investor2 = makeAddr("investor2");
        vm.prank(verifier);
        fin.setInvestorApproved(investor2, true);
        usdt.mint(investor2, FACE);
        vm.startPrank(investor2);
        usdt.approve(address(fin), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancing.InvalidStatus.selector, InvoiceFinancing.Status.Funded));
        fin.fund(id);
        vm.stopPrank();
        assertEq(fin.getInvoice(id).investor, investor);
    }

    function test_fund_revert_afterDeadline() public {
        uint256 id = _listed();
        vm.warp(T0 + 7 days + 1);
        vm.prank(investor);
        vm.expectRevert(InvoiceFinancing.FundingClosed.selector);
        fin.fund(id);
    }

    function test_fund_revert_investorNotApproved_thenAllowlistDisabled() public {
        uint256 id = _listed();
        usdt.mint(stranger, FACE);
        vm.startPrank(stranger);
        usdt.approve(address(fin), type(uint256).max);
        vm.expectRevert(InvoiceFinancing.InvestorNotApproved.selector);
        fin.fund(id);
        vm.stopPrank();

        vm.prank(admin);
        fin.setInvestorAllowlistEnabled(false);
        vm.prank(stranger);
        fin.fund(id);
        assertEq(fin.claimHolder(id), stranger);
    }

    function test_fund_revert_businessCannotFundOwnOffer() public {
        uint256 id = _listed();
        vm.prank(verifier);
        fin.setInvestorApproved(business, true);
        usdt.mint(business, FACE);
        vm.startPrank(business);
        usdt.approve(address(fin), type(uint256).max);
        vm.expectRevert(InvoiceFinancing.SelfDealing.selector);
        fin.fund(id);
        vm.stopPrank();
    }

    function test_fund_revert_insufficientAllowance() public {
        uint256 id = _listed();
        vm.prank(investor);
        usdt.approve(address(fin), ADVANCE - 1);
        vm.prank(investor);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        fin.fund(id);
        // failed tx leaves state untouched
        assertEq(uint8(_status(id)), uint8(InvoiceFinancing.Status.Listed));
        assertEq(fin.claimHolder(id), address(fin));
    }

    function test_fund_revert_whenPaused() public {
        uint256 id = _listed();
        vm.prank(pauser);
        fin.pause();
        vm.prank(investor);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        fin.fund(id);
    }

    // ═════════ cancel / expire ═════════
    function test_cancelOffer_burnsToken_andBlocksFunding() public {
        uint256 id = _listed();
        vm.prank(stranger);
        vm.expectRevert(InvoiceFinancing.NotAuthorised.selector);
        fin.cancelOffer(id);

        vm.prank(business);
        fin.cancelOffer(id);
        assertEq(uint8(_status(id)), uint8(InvoiceFinancing.Status.Cancelled));
        vm.expectRevert(); // token burned
        fin.ownerOf(id);

        vm.prank(investor);
        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancing.InvalidStatus.selector, InvoiceFinancing.Status.Cancelled));
        fin.fund(id);
    }

    function test_expireOffer_onlyAfterDeadline_byAnyone() public {
        uint256 id = _listed();
        vm.prank(stranger);
        vm.expectRevert(InvoiceFinancing.FundingStillOpen.selector);
        fin.expireOffer(id);

        vm.warp(T0 + 7 days + 1);
        vm.prank(stranger);
        fin.expireOffer(id);
        assertEq(uint8(_status(id)), uint8(InvoiceFinancing.Status.Expired));
        vm.expectRevert();
        fin.ownerOf(id);
    }

    function test_cancelOffer_revert_afterFunded() public {
        uint256 id = _funded();
        vm.prank(business);
        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancing.InvalidStatus.selector, InvoiceFinancing.Status.Funded));
        fin.cancelOffer(id);
    }

    // ═════════ repayment / settlement / default ═════════
    function test_repay_byThirdParty_paysCurrentClaimHolder() public {
        uint256 id = _funded();
        usdt.mint(stranger, FACE);
        vm.startPrank(stranger);
        usdt.approve(address(fin), type(uint256).max);
        fin.repay(id);
        vm.stopPrank();
        assertEq(uint8(_status(id)), uint8(InvoiceFinancing.Status.Settled));
        assertEq(usdt.balanceOf(stranger), 0);
    }

    function test_repay_revert_twice_duplicateSettlement() public {
        uint256 id = _funded();
        vm.prank(debtor);
        fin.repay(id);
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancing.InvalidStatus.selector, InvoiceFinancing.Status.Settled));
        fin.repay(id);
    }

    function test_repay_revert_beforeFunding() public {
        uint256 id = _listed();
        vm.prank(debtor);
        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancing.InvalidStatus.selector, InvoiceFinancing.Status.Listed));
        fin.repay(id);
    }

    function test_repay_revert_investorCannotRepayToSelf() public {
        uint256 id = _funded();
        vm.prank(investor);
        vm.expectRevert(InvoiceFinancing.SelfDealing.selector);
        fin.repay(id);
    }

    function test_repay_revert_insufficientBalance_leavesStateUntouched() public {
        uint256 id = _funded();
        address poor = makeAddr("poor");
        vm.startPrank(poor);
        usdt.approve(address(fin), type(uint256).max);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientBalance.selector);
        fin.repay(id);
        vm.stopPrank();
        assertEq(uint8(_status(id)), uint8(InvoiceFinancing.Status.Funded));
    }

    function test_repay_worksWhilePaused() public {
        uint256 id = _funded();
        vm.prank(pauser);
        fin.pause();
        vm.prank(debtor);
        fin.repay(id);
        assertEq(uint8(_status(id)), uint8(InvoiceFinancing.Status.Settled));
    }

    function test_markDefaulted_afterGrace_thenLateRepaymentStillSettles() public {
        uint256 id = _funded();
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancing.NotYetDefaultable.selector));
        fin.markDefaulted(id);

        vm.warp(T0 + 30 days + 7 days); // exactly end of grace: still not defaultable
        vm.prank(operator);
        vm.expectRevert(InvoiceFinancing.NotYetDefaultable.selector);
        fin.markDefaulted(id);
        assertTrue(fin.isOverdue(id));

        vm.warp(T0 + 30 days + 7 days + 1);
        // permissionless: any keeper / stranger may flag the default (informational, moves no funds)
        vm.prank(stranger);
        fin.markDefaulted(id);
        assertEq(uint8(_status(id)), uint8(InvoiceFinancing.Status.Defaulted));

        uint256 before_ = usdt.balanceOf(investor);
        vm.prank(debtor);
        fin.repay(id);
        assertEq(uint8(_status(id)), uint8(InvoiceFinancing.Status.Settled));
        assertEq(usdt.balanceOf(investor), before_ + FACE);
    }

    function test_markDefaulted_revert_notFunded() public {
        uint256 id = _listed();
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancing.InvalidStatus.selector, InvoiceFinancing.Status.Listed));
        fin.markDefaulted(id);
    }

    // ═════════ restricted claim token ═════════
    function test_claimToken_isNonTransferable() public {
        uint256 id = _funded();
        vm.startPrank(investor);
        vm.expectRevert(InvoiceFinancing.TransfersRestricted.selector);
        fin.transferFrom(investor, stranger, id);
        vm.expectRevert(InvoiceFinancing.TransfersRestricted.selector);
        fin.safeTransferFrom(investor, stranger, id);
        vm.expectRevert(InvoiceFinancing.TransfersRestricted.selector);
        fin.approve(stranger, id);
        vm.expectRevert(InvoiceFinancing.TransfersRestricted.selector);
        fin.setApprovalForAll(stranger, true);
        vm.stopPrank();
        assertEq(fin.ownerOf(id), investor);
    }

    function test_claimToken_cannotBeMovedByAdminOrOperator() public {
        uint256 id = _funded();
        vm.prank(admin);
        vm.expectRevert(); // not owner/approved (and restricted)
        fin.transferFrom(investor, admin, id);
        vm.prank(operator);
        vm.expectRevert();
        fin.transferFrom(investor, operator, id);
        assertEq(fin.ownerOf(id), investor);
    }

    // ═════════ admin / configuration ═════════
    function test_config_boundsAndAccess() public {
        vm.startPrank(admin);
        fin.setMaxDiscountBps(1000);
        assertEq(fin.maxDiscountBps(), 1000);
        vm.expectRevert(InvoiceFinancing.InvalidConfig.selector);
        fin.setMaxDiscountBps(0);
        vm.expectRevert(InvoiceFinancing.InvalidConfig.selector);
        fin.setMaxDiscountBps(5001);
        fin.setGracePeriod(1 days);
        vm.expectRevert(InvoiceFinancing.InvalidConfig.selector);
        fin.setGracePeriod(91 days);
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        fin.setMaxDiscountBps(1000);
        vm.prank(stranger);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        fin.setBusinessApproved(stranger, true);
        vm.prank(stranger);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        fin.pause();
    }

    function test_rescue_cannotTouchPaymentToken_butRecoversOthers() public {
        MockERC20 other = new MockERC20(18);
        other.mint(address(fin), 5 ether);
        usdt.mint(address(fin), 1e6);

        vm.startPrank(admin);
        vm.expectRevert(InvoiceFinancing.CannotRescuePaymentToken.selector);
        fin.rescueERC20(IERC20(address(usdt)), admin, 1e6);
        fin.rescueERC20(IERC20(address(other)), admin, 5 ether);
        vm.stopPrank();
        assertEq(other.balanceOf(admin), 5 ether);
        assertEq(usdt.balanceOf(address(fin)), 1e6);
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(InvoiceFinancing.ZeroAddress.selector);
        new InvoiceFinancing(MockERC20(address(0)), admin);
        vm.expectRevert(InvoiceFinancing.ZeroAddress.selector);
        new InvoiceFinancing(usdt, address(0));
    }

    // ═════════ hostile tokens ═════════
    function test_fund_revert_feeOnTransferToken() public {
        FeeERC20 fee = new FeeERC20();
        InvoiceFinancing f2 = new InvoiceFinancing(fee, admin);
        vm.startPrank(admin);
        f2.grantRole(f2.VERIFIER_ROLE(), verifier);
        vm.stopPrank();
        vm.startPrank(verifier);
        f2.setBusinessApproved(business, true);
        f2.setInvestorApproved(investor, true);
        vm.stopPrank();

        InvoiceFinancing.RegisterParams memory p = _params(HASH);
        vm.prank(business);
        uint256 id = f2.registerInvoice(p);
        vm.prank(verifier);
        f2.verifyInvoice(id, ACK);
        vm.prank(business);
        f2.createOffer(id, ADVANCE, T0 + 7 days);

        fee.mint(investor, FACE);
        vm.startPrank(investor);
        fee.approve(address(f2), type(uint256).max);
        vm.expectRevert(InvoiceFinancing.UnexpectedTransferAmount.selector);
        f2.fund(id);
        vm.stopPrank();
    }

    function _reentrantSetup() internal returns (ReentrantERC20 evil, InvoiceFinancing f2, uint256 id) {
        evil = new ReentrantERC20();
        f2 = new InvoiceFinancing(evil, admin);
        bytes32 verifierRole = f2.VERIFIER_ROLE();
        vm.prank(admin);
        f2.grantRole(verifierRole, verifier);
        vm.startPrank(verifier);
        f2.setBusinessApproved(business, true);
        f2.setInvestorApproved(investor, true);
        vm.stopPrank();

        InvoiceFinancing.RegisterParams memory p = _params(HASH);
        vm.prank(business);
        id = f2.registerInvoice(p);
        vm.prank(verifier);
        f2.verifyInvoice(id, ACK);
        vm.prank(business);
        f2.createOffer(id, ADVANCE, T0 + 7 days);

        evil.mint(investor, FACE);
        evil.mint(debtor, FACE);
        vm.prank(investor);
        evil.approve(address(f2), type(uint256).max);
        vm.prank(debtor);
        evil.approve(address(f2), type(uint256).max);
    }

    function test_reentrancy_fund_isBlocked() public {
        (ReentrantERC20 evil, InvoiceFinancing f2, uint256 id) = _reentrantSetup();
        evil.arm(address(f2), abi.encodeCall(InvoiceFinancing.fund, (id)));
        vm.prank(investor);
        f2.fund(id);
        assertFalse(evil.reentrySucceeded());
        assertEq(bytes4(evil.reentryRevertData()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(evil.balanceOf(business), ADVANCE, "advance paid exactly once");
    }

    function test_reentrancy_repay_isBlocked() public {
        (ReentrantERC20 evil, InvoiceFinancing f2, uint256 id) = _reentrantSetup();
        vm.prank(investor);
        f2.fund(id);
        evil.arm(address(f2), abi.encodeCall(InvoiceFinancing.repay, (id)));
        vm.prank(debtor);
        f2.repay(id);
        assertFalse(evil.reentrySucceeded());
        assertEq(bytes4(evil.reentryRevertData()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(evil.balanceOf(investor), FACE - ADVANCE + FACE, "investor paid back exactly once");
        assertEq(evil.balanceOf(debtor), 0, "debtor charged exactly once");
    }

    // ═════════ fuzz ═════════
    function testFuzz_lifecycleConservesFunds(uint256 advance) public {
        // discount must be between 0 (exclusive) and the 20% cap
        advance = bound(advance, (FACE * 8000) / 10_000, FACE - 1);
        uint256 id = _verified();
        vm.prank(business);
        fin.createOffer(id, advance, T0 + 7 days);

        uint256 invBefore = usdt.balanceOf(investor);
        uint256 busBefore = usdt.balanceOf(business);
        uint256 debBefore = usdt.balanceOf(debtor);

        vm.prank(investor);
        fin.fund(id);
        vm.prank(debtor);
        fin.repay(id);

        assertEq(usdt.balanceOf(business), busBefore + advance);
        assertEq(usdt.balanceOf(investor), invBefore + (FACE - advance));
        assertEq(usdt.balanceOf(debtor), debBefore - FACE);
        assertEq(usdt.balanceOf(address(fin)), 0);
    }

    function testFuzz_discountAboveCapAlwaysReverts(uint256 advance) public {
        advance = bound(advance, 1, (FACE * 8000) / 10_000 - 1);
        uint256 id = _verified();
        vm.prank(business);
        vm.expectPartialRevert(InvoiceFinancing.DiscountTooHigh.selector);
        fin.createOffer(id, advance, T0 + 7 days);
    }
    // ═════════ financing limits (exposure cap / max advance) ═════════
    function _newInvoice(bytes32 h, uint256 face) internal returns (uint256 id) {
        InvoiceFinancing.RegisterParams memory p = _params(h);
        p.faceValue = face;
        vm.prank(business);
        id = fin.registerInvoice(p);
        vm.prank(verifier);
        fin.verifyInvoice(id, ACK);
    }

    function test_limits_defaultToUnlimited() public {
        assertEq(fin.maxAdvancePerInvoice(), 0);
        assertEq(fin.defaultBusinessExposureCap(), 0);
        assertEq(fin.exposureCapOf(business), 0);
        _listed();
        assertEq(fin.businessExposure(business), ADVANCE);
    }

    function test_maxAdvancePerInvoice_enforced() public {
        vm.prank(admin);
        fin.setMaxAdvancePerInvoice(5_000e6);
        uint256 id = _verified();
        vm.prank(business);
        vm.expectRevert(abi.encodeWithSelector(InvoiceFinancing.AdvanceTooHigh.selector, ADVANCE, 5_000e6));
        fin.createOffer(id, ADVANCE, T0 + 7 days);
        vm.prank(business);
        // 5,000 of 10,000 face is a 50% discount > 20% max, so the discount rule still applies first-class
        vm.expectRevert();
        fin.createOffer(id, 5_000e6, T0 + 7 days);
        // raise the limit exactly to the advance: allowed (boundary)
        vm.prank(admin);
        fin.setMaxAdvancePerInvoice(ADVANCE);
        vm.prank(business);
        fin.createOffer(id, ADVANCE, T0 + 7 days);
    }

    function test_exposureCap_enforcedAcrossInvoices_andReleasedOnCancelExpireSettle() public {
        vm.prank(admin);
        fin.setDefaultBusinessExposureCap(ADVANCE + 100e6); // room for one 9,500 advance only
        uint256 a = _newInvoice(keccak256("a"), FACE);
        uint256 b = _newInvoice(keccak256("b"), FACE);
        vm.prank(business);
        fin.createOffer(a, ADVANCE, T0 + 7 days);
        assertEq(fin.businessExposure(business), ADVANCE);

        vm.prank(business);
        vm.expectRevert(
            abi.encodeWithSelector(InvoiceFinancing.ExposureCapExceeded.selector, 2 * ADVANCE, ADVANCE + 100e6)
        );
        fin.createOffer(b, ADVANCE, T0 + 7 days);

        // cancel releases
        vm.prank(business);
        fin.cancelOffer(a);
        assertEq(fin.businessExposure(business), 0);
        vm.prank(business);
        fin.createOffer(b, ADVANCE, T0 + 7 days);

        // expiry releases
        vm.warp(T0 + 7 days + 1);
        fin.expireOffer(b);
        assertEq(fin.businessExposure(business), 0);

        // funded stays reserved until settled
        uint256 c = _newInvoice(keccak256("c"), FACE);
        vm.prank(business);
        fin.createOffer(c, ADVANCE, T0 + 20 days);
        vm.prank(investor);
        fin.fund(c);
        assertEq(fin.businessExposure(business), ADVANCE);
        vm.prank(debtor);
        fin.repay(c);
        assertEq(fin.businessExposure(business), 0);
    }

    function test_exposure_defaultedStaysReservedUntilRepaid() public {
        vm.prank(admin);
        fin.setDefaultBusinessExposureCap(ADVANCE);
        uint256 id = _funded();
        vm.warp(T0 + 30 days + 7 days + 1);
        fin.markDefaulted(id);
        assertEq(fin.businessExposure(business), ADVANCE);
        vm.prank(debtor);
        fin.repay(id);
        assertEq(fin.businessExposure(business), 0);
    }

    function test_perBusinessOverride_beatsDefault_andZeroFallsBack() public {
        vm.prank(admin);
        fin.setDefaultBusinessExposureCap(1_000e6);
        vm.prank(verifier);
        fin.setBusinessExposureCap(business, ADVANCE);
        assertEq(fin.exposureCapOf(business), ADVANCE);
        _listed(); // fits the override
        vm.prank(verifier);
        fin.setBusinessExposureCap(business, 0);
        assertEq(fin.exposureCapOf(business), 1_000e6);
    }

    function test_limitSetters_accessControl() public {
        vm.startPrank(stranger);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        fin.setMaxAdvancePerInvoice(1);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        fin.setDefaultBusinessExposureCap(1);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        fin.setBusinessExposureCap(business, 1);
        vm.stopPrank();
        vm.prank(verifier);
        vm.expectRevert(InvoiceFinancing.ZeroAddress.selector);
        fin.setBusinessExposureCap(address(0), 1);
    }

    function test_timeToMaturity() public {
        uint256 id = _funded();
        assertEq(fin.timeToMaturity(id), 30 days);
        vm.warp(T0 + 10 days);
        assertEq(fin.timeToMaturity(id), 20 days);
        vm.warp(T0 + 31 days);
        assertEq(fin.timeToMaturity(id), 0);
    }
}
