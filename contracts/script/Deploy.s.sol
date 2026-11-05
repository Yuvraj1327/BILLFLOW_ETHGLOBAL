// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BillFlowPayments} from "../src/BillFlowPayments.sol";
import {InvoiceFinancing} from "../src/InvoiceFinancing.sol";

interface IDecimals {
    function decimals() external view returns (uint8);
}

/// @notice Deploys both BillFlow contracts to Whitechain Sepolia and wires roles.
///         NOTHING is deployed until YOU run this with a funded deployer, e.g.:
///
///   forge script script/Deploy.s.sol --rpc-url $WHITECHAIN_SEPOLIA_RPC_URL \
///        --account <foundry-keystore-name> --broadcast
///
/// Prefer a Foundry keystore (`cast wallet import`) over `--private-key` so keys never sit in shell history.
/// Required env: USDT_ADDRESS, ADMIN_ADDRESS, QUOTE_SIGNER_ADDRESS, PAUSER_ADDRESS,
///               ISSUER_ADDRESS, VERIFIER_ADDRESS, OPERATOR_ADDRESS
contract Deploy is Script {
    function run() external {
        require(block.chainid == 1874, "refusing to deploy: not Whitechain Sepolia (1874)");

        address usdt = vm.envAddress("USDT_ADDRESS");
        address admin = vm.envAddress("ADMIN_ADDRESS");
        address quoteSigner = vm.envAddress("QUOTE_SIGNER_ADDRESS");
        address pauser = vm.envAddress("PAUSER_ADDRESS");
        address issuer = vm.envAddress("ISSUER_ADDRESS");
        address verifier = vm.envAddress("VERIFIER_ADDRESS");
        address operator = vm.envAddress("OPERATOR_ADDRESS");

        require(usdt.code.length > 0, "USDT_ADDRESS has no code on this chain");
        uint8 dec = IDecimals(usdt).decimals(); // reverts if not an ERC-20 with decimals()
        console2.log("USDT decimals (read from chain):", dec);

        // The deployer must be the admin so it can grant roles in this same script;
        // hand over / renounce afterwards if ADMIN_ADDRESS should be a different wallet.
        vm.startBroadcast();
        BillFlowPayments payments = new BillFlowPayments(IERC20(usdt), msg.sender, quoteSigner, pauser);
        InvoiceFinancing financing = new InvoiceFinancing(IERC20(usdt), msg.sender);

        financing.grantRole(financing.ISSUER_ROLE(), issuer);
        financing.grantRole(financing.VERIFIER_ROLE(), verifier);
        financing.grantRole(financing.OPERATOR_ROLE(), operator);
        financing.grantRole(financing.PAUSER_ROLE(), pauser);

        if (admin != msg.sender) {
            payments.grantRole(payments.DEFAULT_ADMIN_ROLE(), admin);
            financing.grantRole(financing.DEFAULT_ADMIN_ROLE(), admin);
            payments.renounceRole(payments.DEFAULT_ADMIN_ROLE(), msg.sender);
            financing.renounceRole(financing.DEFAULT_ADMIN_ROLE(), msg.sender);
        }
        vm.stopBroadcast();

        console2.log("BillFlowPayments :", address(payments));
        console2.log("InvoiceFinancing :", address(financing));
        console2.log("Record these in docs/deployments.md and backend/.env, then verify on the explorer.");
    }
}
