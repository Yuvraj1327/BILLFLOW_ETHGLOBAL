// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";

/// @notice READ-ONLY probe (Priority 7, Whitechain Scale). Reports which signature-based approval/transfer mechanisms the
///         official USDT contract exposes: EIP-2612 `permit`, EIP-3009 `transferWithAuthorization`, EIP-5267 `eip712Domain`.
///         It sends no transaction. Run it yourself against Whitechain Sepolia (this sandbox cannot reach the RPC):
///   forge script script/ProbeUsdtSignatures.s.sol --rpc-url $WHITECHAIN_SEPOLIA_RPC_URL
/// A gasless merchant-sponsored checkout is implemented ONLY if this prints `permit` and/or `transferWithAuthorization` as present.
contract ProbeUsdtSignatures is Script {
    function _has(address t, bytes memory callData) internal view returns (bool ok) {
        (ok,) = t.staticcall(callData);
    }

    function run() external view {
        address usdt = vm.envAddress("USDT_ADDRESS");
        require(block.chainid == 1874, "not Whitechain Sepolia (1874)");
        require(usdt.code.length > 0, "no contract at USDT_ADDRESS");
        address probe = address(0xdead);
        console2.log("USDT                     :", usdt);
        console2.log("DOMAIN_SEPARATOR()       :", _has(usdt, abi.encodeWithSignature("DOMAIN_SEPARATOR()")));
        console2.log("nonces(address) [2612]   :", _has(usdt, abi.encodeWithSignature("nonces(address)", probe)));
        console2.log("PERMIT_TYPEHASH()        :", _has(usdt, abi.encodeWithSignature("PERMIT_TYPEHASH()")));
        console2.log("authorizationState [3009]:", _has(usdt, abi.encodeWithSignature("authorizationState(address,bytes32)", probe, bytes32(0))));
        console2.log("TRANSFER_WITH_AUTH_TYPEHASH:", _has(usdt, abi.encodeWithSignature("TRANSFER_WITH_AUTHORIZATION_TYPEHASH()")));
        console2.log("eip712Domain() [5267]    :", _has(usdt, abi.encodeWithSignature("eip712Domain()")));
        console2.log("Presence of a getter is a HINT, not proof: confirm with the token's verified source / a test permit signature.");
    }
}
