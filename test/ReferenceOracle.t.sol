// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Ethereum } from "../lib/spark-address-registry/src/Ethereum.sol";

import { IERC20 } from "../lib/oz/contracts/token/ERC20/IERC20.sol";

import { ERC1967Proxy, ISparkVaultLike, TestBase, FTMS } from "./TestBase.t.sol";

import { IFTMS } from "../src/IFTMS.sol";

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
        FTMS vault = FTMS(
            address(new ERC1967Proxy(
                address(new FTMS()),
                abi.encodeCall(
                    IFTMS.initialize,
                    (
                        address(spUSDC),
                        address(0),
                        true,
                        "FTMS spUSDC",
                        "ftmsSpUSDC",
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

    function test_referenceOracleReverts() external {
        _requestDeposit(ali, 1_000_000e6);  // Filled instantly

        address bob = makeAddr("bob");

        _setCapacity(0);
        uint256 savingsShares = spUSDC.convertToShares(500_000e6);
        _requestDeposit(bob, 500_000e6);  // Queued

        vm.mockCallRevert(address(spUSDC), abi.encodeWithSelector(ISparkVaultLike.convertToAssets.selector), "");
        vm.mockCallRevert(address(spUSDC), abi.encodeWithSelector(ISparkVaultLike.convertToShares.selector), "");

        // Deposit cancellations don't use the oracle.
        _requestDepositCancellation(bob, 1, savingsShares);
        _processPendingDepositCancellations(1);

        assertEq(spUSDC.balanceOf(bob), savingsShares);

        // Deposits and redemptions can't be processed.
        _requestRedeem(ali, spPrime.balanceOf(ali));

        vm.prank(operator);
        vm.expectRevert(bytes(""));
        spPrime.processPendingRedeems(type(uint256).max, type(uint256).max);

        vm.prank(operator);
        vm.expectRevert(bytes(""));
        spPrime.processPendingDeposits(type(uint256).max, type(uint256).max);
    }

}

interface IUSDTLike {

    function approve(address spender, uint256 amount) external;

    function balanceOf(address owner) external view returns (uint256);

    function transfer(address to, uint256 amount) external;

}

// The asset can be a plain token whose `transfer` returns no value, without a reference oracle.
contract NoReturnValueAssetTests is TestBase {

    IUSDTLike internal usdt = IUSDTLike(Ethereum.USDT);

    address internal ali = makeAddr("ali");

    FTMS internal vault;

    function setUp() public override {
        super.setUp();

        vault = FTMS(
            address(new ERC1967Proxy(
                address(new FTMS()),
                abi.encodeCall(
                    IFTMS.initialize,
                    (address(usdt), address(0), true, "FTMS USDT", "ftmsUSDT", admin, 1, 1, 1)
                )
            ))
        );

        vm.startPrank(admin);
        vault.grantRole(OPERATOR_ROLE, operator);
        vault.grantRole(TAKER_ROLE,    taker);
        vault.setVSRBounds(RAY, vault.MAX_VSR());
        vm.stopPrank();

        vm.startPrank(operator);
        vault.setCapacity(VAULT_CAPACITY);
        vault.setVSR(FIVE_PCT_VSR);
        vm.stopPrank();
    }

    function test_noReturnValueAsset() external {
        deal(address(usdt), ali, 1_000_000e6);

        vm.startPrank(ali);
        usdt.approve(address(vault), 1_000_000e6);
        vault.requestDeposit(1_000_000e6, ali, 0);  // Filled instantly
        vm.stopPrank();

        assertEq(vault.balanceOf(ali),             1_000_000e6);
        assertEq(usdt.balanceOf(address(vault)),   1_000_000e6);

        vm.prank(taker);
        vault.take(1_000_000e6);

        assertEq(usdt.balanceOf(taker),            1_000_000e6);
        assertEq(usdt.balanceOf(address(vault)),   0);

        skip(365 days);

        // Return the capital plus the VSR.
        deal(address(usdt), taker, 1_050_000e6);

        vm.prank(taker);
        usdt.transfer(address(vault), 1_050_000e6);

        vm.prank(ali);
        vault.requestRedeem(1_000_000e6, ali);

        // The payout fails, so it is credited as claimable.
        vm.mockCallRevert(
            address(usdt),
            abi.encodeWithSelector(IERC20.transfer.selector, ali, 1_050_000e6 - 1),
            ""
        );

        vm.prank(operator);
        vault.processPendingRedeems(type(uint256).max, type(uint256).max);

        assertEq(vault.claimableAssetsOf(ali), 1_050_000e6 - 1);
        assertEq(vault.availableLiquidAssets(), 1);

        vm.clearMockedCalls();

        vault.claim(ali);

        assertEq(usdt.balanceOf(ali),            1_050_000e6 - 1);
        assertEq(usdt.balanceOf(address(vault)), 1);
        assertEq(vault.claimableAssetsOf(ali),   0);
    }

}
