// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BillFlowPayments} from "../src/BillFlowPayments.sol";
import {MockERC20, ReentrantERC20, FeeERC20} from "./mocks/Mocks.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract BillFlowPaymentsTest is Test {
    BillFlowPayments pay;
    MockERC20 usdt;

    uint256 signerKey = 0xA11CE;
    address signer;
    address admin = makeAddr("admin");
    address pauser = makeAddr("pauser");
    address merchant = makeAddr("merchant");
    address payer = makeAddr("payer");
    address other = makeAddr("other");

    bytes32 constant INV = keccak256("invoice-1");
    bytes32 constant INV_HASH = keccak256("invoice-1-data");
    uint256 constant TOTAL = 1_000e6; // 1,000 units at 6 decimals (tests only)

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

    function setUp() public {
        vm.warp(1_700_000_000);
        signer = vm.addr(signerKey);
        usdt = new MockERC20(6);
        pay = new BillFlowPayments(usdt, admin, signer, pauser);
        usdt.mint(payer, 10_000e6);
        vm.prank(payer);
        usdt.approve(address(pay), type(uint256).max);
    }

    // ───────── helpers ─────────
    function _q(uint256 amount, uint256 nonce) internal view returns (BillFlowPayments.Quote memory q) {
        q = BillFlowPayments.Quote({
            invoiceId: INV,
            invoiceHash: INV_HASH,
            merchant: merchant,
            payer: payer,
            amount: amount,
            invoiceTotal: TOTAL,
            nonce: nonce,
            expiry: uint64(block.timestamp + 15 minutes)
        });
    }

    function _sign(BillFlowPayments.Quote memory q, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, pay.hashQuote(q));
        return abi.encodePacked(r, s, v);
    }

    function _pay(uint256 amount, uint256 nonce) internal returns (uint256) {
        BillFlowPayments.Quote memory q = _q(amount, nonce);
        bytes memory sig = _sign(q, signerKey);
        vm.prank(payer);
        return pay.payInvoice(q, sig);
    }

    // ───────── happy paths ─────────
    function test_fullPayment_goesDirectlyToMerchant_andEmitsEvent() public {
        BillFlowPayments.Quote memory q = _q(TOTAL, 1);
        bytes memory sig = _sign(q, signerKey);

        vm.expectEmit(true, true, true, true, address(pay));
        emit InvoicePaid(INV, 1, payer, merchant, TOTAL, TOTAL, TOTAL, INV_HASH);
        vm.prank(payer);
        uint256 id = pay.payInvoice(q, sig);

        assertEq(id, 1);
        assertEq(usdt.balanceOf(merchant), TOTAL);
        assertEq(usdt.balanceOf(address(pay)), 0, "contract must never hold funds");
        assertTrue(pay.isInvoicePaid(INV));
        assertEq(pay.remainingAmount(INV), 0);
        BillFlowPayments.InvoicePayment memory s = pay.getInvoicePaymentStatus(INV);
        assertEq(uint8(s.status), uint8(BillFlowPayments.PaymentStatus.Paid));
        assertEq(s.totalPaid, TOTAL);
        assertEq(s.paymentCount, 1);
        BillFlowPayments.PaymentRecord memory r = pay.getPayment(1);
        assertEq(r.payer, payer);
        assertEq(r.merchant, merchant);
        assertEq(r.amount, TOTAL);
        assertEq(r.invoiceId, INV);
        assertEq(r.paidAt, block.timestamp);
    }

    function test_partialPayments_thenComplete() public {
        _pay(400e6, 1);
        BillFlowPayments.InvoicePayment memory s = pay.getInvoicePaymentStatus(INV);
        assertEq(uint8(s.status), uint8(BillFlowPayments.PaymentStatus.PartiallyPaid));
        assertFalse(pay.isInvoicePaid(INV));
        assertEq(pay.remainingAmount(INV), 600e6);

        _pay(600e6, 2);
        assertTrue(pay.isInvoicePaid(INV));
        assertEq(usdt.balanceOf(merchant), TOTAL);
        assertEq(pay.paymentCount(), 2);
    }

    function test_independentEip712Digest_matchesContract() public view {
        BillFlowPayments.Quote memory q = _q(123, 7);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Quote(bytes32 invoiceId,bytes32 invoiceHash,address merchant,address payer,uint256 amount,uint256 invoiceTotal,uint256 nonce,uint64 expiry)"
                ),
                q.invoiceId,
                q.invoiceHash,
                q.merchant,
                q.payer,
                q.amount,
                q.invoiceTotal,
                q.nonce,
                q.expiry
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", pay.DOMAIN_SEPARATOR(), structHash));
        assertEq(digest, pay.hashQuote(q));
    }

    // ───────── duplicate / replay protection ─────────
    function test_revert_duplicateFullPayment() public {
        _pay(TOTAL, 1);
        BillFlowPayments.Quote memory q = _q(TOTAL, 2);
        bytes memory sig = _sign(q, signerKey);
        vm.prank(payer);
        vm.expectRevert(BillFlowPayments.AlreadyPaid.selector);
        pay.payInvoice(q, sig);
    }

    function test_revert_replayedNonce() public {
        BillFlowPayments.Quote memory q = _q(100e6, 1);
        bytes memory sig = _sign(q, signerKey);
        vm.startPrank(payer);
        pay.payInvoice(q, sig);
        vm.expectRevert(BillFlowPayments.NonceUsed.selector);
        pay.payInvoice(q, sig);
        vm.stopPrank();
    }

    function test_revert_overpayment() public {
        _pay(900e6, 1);
        BillFlowPayments.Quote memory q = _q(200e6, 2);
        bytes memory sig = _sign(q, signerKey);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(BillFlowPayments.Overpayment.selector, 100e6));
        pay.payInvoice(q, sig);
    }

    function test_revert_quoteForSameInvoiceWithDifferentTerms() public {
        _pay(100e6, 1);
        BillFlowPayments.Quote memory q = _q(100e6, 2);
        q.merchant = other;
        bytes memory sig = _sign(q, signerKey);
        vm.prank(payer);
        vm.expectRevert(BillFlowPayments.InvoiceMismatch.selector);
        pay.payInvoice(q, sig);

        q = _q(100e6, 3);
        q.invoiceTotal = TOTAL * 2;
        sig = _sign(q, signerKey);
        vm.prank(payer);
        vm.expectRevert(BillFlowPayments.InvoiceMismatch.selector);
        pay.payInvoice(q, sig);

        q = _q(100e6, 4);
        q.invoiceHash = keccak256("different");
        sig = _sign(q, signerKey);
        vm.prank(payer);
        vm.expectRevert(BillFlowPayments.InvoiceMismatch.selector);
        pay.payInvoice(q, sig);
    }

    // ───────── authorisation ─────────
    function test_revert_expiredQuote() public {
        BillFlowPayments.Quote memory q = _q(100e6, 1);
        bytes memory sig = _sign(q, signerKey);
        vm.warp(block.timestamp + 16 minutes);
        vm.prank(payer);
        vm.expectRevert(BillFlowPayments.QuoteExpired.selector);
        pay.payInvoice(q, sig);
    }

    function test_revert_wrongSigner() public {
        BillFlowPayments.Quote memory q = _q(100e6, 1);
        bytes memory sig = _sign(q, 0xBAD);
        vm.prank(payer);
        vm.expectRevert(BillFlowPayments.InvalidSignature.selector);
        pay.payInvoice(q, sig);
    }

    function test_revert_tamperedAmount() public {
        BillFlowPayments.Quote memory q = _q(100e6, 1);
        bytes memory sig = _sign(q, signerKey);
        q.amount = 900e6;
        vm.prank(payer);
        vm.expectRevert(BillFlowPayments.InvalidSignature.selector);
        pay.payInvoice(q, sig);
    }

    function test_revert_tamperedMerchant() public {
        BillFlowPayments.Quote memory q = _q(100e6, 1);
        bytes memory sig = _sign(q, signerKey);
        q.merchant = other;
        vm.prank(payer);
        vm.expectRevert(BillFlowPayments.InvalidSignature.selector);
        pay.payInvoice(q, sig);
    }

    function test_revert_callerIsNotQuotedPayer() public {
        BillFlowPayments.Quote memory q = _q(100e6, 1);
        bytes memory sig = _sign(q, signerKey);
        vm.prank(other);
        vm.expectRevert(BillFlowPayments.NotPayer.selector);
        pay.payInvoice(q, sig);
    }

    function _expectInvalid(BillFlowPayments.Quote memory q, bytes4 selector) internal {
        bytes memory sig = _sign(q, signerKey);
        vm.prank(payer);
        vm.expectRevert(selector);
        pay.payInvoice(q, sig);
    }

    function test_revert_invalidInputs() public {
        _expectInvalid(_q(0, 1), BillFlowPayments.InvalidAmount.selector);

        BillFlowPayments.Quote memory q = _q(1, 2);
        q.merchant = address(0);
        _expectInvalid(q, BillFlowPayments.ZeroAddress.selector);

        q = _q(1, 3);
        q.merchant = payer;
        _expectInvalid(q, BillFlowPayments.SelfPayment.selector);

        q = _q(1, 4);
        q.invoiceId = bytes32(0);
        _expectInvalid(q, BillFlowPayments.InvalidInvoice.selector);
    }

    function test_revert_insufficientAllowance() public {
        address poor = makeAddr("poor");
        usdt.mint(poor, TOTAL);
        BillFlowPayments.Quote memory q = _q(100e6, 1);
        q.payer = poor;
        bytes memory sig = _sign(q, signerKey);
        vm.prank(poor);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        pay.payInvoice(q, sig);
    }

    // ───────── admin ─────────
    function test_pause_blocksPayments_unpauseRestores() public {
        vm.prank(pauser);
        pay.pause();
        BillFlowPayments.Quote memory q = _q(100e6, 1);
        bytes memory sig = _sign(q, signerKey);
        vm.prank(payer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pay.payInvoice(q, sig);

        vm.prank(pauser);
        pay.unpause();
        vm.prank(payer);
        pay.payInvoice(q, sig);
    }

    function test_pause_onlyPauser() public {
        vm.prank(other);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        pay.pause();
    }

    function test_setQuoteSigner_onlyAdmin_andInvalidatesOldQuotes() public {
        BillFlowPayments.Quote memory q = _q(100e6, 1);
        bytes memory sig = _sign(q, signerKey);

        vm.prank(other);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        pay.setQuoteSigner(other);

        vm.prank(admin);
        pay.setQuoteSigner(makeAddr("newSigner"));

        vm.prank(payer);
        vm.expectRevert(BillFlowPayments.InvalidSignature.selector);
        pay.payInvoice(q, sig);

        vm.prank(admin);
        vm.expectRevert(BillFlowPayments.ZeroAddress.selector);
        pay.setQuoteSigner(address(0));
    }

    function test_revokeNonce() public {
        BillFlowPayments.Quote memory q = _q(100e6, 5);
        bytes memory sig = _sign(q, signerKey);

        vm.prank(other);
        vm.expectRevert(BillFlowPayments.NotAuthorised.selector);
        pay.revokeNonce(5);

        vm.prank(signer);
        pay.revokeNonce(5);

        vm.prank(payer);
        vm.expectRevert(BillFlowPayments.NonceUsed.selector);
        pay.payInvoice(q, sig);
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(BillFlowPayments.ZeroAddress.selector);
        new BillFlowPayments(MockERC20(address(0)), admin, signer, pauser);
        vm.expectRevert(BillFlowPayments.ZeroAddress.selector);
        new BillFlowPayments(usdt, address(0), signer, pauser);
        vm.expectRevert(BillFlowPayments.ZeroAddress.selector);
        new BillFlowPayments(usdt, admin, address(0), pauser);
        vm.expectRevert(BillFlowPayments.ZeroAddress.selector);
        new BillFlowPayments(usdt, admin, signer, address(0));
    }

    function test_getPayment_unknownId_reverts() public {
        vm.expectRevert(BillFlowPayments.InvalidInvoice.selector);
        pay.getPayment(1);
    }

    // ───────── hostile tokens ─────────
    function test_revert_feeOnTransferToken() public {
        FeeERC20 fee = new FeeERC20();
        BillFlowPayments p2 = new BillFlowPayments(fee, admin, signer, pauser);
        fee.mint(payer, TOTAL);
        vm.prank(payer);
        fee.approve(address(p2), type(uint256).max);

        BillFlowPayments.Quote memory q = _q(TOTAL, 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, p2.hashQuote(q));
        vm.prank(payer);
        vm.expectRevert(BillFlowPayments.UnexpectedTransferAmount.selector);
        p2.payInvoice(q, abi.encodePacked(r, s, v));
    }

    function test_reentrancy_isBlocked() public {
        ReentrantERC20 evil = new ReentrantERC20();
        BillFlowPayments p2 = new BillFlowPayments(evil, admin, signer, pauser);
        evil.mint(payer, TOTAL);
        vm.prank(payer);
        evil.approve(address(p2), type(uint256).max);

        BillFlowPayments.Quote memory q1 = _q(100e6, 1);
        BillFlowPayments.Quote memory q2 = _q(100e6, 2);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, p2.hashQuote(q1));
        bytes memory sig1 = abi.encodePacked(r, s, v);
        (v, r, s) = vm.sign(signerKey, p2.hashQuote(q2));
        bytes memory sig2 = abi.encodePacked(r, s, v);

        evil.arm(address(p2), abi.encodeCall(BillFlowPayments.payInvoice, (q2, sig2)));
        vm.prank(payer);
        p2.payInvoice(q1, sig1);

        assertFalse(evil.reentrySucceeded(), "re-entrant call must fail");
        assertEq(bytes4(evil.reentryRevertData()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(p2.paymentCount(), 1);
    }

    // ───────── fuzz ─────────
    function testFuzz_cumulativePaymentsNeverExceedTotal(uint256 a, uint256 b) public {
        a = bound(a, 1, TOTAL);
        b = bound(b, 1, TOTAL);
        _pay(a, 1);

        BillFlowPayments.Quote memory q = _q(b, 2);
        bytes memory sig = _sign(q, signerKey);
        vm.prank(payer);
        if (a == TOTAL) {
            vm.expectRevert(BillFlowPayments.AlreadyPaid.selector);
            pay.payInvoice(q, sig);
        } else if (a + b > TOTAL) {
            vm.expectRevert(abi.encodeWithSelector(BillFlowPayments.Overpayment.selector, TOTAL - a));
            pay.payInvoice(q, sig);
        } else {
            pay.payInvoice(q, sig);
        }
        assertLe(usdt.balanceOf(merchant), TOTAL);
        assertEq(usdt.balanceOf(merchant), TOTAL - pay.remainingAmount(INV));
        assertEq(usdt.balanceOf(address(pay)), 0);
    }
}
