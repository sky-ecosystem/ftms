// SPDX-FileCopyrightText: © 2026 Dai Foundation <www.daifoundation.org>
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.8.34;

import { ERC20 }                  from "oz/token/ERC20/ERC20.sol";
import { IERC20, IERC20Metadata } from "oz/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 }              from "oz/token/ERC20/utils/SafeERC20.sol";

// ERC-4626 vault whose shares are always worth one unit of `asset`.
// `totalAssets` is `totalSupply`, so donations don't move the price (they are stranded).
// No fees, caps, admin, pause or upgradeability. Zero amounts succeed.
contract PassthroughVault is ERC20 {

    using SafeERC20 for IERC20;

    // --- Immutables ---

    address public immutable asset;
    uint8   private immutable _decimals;

    // --- Events ---

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);

    constructor(address asset_, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        asset     = asset_;
        _decimals = IERC20Metadata(asset_).decimals();
    }

    // --- Internals ---

    function _enter(uint256 assets, uint256 shares, address receiver) internal {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function _exit(uint256 assets, uint256 shares, address receiver, address owner) internal {
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);
        IERC20(asset).safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    // --- ERC4626 ---

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function totalAssets() external view returns (uint256) {
        return totalSupply();
    }

    function convertToShares(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        return balanceOf(owner);
    }

    function maxRedeem(address owner) external view returns (uint256) {
        return balanceOf(owner);
    }

    function previewDeposit(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function previewMint(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function previewWithdraw(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function previewRedeem(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = assets;
        _enter(assets, shares, receiver);
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        assets = shares;
        _enter(assets, shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = assets;
        _exit(assets, shares, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        assets = shares;
        _exit(assets, shares, receiver, owner);
    }
}
