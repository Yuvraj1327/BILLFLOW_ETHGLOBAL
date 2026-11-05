// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev TEST-ONLY token. Never deployed; all demo and deployment flows use the official Whitechain
///      testnet USDT. 6 decimals is only the common USDT convention used by the unit tests.
contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(uint8 dec) ERC20("Mock Test Token", "MTT") {
        _dec = dec;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Re-enters a target contract from inside transferFrom to prove the reentrancy guards hold.
contract ReentrantERC20 is MockERC20 {
    address public target;
    bytes public data;
    bool public armed;
    bool public reentrySucceeded;
    bytes public reentryRevertData;

    constructor() MockERC20(6) {}

    function arm(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (armed) {
            armed = false;
            (bool ok, bytes memory ret) = target.call(data);
            reentrySucceeded = ok;
            reentryRevertData = ret;
        }
        return super.transferFrom(from, to, value);
    }
}

/// @dev Takes a 1% fee on transfers — the contracts must refuse such tokens.
contract FeeERC20 is MockERC20 {
    constructor() MockERC20(6) {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}
