// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BillFlowPayments} from "../src/BillFlowPayments.sol";
import {BillFlowRefunds, IBillFlowPaymentsView} from "../src/BillFlowRefunds.sol";
import {MockERC20, ReentrantERC20, FeeERC20} from "./mocks/Mocks.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract BillFlowRefundsTest is Test {
    BillFlowPayments pay;
    BillFlowRefunds ref;
    MockERC20 usdt;

    uint256 signerKey = 0xA11CE;
    address admin = makeAddr("admin");
    address pauser = makeAddr("pauser");
    address merchant = makeAddr("merchant");
    address payer = makeAddr("payer");
    address attacker = makeAddr("attacker");

    bytes32 constant INV = keccak256("inv");
    bytes32 constant INV_HASH = keccak256("inv-data");
    uint256 constant TOTAL = 1_000e6;
    uint256 nonce;

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

    function setUp() public {
        vm.warp(1_700_000_000);
        usdt = new MockERC20(6);
        _deploy(usdt);
    }

    function _deploy(MockERC20 t) internal {
        pay = new BillFlowPayments(t, admin, vm.addr(signerKey), pauser);
        ref = new BillFlowRefunds(IBillFlowPaymentsView(address(pay)), admin, pauser);
        t.mint(payer, 10_000e6);
        t.mint(merchant, 10_000e6);
        vm.prank(payer);
        t.approve(address(pay), type(uint256).max);
        vm.prank(merchant);
        t.approve(address(ref), type(uint256).max);
    }

    function _payment(bytes32 invoiceId, uint256 amount, uint256 total) internal returns (uint256) {
        BillFlowPayments.Quote memory q = BillFlowPayments.Quote({
            invoiceId: invoiceId,
            invoiceHash: INV_HASH,
            merchant: merchant,
            payer: payer,
            amount: amount,
            invoiceTotal: total,
            nonce: ++nonce,
            expiry: uint64(block.timestamp + 15 minutes)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, pay.hashQuote(q));
        vm.prank(payer);
        return pay.payInvoice(q, abi.encodePacked(r, s, v));
    }

    // ───────── happy paths ─────────
    function test_fullRefund_returnsFundsToOriginalPayer_andEmits() public {
        uint256 pid = _payment(INV, TOTAL, TOTAL);
        uint256 payerBefore = usdt.balanceOf(payer);
        uint256 merchBefore = usdt.balanceOf(merchant);

        vm.expectEmit(true, true, true, true, address(ref));
        emit PaymentRefunded(1, pid, payer, merchant, TOTAL, TOTAL, TOTAL, bytes32("r1"), bytes32("why"));
        vm.prank(merchant);
        uint256 rid = ref.refund(pid, TOTAL, bytes32("r1"), bytes32("why"));

        assertEq(rid, 1);
        assertEq(usdt.balanceOf(payer), payerBefore + TOTAL);
        assertEq(usdt.balanceOf(merchant), merchBefore - TOTAL);
        assertEq(usdt.balanceOf(address(ref)), 0, "refund contract never holds funds");
        assertEq(ref.totalRefunded(pid), TOTAL);
        assertEq(ref.refundable(pid), 0);
        BillFlowRefunds.RefundRecord memory r = ref.getRefund(rid);
        assertEq(r.payer, payer);
        assertEq(r.merchant, merchant);
        assertEq(r.amount, TOTAL);
        assertEq(r.refundRef, bytes32("r1"));
    }

    function test_partialRefunds_accumulate_untilFullyRefunded() public {
        uint256 pid = _payment(INV, TOTAL, TOTAL);
        vm.startPrank(merchant);
        ref.refund(pid, 300e6, bytes32("a"), 0);
        assertEq(ref.refundable(pid), 700e6);
        ref.refund(pid, 500e6, bytes32("b"), 0);
        assertEq(ref.refundable(pid), 200e6);
        vm.expectRevert(abi.encodeWithSelector(BillFlowRefunds.RefundExceedsPayment.selector, 200e6));
        ref.refund(pid, 200e6 + 1, bytes32("c"), 0);
        ref.refund(pid, 200e6, bytes32("d"), 0);
        vm.stopPrank();
        assertEq(ref.totalRefunded(pid), TOTAL);
        assertEq(ref.refundCount(), 3);
    }

    function test_refundOfPartialPayment_isBoundedByThatPaymentNotInvoice() public {
        uint256 p1 = _payment(INV, 400e6, TOTAL);
        uint256 p2 = _payment(INV, 600e6, TOTAL);
        vm.startPrank(merchant);
        vm.expectRevert(abi.encodeWithSelector(BillFlowRefunds.RefundExceedsPayment.selector, 400e6));
        ref.refund(p1, 401e6, bytes32("x"), 0);
        ref.refund(p2, 600e6, bytes32("y"), 0);
        vm.stopPrank();
        assertEq(ref.refundable(p1), 400e6);
    }

    // ───────── authorisation ─────────
    function test_onlyRecordedMerchantCanRefund() public {
        uint256 pid = _payment(INV, TOTAL, TOTAL);
        vm.prank(attacker);
        vm.expectRevert(BillFlowRefunds.NotMerchant.selector);
        ref.refund(pid, 1, bytes32("z"), 0);
        vm.prank(payer);
        vm.expectRevert(BillFlowRefunds.NotMerchant.selector);
        ref.refund(pid, 1, bytes32("z"), 0);
        vm.prank(admin);
        vm.expectRevert(BillFlowRefunds.NotMerchant.selector);
        ref.refund(pid, 1, bytes32("z"), 0);
    }

    function test_refundRefIsSingleUse_idempotency() public {
        uint256 pid = _payment(INV, TOTAL, TOTAL);
        vm.startPrank(merchant);
        ref.refund(pid, 100e6, bytes32("same"), 0);
        vm.expectRevert(BillFlowRefunds.RefundRefUsed.selector);
        ref.refund(pid, 100e6, bytes32("same"), 0);
        vm.stopPrank();
        assertEq(ref.totalRefunded(pid), 100e6);
    }

    function test_invalidInputs() public {
        uint256 pid = _payment(INV, TOTAL, TOTAL);
        vm.startPrank(merchant);
        vm.expectRevert(BillFlowRefunds.InvalidAmount.selector);
        ref.refund(pid, 0, bytes32("a"), 0);
        vm.expectRevert(BillFlowRefunds.InvalidRefundRef.selector);
        ref.refund(pid, 1, bytes32(0), 0);
        vm.expectRevert(BillFlowRefunds.InvalidPayment.selector);
        ref.refund(0, 1, bytes32("a"), 0);
        vm.expectRevert(BillFlowRefunds.InvalidPayment.selector);
        ref.refund(99, 1, bytes32("a"), 0);
        vm.stopPrank();
    }

    function test_merchantWithoutAllowanceOrBalance_reverts_andStateRollsBack() public {
        uint256 pid = _payment(INV, TOTAL, TOTAL);
        vm.prank(merchant);
        usdt.approve(address(ref), 0);
        vm.prank(merchant);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(ref), 0, 10e6)
        );
        ref.refund(pid, 10e6, bytes32("a"), 0);
        assertEq(ref.totalRefunded(pid), 0);
        assertEq(ref.refundCount(), 0);
        assertEq(ref.refundIdByRef(bytes32("a")), 0, "ref not burnt by failed refund");
    }

    function test_refundDoesNotTouchPaymentsContractState() public {
        uint256 pid = _payment(INV, TOTAL, TOTAL);
        BillFlowPayments.InvoicePayment memory before_ = pay.getInvoicePaymentStatus(INV);
        vm.prank(merchant);
        ref.refund(pid, TOTAL, bytes32("a"), 0);
        BillFlowPayments.InvoicePayment memory after_ = pay.getInvoicePaymentStatus(INV);
        assertEq(abi.encode(before_), abi.encode(after_));
        assertTrue(pay.isInvoicePaid(INV));
    }

    // ───────── pause / roles ─────────
    function test_pause_blocksRefunds_onlyPauser() public {
        uint256 pid = _payment(INV, TOTAL, TOTAL);
        bytes32 role = ref.PAUSER_ROLE();
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, role));
        ref.pause();
        vm.prank(pauser);
        ref.pause();
        vm.prank(merchant);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        ref.refund(pid, 1, bytes32("a"), 0);
        vm.prank(pauser);
        ref.unpause();
        vm.prank(merchant);
        ref.refund(pid, 1, bytes32("a"), 0);
    }

    function test_constructorRejectsZero() public {
        vm.expectRevert(BillFlowRefunds.ZeroAddress.selector);
        new BillFlowRefunds(IBillFlowPaymentsView(address(pay)), address(0), pauser);
        vm.expectRevert(BillFlowRefunds.ZeroAddress.selector);
        new BillFlowRefunds(IBillFlowPaymentsView(address(pay)), admin, address(0));
    }

    function test_viewsForUnknownPayment() public view {
        assertEq(ref.refundable(0), 0);
        assertEq(ref.refundable(5), 0);
    }

    // ───────── hostile tokens ─────────
    function test_feeTokenDeployment_hasNoRefundablePayments() public {
        FeeERC20 fee = new FeeERC20();
        // BillFlowPayments itself rejects fee-on-transfer tokens, so no payment can exist on such a
        // deployment and therefore nothing is refundable (the refund delta check is defence in depth).
        pay = new BillFlowPayments(fee, admin, vm.addr(signerKey), pauser);
        ref = new BillFlowRefunds(IBillFlowPaymentsView(address(pay)), admin, pauser);
        vm.prank(merchant);
        vm.expectRevert(BillFlowRefunds.InvalidPayment.selector);
        ref.refund(1, 1, bytes32("a"), 0);
    }

    function test_reentrancyViaToken_blocked() public {
        ReentrantERC20 evil = new ReentrantERC20();
        pay = new BillFlowPayments(evil, admin, vm.addr(signerKey), pauser);
        ref = new BillFlowRefunds(IBillFlowPaymentsView(address(pay)), admin, pauser);
        evil.mint(payer, 10_000e6);
        evil.mint(merchant, 10_000e6);
        vm.prank(payer);
        evil.approve(address(pay), type(uint256).max);
        vm.prank(merchant);
        evil.approve(address(ref), type(uint256).max);
        uint256 pid = _payment(INV, TOTAL, TOTAL);

        evil.arm(address(ref), abi.encodeCall(ref.refund, (pid, 1e6, bytes32("re"), bytes32(0))));
        vm.prank(merchant);
        ref.refund(pid, 100e6, bytes32("a"), 0);
        assertFalse(evil.reentrySucceeded());
        assertEq(bytes4(evil.reentryRevertData()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(ref.totalRefunded(pid), 100e6);
    }

    // ───────── fuzz ─────────
    function testFuzz_refundsNeverExceedPayment(uint256 paid, uint256 a, uint256 b, uint256 c) public {
        paid = bound(paid, 1, 5_000e6);
        uint256 pid = _payment(keccak256(abi.encode(paid)), paid, paid);
        uint256[3] memory amts = [a, b, c];
        uint256 sum;
        for (uint256 i; i < 3; i++) {
            uint256 amt = bound(amts[i], 1, paid + 10);
            vm.prank(merchant);
            try ref.refund(pid, amt, bytes32(i + 1), 0) {
                sum += amt;
            } catch {}
            assertLe(ref.totalRefunded(pid), paid);
            assertEq(ref.totalRefunded(pid), sum);
        }
        assertEq(usdt.balanceOf(address(ref)), 0);
    }
}
