// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ERC1967Proxy, TestBase, SparkPrimeVault } from "./TestBase.t.sol";

import { ISparkPrimeVault } from "../src/ISparkPrimeVault.sol";

contract ReferenceOracleTests is TestBase {

    address internal ali = makeAddr("ali");

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

        // Converting back rounds down twice, through the reference value and the oracle.
        assertEq(spPrime.convertToShares(assets), shares - 2);

        _requestRedeem(ali, shares);
        _processPendingRedeems();

        assertEq(spUSDC.balanceOf(ali), assets);
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
                        true,
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
