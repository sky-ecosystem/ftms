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

import { ERC1967Proxy } from "oz/proxy/ERC1967/ERC1967Proxy.sol";

import { ISparkPrimeVault } from "spark-prime-vault/ISparkPrimeVault.sol";
import { SparkPrimeVault }  from "spark-prime-vault/SparkPrimeVault.sol";

import { PassthroughVault } from "src/PassthroughVault.sol";

interface ChainlogLike {
    function getAddress(bytes32) external view returns (address);
}

interface GemLike {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface SleeveLike is GemLike {
    function asset() external view returns (address);
    function convertToAssets(uint256) external view returns (uint256);
    function deposit(uint256, address) external returns (uint256);
    function redeem(uint256, address, address) external returns (uint256);
}

// Scenarios every supported sleeve must pass. Amounts are in whole units of the asset.
abstract contract FtmsIntegrationTest is Test {
    ChainlogLike constant LOG = ChainlogLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    uint256 constant RAY       = 10 ** 27;
    uint256 constant TOLERANCE = 10; // wei
    uint256 constant VSR_5PCT  = 1.000000001547125957863212448e27;

    bytes32 constant LOSS_MANAGER_ROLE = keccak256("LOSS_MANAGER_ROLE");
    bytes32 constant OPERATOR_ROLE     = keccak256("OPERATOR_ROLE");
    bytes32 constant PAUSER_ROLE       = keccak256("PAUSER_ROLE");
    bytes32 constant TAKER_ROLE        = keccak256("TAKER_ROLE");
    bytes32 constant UNPAUSER_ROLE     = keccak256("UNPAUSER_ROLE");

    address admin       = address(0xAD);
    address lossManager = address(0x1055);
    address operator    = address(0x0BE);
    address pauser      = address(0xBA05E);
    address taker       = address(0x7A4E);
    address unpauser    = address(0x0BA05E);
    address alice       = address(0xA11CE);
    address bob         = address(0xB0B);

    GemLike         gem;
    SleeveLike      sleeve;
    SparkPrimeVault vault;
    uint256         unit;

    function _sleeve() internal virtual returns (address);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        sleeve = SleeveLike(_sleeve());
        gem    = GemLike(sleeve.asset());
        unit   = 10 ** gem.decimals();

        vault = SparkPrimeVault(address(new ERC1967Proxy(
            address(new SparkPrimeVault()),
            abi.encodeCall(ISparkPrimeVault.initialize, (
                address(sleeve),
                "FTMS Test Vault",
                "ftmsTEST",
                admin,
                100 * unit, // minDeposit
                1,          // minDepositCancellation
                1           // minRedeem
            ))
        )));

        vm.startPrank(admin);
        vault.grantRole(LOSS_MANAGER_ROLE, lossManager);
        vault.grantRole(OPERATOR_ROLE,     operator);
        vault.grantRole(PAUSER_ROLE,       pauser);
        vault.grantRole(TAKER_ROLE,        taker);
        vault.grantRole(UNPAUSER_ROLE,     unpauser);
        vault.setVSRBounds(RAY, vault.MAX_VSR());
        vm.stopPrank();

        vm.prank(operator); vault.setCapacity(1_000_000_000 * unit);
    }

    // --- Helpers ---

    function _requestDeposit(address usr, uint256 assets) internal returns (uint256 requestId) {
        deal(address(gem), usr, assets);
        vm.startPrank(usr);
        gem.approve(address(vault), assets);
        requestId = vault.requestDeposit(assets, usr, 0);
        vm.stopPrank();
    }

    function _requestRedeem(address usr, uint256 shares) internal {
        vm.prank(usr); vault.requestRedeem(shares, usr);
    }

    function _processDeposits() internal {
        vm.prank(operator); vault.processPendingDeposits(type(uint256).max, type(uint256).max);
    }

    function _processRedeems() internal {
        vm.prank(operator); vault.processPendingRedeems(type(uint256).max, type(uint256).max);
    }

    function _processCancellations() internal {
        vm.prank(operator); vault.processPendingDepositCancellations(type(uint256).max, type(uint256).max);
    }

    // Takes all sleeve shares out of the vault and redeems them for the asset
    function _takeAll() internal {
        uint256 shares = sleeve.balanceOf(address(vault));
        vm.startPrank(taker);
        vault.take(shares);
        sleeve.redeem(shares, taker, taker);
        vm.stopPrank();
    }

    // Returns capital as sleeve shares (only those count as liquidity)
    function _return(uint256 assets) internal {
        deal(address(gem), taker, assets);
        vm.startPrank(taker);
        gem.approve(address(sleeve), assets);
        sleeve.deposit(assets, address(vault));
        vm.stopPrank();
    }

    function _backing() internal view returns (uint256) {
        return sleeve.convertToAssets(sleeve.balanceOf(address(vault)));
    }

    // --- Deposits and redemptions ---

    function testDepositAndRedeem() public {
        _requestDeposit(alice, 1_000 * unit); // First deposit is processed immediately
        uint256 shares = vault.balanceOf(alice);

        assertGt(shares, 0);
        assertApproxEqAbs(vault.assetsOf(alice), 1_000 * unit, TOLERANCE);
        assertApproxEqAbs(_backing(),            1_000 * unit, TOLERANCE);

        _requestRedeem(alice, shares);
        _processRedeems();

        assertEq(vault.totalSupply(), 0);
        assertApproxEqAbs(gem.balanceOf(alice), 1_000 * unit, TOLERANCE);
        assertLe(gem.balanceOf(alice), 1_000 * unit); // Rounding stays with the vault
    }

    function testQueuedDepositsFifoWithinCapacity() public {
        vm.prank(operator); vault.setCapacity(0);
        _requestDeposit(alice, 1_000 * unit);
        _requestDeposit(bob,   2_000 * unit);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob),   0);

        // Room for alice and half of bob
        uint256 capacity = vault.convertToShares(2_000 * unit);
        vm.prank(operator); vault.setCapacity(capacity);
        _processDeposits();

        assertApproxEqAbs(vault.assetsOf(alice), 1_000 * unit, TOLERANCE);
        assertApproxEqAbs(vault.assetsOf(bob),   1_000 * unit, TOLERANCE);
        assertGt(vault.pendingDepositSavingsShares(), 0);
    }

    function testVsrPaidFromReturnedCapital() public {
        vm.prank(operator); vault.setVSR(VSR_5PCT);
        _requestDeposit(alice, 1_000 * unit);
        _takeAll();

        assertEq(vault.availableLiquidAssets(), 0);

        skip(365 days);
        uint256 owed = vault.assetsOf(alice);
        assertApproxEqRel(owed, 1_050 * unit, 0.001e18);

        _return(1_100 * unit);
        _requestRedeem(alice, vault.balanceOf(alice));
        _processRedeems();

        assertApproxEqAbs(gem.balanceOf(alice), owed, TOLERANCE);
    }

    // --- Deposit cancellations ---

    function testCancellationRefundsQueuedValue() public {
        vm.prank(operator); vault.setCapacity(0);
        uint256 requestId = _requestDeposit(alice, 1_000 * unit);

        skip(30 days);
        uint256 queued   = vault.pendingDepositSavingsShares();
        uint256 expected = sleeve.convertToAssets(queued);
        assertGe(expected + TOLERANCE, 1_000 * unit); // Sleeve yield accrues to the depositor

        vm.prank(alice); vault.requestDepositCancellation(requestId, alice, queued);
        _processCancellations();

        assertApproxEqAbs(gem.balanceOf(alice), expected, TOLERANCE);
        assertEq(vault.balanceOf(alice), 0);
    }

    function testPendingDepositsCanBeTaken() public {
        vm.prank(operator); vault.setCapacity(0);
        uint256 requestId = _requestDeposit(alice, 1_000 * unit);
        _takeAll();

        uint256 queued = vault.pendingDepositSavingsShares();
        vm.prank(alice); vault.requestDepositCancellation(requestId, alice, queued);
        _processCancellations();
        assertEq(gem.balanceOf(alice), 0); // Unpaid until capital returns

        _return(1_000 * unit);
        _processCancellations();
        assertApproxEqRel(gem.balanceOf(alice), 1_000 * unit, 0.001e18);
    }

    // --- Liquidity ---

    function testTakeAndReturn() public {
        _requestDeposit(alice, 1_000 * unit);
        _takeAll();

        _requestRedeem(alice, vault.balanceOf(alice));
        _processRedeems();
        assertEq(gem.balanceOf(alice), 0); // Out of liquidity, request stays queued

        _return(1_000 * unit);
        _processRedeems();
        assertApproxEqAbs(gem.balanceOf(alice), 1_000 * unit, TOLERANCE);
        assertEq(vault.pendingRedeemShares(), 0);
    }

    function testAssetSentDirectlyIsNotLiquidity() public {
        _requestDeposit(alice, 1_000 * unit);
        _takeAll();
        deal(address(gem), address(vault), 1_000 * unit);

        assertEq(vault.availableLiquidAssets(), 0);

        _requestRedeem(alice, vault.balanceOf(alice));
        _processRedeems();

        assertEq(gem.balanceOf(alice), 0);
        assertEq(gem.balanceOf(address(vault)), 1_000 * unit); // Stranded
    }

    function testDustRedeemRemainder() public {
        _requestDeposit(alice, 1_000 * unit);
        _requestDeposit(bob,   1_000 * unit);
        uint256 shares = vault.balanceOf(alice);
        _requestRedeem(alice, shares);
        _requestRedeem(bob,   vault.balanceOf(bob));

        // Leave 1 wei of alice's request at the head of the queue
        vm.prank(operator); vault.processPendingRedeems(shares - 1, 1);
        (,,, uint256 remainder) = vault.getPendingRedeemRequest(0);
        assertEq(remainder, 1);

        // Needs the sleeve's `redeem(0)` to succeed
        _processRedeems();

        assertEq(vault.pendingRedeemShares(), 0);
        assertApproxEqAbs(gem.balanceOf(bob), 1_000 * unit, TOLERANCE);
    }

    // --- Losses ---

    function testImpairSharesLossProRata() public {
        _requestDeposit(alice, 1_000 * unit);
        _requestDeposit(bob,   1_000 * unit);
        _takeAll();
        _return(1_800 * unit); // 10% loss

        vm.prank(pauser);      vault.pause();
        vm.prank(lossManager); vault.impair(200 * unit);
        vm.prank(unpauser);    vault.unpause();

        _requestRedeem(alice, vault.balanceOf(alice));
        _requestRedeem(bob,   vault.balanceOf(bob));
        _processRedeems();

        assertApproxEqRel(gem.balanceOf(alice), 900 * unit, 0.0001e18);
        assertApproxEqRel(gem.balanceOf(bob),   900 * unit, 0.0001e18);
    }
}

contract UsdcPassthroughIntegrationTest is FtmsIntegrationTest {
    function _sleeve() internal override returns (address) {
        return address(new PassthroughVault(LOG.getAddress("USDC"), "Passthrough USDC", "ptUSDC"));
    }
}

contract UsdsPassthroughIntegrationTest is FtmsIntegrationTest {
    function _sleeve() internal override returns (address) {
        return address(new PassthroughVault(LOG.getAddress("USDS"), "Passthrough USDS", "ptUSDS"));
    }
}

contract SUsdsIntegrationTest is FtmsIntegrationTest {
    function _sleeve() internal view override returns (address) {
        return LOG.getAddress("SUSDS");
    }

    function testQueuedDepositsEarnSsr() public {
        vm.prank(operator); vault.setCapacity(0);
        _requestDeposit(alice, 1_000 * unit);

        uint256 before = sleeve.convertToAssets(vault.pendingDepositSavingsShares());
        skip(365 days);
        assertGt(sleeve.convertToAssets(vault.pendingDepositSavingsShares()), before);
    }
}

// Not a valid sleeve: `redeem(0)` reverts, so a dust remainder would block the redeem queue
contract StUsdsIntegrationTest is Test {
    ChainlogLike constant LOG = ChainlogLike(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
    }

    function testRedeemZeroReverts() public {
        SleeveLike stUsds = SleeveLike(LOG.getAddress("STUSDS"));
        vm.expectRevert("StUsds/assets-zero");
        stUsds.redeem(0, address(this), address(this));
    }
}
