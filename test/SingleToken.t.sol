// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IERC20 } from "../lib/oz/contracts/token/ERC20/IERC20.sol";

import { ERC1967Proxy, TestBase, SparkPrimeVault } from "./TestBase.t.sol";

import { ISparkPrimeVault } from "../src/ISparkPrimeVault.sol";

contract SingleTokenTests is TestBase {

    address internal ali = makeAddr("ali");
    address internal bob = makeAddr("bob");

    function test_claimableAssetsAreReserved() external {
        _setCapacity(0);

        uint256 assets = spUSDC.convertToShares(1_000_000e6);

        _requestDeposit(ali, 1_000_000e6);
        _requestDepositCancellation(ali, 0, assets);

        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(IERC20.transfer.selector, ali, assets),
            ""
        );

        _processPendingDepositCancellations(1);

        vm.clearMockedCalls();

        assertEq(spPrime.totalClaimable(),           assets);
        assertEq(spUSDC.balanceOf(address(spPrime)), assets);

        // Claimable assets are neither liquidity nor takeable.
        assertEq(spPrime.availableLiquidAssets(), 0);

        vm.expectRevert(ISparkPrimeVault.InsufficientAssets.selector);
        _take(1);

        // Only the new deposit can be taken or used for cancellations.
        uint256 bobAssets = spUSDC.convertToShares(500_000e6);

        _requestDeposit(bob, 500_000e6);
        _requestDepositCancellation(bob, 1, bobAssets);

        assertEq(spPrime.availableLiquidAssets(), bobAssets);

        vm.expectRevert(ISparkPrimeVault.InsufficientAssets.selector);
        _take(bobAssets + 1);

        _take(bobAssets);

        _processPendingDepositCancellations(1);

        assertEq(spPrime.pendingCancelledDepositAssets(), bobAssets);
        assertEq(spUSDC.balanceOf(bob),                    0);

        // The claim is still fully backed.
        spPrime.claim(ali);

        assertEq(spUSDC.balanceOf(ali),              assets);
        assertEq(spUSDC.balanceOf(address(spPrime)), 0);
    }

    function test_returnCapitalByTransfer() external {
        uint256 assets = spUSDC.convertToShares(1_000_000e6);

        _requestDeposit(ali, 1_000_000e6);  // Filled instantly

        _take(assets);

        assertEq(spPrime.availableLiquidAssets(), 0);

        // The taker returns capital by sending assets straight to the vault.
        vm.prank(taker);
        assertTrue(spUSDC.transfer(address(spPrime), assets));

        assertEq(spPrime.availableLiquidAssets(), assets);

        _requestRedeem(ali, spPrime.balanceOf(ali));
        _processPendingRedeems();

        assertEq(spPrime.totalSupply(), 0);
        assertEq(spUSDC.assetsOf(ali),  1_000_000e6 - 2);
    }

    function test_zeroPayoutTransferRevertDoesNotBlockQueue() external {
        _requestDeposit(ali, 1_000_000e6);  // Filled instantly
        _requestRedeem(ali, spPrime.balanceOf(ali));

        // One vault share is worth less than one asset unit, so it pays out zero.
        assertEq(spPrime.convertToAssets(1), 0);

        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(IERC20.transfer.selector, ali, 0),
            ""
        );

        uint256 pendingRedeemShares = spPrime.pendingRedeemShares();

        _processPendingRedeems(1, 1);

        assertEq(spPrime.pendingRedeemShares(),  pendingRedeemShares - 1);
        assertEq(spPrime.claimableAssetsOf(ali), 0);
    }

    function test_assetViewsMatchPayout() external {
        _requestDeposit(ali, 1_000_000e6);  // Filled instantly

        skip(365 days);

        // Cover the VSR with extra liquidity.
        deal(address(spUSDC), address(spPrime), spUSDC.convertToShares(2_000_000e6));

        uint256 shares = spPrime.balanceOf(ali);
        uint256 assets = spPrime.convertToAssets(shares);

        // Views are in spUSDC, worth the USDC value of the shares.
        assertEq(spPrime.assetsOf(ali),         assets);
        assertEq(spPrime.totalAssets(),         assets);
        assertEq(spPrime.referenceValueOf(ali), 1_050_000e6 - 2);
        assertEq(assets,                        spUSDC.convertToShares(1_050_000e6 - 2));
        assertLt(assets,                        1_050_000e6 - 2);

        _requestRedeem(ali, shares);
        _processPendingRedeems();

        assertEq(spUSDC.balanceOf(ali), assets);
    }

    function test_impairTakesReferenceAmount() external {
        _requestDeposit(ali, 1_000_000e6);  // Filled instantly
        _pause();

        skip(365 days);

        uint256 referenceBefore = spPrime.totalReferenceValue();
        uint256 assetsBefore    = spPrime.totalAssets();

        vm.prank(lossManager);
        spPrime.impair(100_000e6);

        // The loss is 100k USDC, whatever spUSDC is worth.
        assertEq(spPrime.totalReferenceValue(), referenceBefore - 100_000e6 - 1);

        assertApproxEqAbs(
            assetsBefore - spPrime.totalAssets(),
            spUSDC.convertToShares(100_000e6),
            2
        );
    }

    function test_unsetReferenceOracle() external {
        SparkPrimeVault vault = SparkPrimeVault(
            address(new ERC1967Proxy(
                address(new SparkPrimeVault()),
                abi.encodeCall(
                    ISparkPrimeVault.initialize,
                    (
                        address(spUSDC),
                        address(0),
                        "Spark Prime spUSDC",
                        "spPrime",
                        admin,
                        MINIMUM_DEPOSIT,
                        MINIMUM_DEPOSIT_CANCELLATION,
                        MINIMUM_REDEEM
                    )
                )
            ))
        );

        assertEq(vault.referenceOracle(), address(0));

        vm.startPrank(admin);
        vault.grantRole(OPERATOR_ROLE, operator);
        vault.setVSRBounds(RAY, vault.MAX_VSR());
        vm.stopPrank();

        vm.startPrank(operator);
        vault.setCapacity(VAULT_CAPACITY);
        vault.setVSR(FIVE_PCT_VSR);
        vm.stopPrank();

        deal(address(spUSDC), ali, 1_000_000e6);

        vm.startPrank(ali);
        spUSDC.approve(address(vault), 1_000_000e6);
        vault.requestDeposit(1_000_000e6, ali, 0);
        vm.stopPrank();

        // The reference is the asset itself: one vault share per asset unit at `chi == RAY`.
        assertEq(vault.balanceOf(ali),          1_000_000e6);
        assertEq(vault.totalAssets(),           1_000_000e6);
        assertEq(vault.availableLiquidAssets(), 1_000_000e6);

        skip(365 days);

        // The VSR is a premium on top of the asset's own yield, paid in the asset.
        assertEq(vault.totalAssets(), 1_050_000e6 - 1);

        deal(address(spUSDC), address(vault), 1_050_000e6);

        vm.prank(ali);
        vault.requestRedeem(1_000_000e6, ali);

        vm.prank(operator);
        vault.processPendingRedeems(type(uint256).max, type(uint256).max);

        assertEq(spUSDC.balanceOf(ali),            1_050_000e6 - 1);
        assertEq(spUSDC.balanceOf(address(vault)), 1);
    }

}
