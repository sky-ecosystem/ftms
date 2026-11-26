// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { StdCheats } from "../../../lib/forge-std/src/StdCheats.sol";
import { Vm }        from "../../../lib/forge-std/src/Vm.sol";

import { IAssetHarness } from "../handlers/HandlerBase.sol";

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IUSDCLike {
    function blacklist(address account) external;
    function blacklister() external view returns (address);
    function isBlacklisted(address account) external view returns (bool);
    function unBlacklist(address account) external;
}

interface IUSDTLike {
    function addBlackList(address account) external;
    function isBlackListed(address account) external view returns (bool);
    function owner() external view returns (address);
    function removeBlackList(address account) external;
}

// Drives a real mainnet token on a fork: balances are set with `deal`, and blocking uses the
// token's own blocklist. USDC blocks both sides of a transfer, USDT only the sender. Other tokens
// have no blocklist, so `setBlocked` does nothing for them.
contract ForkAsset is IAssetHarness, StdCheats {

    enum Blocklist { NONE, USDC, USDT }

    Vm internal constant hevm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address   public immutable override token;
    Blocklist public immutable blocklist;

    constructor(address token_, Blocklist blocklist_) {
        token     = token_;
        blocklist = blocklist_;
    }

    function balanceOf(address account_) public view override returns (uint256) {
        return IERC20Like(token).balanceOf(account_);
    }

    function decimals() external view override returns (uint8) {
        return IERC20Like(token).decimals();
    }

    function blocked(address account_) external view override returns (bool) {
        if (blocklist == Blocklist.USDC) return IUSDCLike(token).isBlacklisted(account_);
        if (blocklist == Blocklist.USDT) return IUSDTLike(token).isBlackListed(account_);
        return false;
    }

    // `deal` leaves the token's total supply alone, which no conversion of these tokens reads.
    // Never called for a blocked USDC account: USDC keeps its blacklist flag in the balance slot.
    function mint(address account_, uint256 amount_) external override {
        deal(token, account_, balanceOf(account_) + amount_);
    }

    function burn(address account_, uint256 amount_) external override {
        deal(token, account_, balanceOf(account_) - amount_);
    }

    function setBlocked(address account_, bool blocked_) external override {
        if (blocklist == Blocklist.USDC) {
            hevm.prank(IUSDCLike(token).blacklister());
            if (blocked_) IUSDCLike(token).blacklist(account_);
            else          IUSDCLike(token).unBlacklist(account_);
        } else if (blocklist == Blocklist.USDT) {
            hevm.prank(IUSDTLike(token).owner());
            if (blocked_) IUSDTLike(token).addBlackList(account_);
            else          IUSDTLike(token).removeBlackList(account_);
        }
    }

}
