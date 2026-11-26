// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IAssetHarness } from "../handlers/HandlerBase.sol";

// An ERC-20 with an issuer blocklist (like USDC) whose `transfer` and `transferFrom` can
// return no value (like USDT). Transfers from or to a blocked account revert.
contract MockAsset is IAssetHarness {

    uint8 public immutable override decimals;

    bool public immutable noReturn;

    uint256 public totalSupply;

    mapping (address => uint256)                      public override balanceOf;
    mapping (address => mapping (address => uint256)) public allowance;
    mapping (address => bool)                         public override blocked;

    constructor(bool noReturn_, uint8 decimals_) {
        noReturn = noReturn_;
        decimals = decimals_;
    }

    /**********************************************************************************************/
    /*** Test helpers                                                                           ***/
    /**********************************************************************************************/

    function token() external view override returns (address) {
        return address(this);
    }

    function mint(address account_, uint256 amount_) external override {
        totalSupply         += amount_;
        balanceOf[account_] += amount_;
    }

    function burn(address account_, uint256 amount_) external override {
        totalSupply         -= amount_;
        balanceOf[account_] -= amount_;
    }

    function setBlocked(address account_, bool blocked_) external override {
        blocked[account_] = blocked_;
    }

    /**********************************************************************************************/
    /*** ERC-20                                                                                 ***/
    /**********************************************************************************************/

    function approve(address spender_, uint256 amount_) external returns (bool) {
        allowance[msg.sender][spender_] = amount_;
        return true;
    }

    function transfer(address to_, uint256 amount_) external returns (bool) {
        _transfer(msg.sender, to_, amount_);
        return _return();
    }

    function transferFrom(address from_, address to_, uint256 amount_) external returns (bool) {
        uint256 allowance_ = allowance[from_][msg.sender];

        if (allowance_ != type(uint256).max) {
            require(allowance_ >= amount_, "MockAsset/insufficient-allowance");
            allowance[from_][msg.sender] = allowance_ - amount_;
        }

        _transfer(from_, to_, amount_);
        return _return();
    }

    function _transfer(address from_, address to_, uint256 amount_) internal {
        require(!blocked[from_] && !blocked[to_], "MockAsset/blocked");
        require(balanceOf[from_] >= amount_,      "MockAsset/insufficient-balance");

        balanceOf[from_] -= amount_;
        balanceOf[to_]   += amount_;
    }

    function _return() internal view returns (bool) {
        if (noReturn) {
            assembly { return(0, 0) }
        }

        return true;
    }

}
