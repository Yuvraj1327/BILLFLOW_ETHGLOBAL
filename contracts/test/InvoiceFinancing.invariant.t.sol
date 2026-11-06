// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {InvoiceFinancing} from "../src/InvoiceFinancing.sol";
import {MockERC20} from "./mocks/Mocks.sol";

/// Random sequences of lifecycle calls. Reverting calls are expected and ignored (try/catch); what must hold is accounting.
contract FinancingHandler is Test {
    InvoiceFinancing public fin;
    MockERC20 public usdt;
    address public admin; address public verifier; address public business; address public investor; address public debtor;
    uint256 public salt;
    uint256[] public ids;
    uint256 public ghostAdvancePaid;   // sum of advances moved to the business by successful fund()
    uint256 public ghostRepaid;        // sum of face values moved to investors by successful repay()

    constructor(InvoiceFinancing f, MockERC20 t, address a, address v, address b, address i, address d) {
        fin = f; usdt = t; admin = a; verifier = v; business = b; investor = i; debtor = d;
    }

    function register(uint256 face) external {
        face = bound(face, 1_000, 1_000_000e6);
        InvoiceFinancing.RegisterParams memory p = InvoiceFinancing.RegisterParams({
            invoiceHash: keccak256(abi.encode("h", ++salt)), documentHash: keccak256("d"), debtorRef: keccak256("r"),
            business: business, debtor: debtor, faceValue: face,
            issueDate: uint64(block.timestamp), dueDate: uint64(block.timestamp + 30 days)
        });
        vm.prank(business);
        try fin.registerInvoice(p) returns (uint256 id) { ids.push(id); } catch {}
    }

    function verify(uint256 k) external {
        if (ids.length == 0) return;
        vm.prank(verifier);
        try fin.verifyInvoice(ids[k % ids.length], keccak256("ack")) {} catch {}
    }

    function list(uint256 k, uint256 pct) external {
        if (ids.length == 0) return;
        uint256 id = ids[k % ids.length];
        uint256 face = fin.getInvoice(id).faceValue;
        uint256 adv = face * bound(pct, 50, 99) / 100;
        vm.prank(business);
        try fin.createOffer(id, adv, uint64(block.timestamp + 7 days)) {} catch {}
    }

    function fund(uint256 k) external {
        if (ids.length == 0) return;
        uint256 id = ids[k % ids.length];
        uint256 adv = fin.getInvoice(id).advance;
        vm.prank(investor);
        try fin.fund(id) { ghostAdvancePaid += adv; } catch {}
    }

    function repay(uint256 k) external {
        if (ids.length == 0) return;
        uint256 id = ids[k % ids.length];
        uint256 face = fin.getInvoice(id).faceValue;
        vm.prank(debtor);
        try fin.repay(id) { ghostRepaid += face; } catch {}
    }

    function cancelOffer(uint256 k) external {
        if (ids.length == 0) return;
        vm.prank(business);
        try fin.cancelOffer(ids[k % ids.length]) {} catch {}
    }

    function expire(uint256 k) external {
        if (ids.length == 0) return;
        try fin.expireOffer(ids[k % ids.length]) {} catch {}
    }

    function warp(uint256 s) external { vm.warp(block.timestamp + bound(s, 1, 10 days)); }
    function count() external view returns (uint256) { return ids.length; }
}

contract InvoiceFinancingInvariantTest is Test {
    InvoiceFinancing fin;
    MockERC20 usdt;
    FinancingHandler h;
    address admin = makeAddr("admin");
    address verifier = makeAddr("verifier");
    address business = makeAddr("business");
    address investor = makeAddr("investor");
    address debtor = makeAddr("debtor");
    uint256 constant START_BIZ = 7;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdt = new MockERC20(6);
        fin = new InvoiceFinancing(usdt, admin);
        vm.startPrank(admin);
        fin.grantRole(fin.VERIFIER_ROLE(), verifier);
        vm.stopPrank();
        vm.startPrank(verifier);
        fin.setBusinessApproved(business, true);
        fin.setInvestorApproved(investor, true);
        vm.stopPrank();
        usdt.mint(business, START_BIZ);
        usdt.mint(investor, type(uint128).max);
        usdt.mint(debtor, type(uint128).max);
        vm.prank(investor); usdt.approve(address(fin), type(uint256).max);
        vm.prank(debtor); usdt.approve(address(fin), type(uint256).max);
        h = new FinancingHandler(fin, usdt, admin, verifier, business, investor, debtor);
        targetContract(address(h));
    }

    /// The contract is a pure router: it must never custody the payment token.
    function invariant_contractNeverHoldsPaymentToken() public view {
        assertEq(usdt.balanceOf(address(fin)), 0);
    }

    /// Business only ever receives exactly the advances of successfully funded offers.
    function invariant_businessReceivedEqualsFundedAdvances() public view {
        assertEq(usdt.balanceOf(business), START_BIZ + h.ghostAdvancePaid());
    }

    /// Every settled invoice paid its face value exactly once to the investor (no duplicate settlement).
    function invariant_settlementsPaidExactlyOnce() public view {
        uint256 settledFace;
        for (uint256 i = 0; i < h.count(); i++) {
            uint256 id = h.ids(i);
            InvoiceFinancing.Invoice memory inv = fin.getInvoice(id);
            if (inv.status == InvoiceFinancing.Status.Settled) settledFace += inv.faceValue;
        }
        assertEq(settledFace, h.ghostRepaid());
    }

    /// businessExposure always equals the sum of advances of Listed/Funded/Defaulted offers (no leak, no double release).
    function invariant_exposureMatchesOpenOffers() public view {
        uint256 open;
        for (uint256 i = 0; i < h.count(); i++) {
            InvoiceFinancing.Invoice memory inv = fin.getInvoice(h.ids(i));
            if (
                inv.status == InvoiceFinancing.Status.Listed || inv.status == InvoiceFinancing.Status.Funded
                    || inv.status == InvoiceFinancing.Status.Defaulted
            ) open += inv.advance;
        }
        assertEq(fin.businessExposure(business), open);
    }

    /// Sanity: the handler's call sequence can actually reach Funded and Settled (so the invariants are not vacuous).
    function test_handlerCanReachSettlement() public {
        h.register(10_000e6);
        h.verify(0);
        h.list(0, 95);
        h.fund(0);
        assertGt(h.ghostAdvancePaid(), 0);
        h.repay(0);
        assertEq(h.ghostRepaid(), 10_000e6);
        assertEq(uint8(fin.getInvoice(1).status), uint8(InvoiceFinancing.Status.Settled));
    }
}
