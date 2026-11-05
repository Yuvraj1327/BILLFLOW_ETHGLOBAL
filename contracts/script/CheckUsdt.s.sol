// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";

interface IERC20Meta {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

/// @notice READ-ONLY. Run this against Whitechain Sepolia BEFORE deploying to confirm that
///         USDT_ADDRESS is a live ERC-20 with the expected chain, name, symbol and decimals.
///         forge script script/CheckUsdt.s.sol --rpc-url $WHITECHAIN_SEPOLIA_RPC_URL
contract CheckUsdt is Script {
    function run() external view {
        address usdt = vm.envAddress("USDT_ADDRESS");
        console2.log("chainid       :", block.chainid);
        console2.log("USDT_ADDRESS  :", usdt);
        console2.log("has code      :", usdt.code.length > 0);
        require(block.chainid == 1874, "not Whitechain Sepolia (1874)");
        require(usdt.code.length > 0, "no contract at USDT_ADDRESS");

        IERC20Meta t = IERC20Meta(usdt);
        console2.log("name          :", t.name());
        console2.log("symbol        :", t.symbol());
        console2.log("decimals      :", t.decimals());
        console2.log("totalSupply   :", t.totalSupply());

        address who = vm.envOr("CHECK_BALANCE_OF", address(0));
        if (who != address(0)) console2.log("balanceOf     :", t.balanceOf(who));
        console2.log("Compare name/symbol/decimals with the official Whitechain / sponsor documentation.");
    }
}
