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

import "forge-std/Test.sol";

import { PassthroughVault } from "src/PassthroughVault.sol";

import { GemMock } from "test/mocks/GemMock.sol";

contract PassthroughVaultTest is Test {
    GemMock          gem;
    PassthroughVault vault;

    address user     = address(0x123);
    address receiver = address(0x456);
    address spender  = address(0x789);

    function setUp() public {
        gem   = new GemMock();
        vault = new PassthroughVault(address(gem), "Passthrough mUSD", "ptmUSD");
    }

    function _deposit(address owner, uint256 assets) internal {
        gem.mint(owner, assets);
        vm.startPrank(owner);
        gem.approve(address(vault), assets);
        vault.deposit(assets, owner);
        vm.stopPrank();
    }

    function testMetadata() public view {
        assertEq(vault.asset(),    address(gem));
        assertEq(vault.decimals(), gem.decimals());
    }

    // Sleeve requirement 3: no fees
    function testFuzzRoundTripIsOneToOne(uint256 assets) public {
        assets = bound(assets, 0, 1e30);
        gem.mint(user, assets);

        vm.startPrank(user);
        gem.approve(address(vault), assets);
        uint256 shares = vault.deposit(assets, user);

        assertEq(shares,                        assets);
        assertEq(vault.convertToShares(assets), assets);
        assertEq(vault.convertToAssets(shares), assets);
        assertEq(vault.previewRedeem(shares),   assets);

        uint256 out = vault.redeem(shares, user, user);
        vm.stopPrank();

        assertEq(out,                 assets);
        assertEq(gem.balanceOf(user), assets);
        assertEq(vault.totalSupply(), 0);
    }

    function testDonationDoesNotMovePrice() public {
        _deposit(user, 1_000e6);
        gem.mint(address(vault), 500e6);

        assertEq(vault.totalAssets(),        1_000e6);
        assertEq(vault.convertToAssets(1e6), 1e6);
        assertEq(vault.maxWithdraw(user),    1_000e6);
    }

    // Sleeve requirement 2, plus depositing for another receiver (how capital is returned)
    function testDepositToOtherReceiver() public {
        gem.mint(user, 100e6);
        vm.startPrank(user);
        gem.approve(address(vault), 100e6);
        vault.deposit(100e6, receiver);
        vm.stopPrank();

        assertEq(vault.balanceOf(receiver), 100e6);
        assertEq(vault.balanceOf(user),     0);
    }

    // Sleeve requirement 4: zero amounts succeed
    function testZeroAmounts() public {
        vm.startPrank(user);
        assertEq(vault.deposit(0, user),        0);
        assertEq(vault.mint(0, user),           0);
        assertEq(vault.redeem(0, user, user),   0);
        assertEq(vault.withdraw(0, user, user), 0);
        vm.stopPrank();
    }

    // Sleeve requirement 1: `maxRedeem` is redeemable in full, in the same call
    function testMaxRedeem() public {
        _deposit(user, 1_000e6);

        assertEq(vault.maxRedeem(user),   1_000e6);
        assertEq(vault.maxWithdraw(user), 1_000e6);

        uint256 maxShares = vault.maxRedeem(user);
        vm.prank(user);
        vault.redeem(maxShares, receiver, user);

        assertEq(gem.balanceOf(receiver), 1_000e6);
        assertEq(vault.maxRedeem(user),   0);
    }

    function testRedeemAboveBalanceReverts() public {
        _deposit(user, 100e6);

        vm.prank(user);
        vm.expectRevert();
        vault.redeem(100e6 + 1, user, user);
    }

    function testRedeemByApprovedSpender() public {
        _deposit(user, 100e6);

        vm.prank(user);
        vault.approve(spender, 60e6);

        vm.prank(spender);
        vault.redeem(60e6, receiver, user);

        assertEq(gem.balanceOf(receiver),        60e6);
        assertEq(vault.allowance(user, spender), 0);

        vm.prank(spender);
        vm.expectRevert();
        vault.redeem(1, receiver, user);
    }

    // `take` transfers sleeve shares
    function testSharesTransferable() public {
        _deposit(user, 100e6);

        vm.prank(user);
        vault.transfer(receiver, 40e6);

        assertEq(vault.balanceOf(receiver), 40e6);
    }
}
