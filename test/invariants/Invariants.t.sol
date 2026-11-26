// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { console } from "../../lib/forge-std/src/console.sol";

import { Ethereum } from "../../lib/spark-address-registry/src/Ethereum.sol";

import { InvariantsBase } from "./InvariantsBase.t.sol";

import { HandlerBase } from "./handlers/HandlerBase.sol";

abstract contract InvariantTestBase is InvariantsBase {

    /**********************************************************************************************/
    /*** Post-invariant: full unwind                                                           ***/
    /**********************************************************************************************/

    // From any reachable state, once the vault is unpaused, nobody is blocked, the taker has
    // returned everything and capacity is open, every queue drains, every holder exits and every
    // claim is paid.
    function afterInvariant() public {
        _logMetrics();

        _checkInvariantsOverTime();

        // 1. Normalise.
        if (vault.paused()) {
            vm.prank(unpauser);
            vault.unpause();
        }

        for (uint256 i = 0; i < NUM_USERS; i++) {
            asset.setBlocked(userHandler.users(i), false);
        }

        uint256 taken_ = asset.balanceOf(taker);

        asset.burn(taker, taken_);
        asset.mint(address(vault), taken_);

        vm.prank(operator);
        vault.setCapacity(type(uint128).max);

        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(0);

        vm.startPrank(admin);
        vault.setMinDepositCancellation(1);
        vault.setMinRedeem(1);
        vm.stopPrank();

        _checkInvariantsOverTime();

        // 2. Deposits: one call fills everything with the capacity open, unless the shares would
        //    exceed the largest capacity (only after extreme impairments with huge amounts). Those
        //    owners cancel instead.
        vm.prank(operator);
        vault.processPendingDeposits(type(uint256).max, type(uint256).max);

        if (vault.pendingDepositAssets() != 0) {
            ( , , , uint256 head_ ) = vault.getPendingDepositRequest(vault.processedDepositCount());

            // Worked out here rather than with the vault's own conversions, which could be the
            // reason the deposit is stuck.
            uint256 sharesNeeded_ = _toReference(head_) * RAY / vault.nowChi();

            assertGt(vault.totalSupply() + sharesNeeded_, type(uint128).max, "unwind: deposits stuck below capacity");

            while (vault.pendingDepositAssets() != 0) userHandler.requestDepositCancellation(0, 0, 0);
        }

        assertEq(vault.pendingDepositAssets(), 0, "unwind: deposit queue not drained");

        // 3. Cancellations: a solvent vault holds enough. Otherwise top it up first.
        uint256 owed_       = vault.pendingCancelledDepositAssets();
        uint256 available_  = vault.availableLiquidAssets();

        if (_strict()) assertGe(available_, owed_, "unwind: strict vault short for cancellations");

        if (available_ < owed_) asset.mint(address(vault), owed_ - available_);

        vm.prank(operator);
        vault.processPendingDepositCancellations(type(uint256).max, type(uint256).max);

        assertEq(vault.pendingCancelledDepositAssets(), 0, "unwind: cancellation queue not drained");

        _checkInvariantsOverTime();

        // 4. Every holder redeems everything. Seed `i` resolves to user `i`, and a shares seed of 0
        //    redeems the whole balance.
        for (uint256 i = 0; i < NUM_USERS; i++) {
            userHandler.requestRedeem(0, i, i);
        }

        assertEq(vault.balanceOf(address(vault)), vault.totalSupply(), "unwind: supply not fully escrowed");

        // 5. Redeems. A solvent vault can pay everything except shares worth less than about one
        //    reference unit, which round down to no assets.
        if (_strict()) {
            _processRedeemsWithoutTopUp();

            assertLt(
                vault.pendingRedeemShares() * vault.nowChi(),
                vault.nowChi() + RAY,
                "unwind: strict vault short for redeems"
            );
        }

        _processRedeemsWithTopUp();

        assertEq(vault.pendingRedeemShares(),       0, "unwind: redeem queue not drained");
        assertEq(vault.totalSupply(),               0, "unwind: totalSupply != 0 after full exit");
        assertEq(vault.balanceOf(address(vault)), 0, "unwind: escrow left after full exit");

        // 6. Claims: nobody is blocked any more, so every claimable is payable.
        for (uint256 i = 0; i < NUM_USERS; i++) {
            address user_ = userHandler.users(i);

            if (vault.claimableAssetsOf(user_) != 0) vault.claim(user_);
        }

        assertEq(vault.totalClaimable(), 0, "unwind: claimables left");

        _checkInvariantsOverTime();
    }

    /**********************************************************************************************/
    /*** Internal Helpers                                                                       ***/
    /**********************************************************************************************/

    function _checkInvariantsOverTime() internal {
        invariant_vault();

        uint256[] memory values_ = new uint256[](NUM_USERS);

        for (uint256 i = 0; i < NUM_USERS; i++) {
            values_[i] = vault.referenceValueOf(userHandler.users(i));
        }

        uint256 total_ = vault.totalReferenceValue();

        skip(30 minutes);

        // With no interactions, reference values can only grow over time. Asset values can fall,
        // if the oracle price rises.
        for (uint256 i = 0; i < NUM_USERS; i++) {
            assertGe(vault.referenceValueOf(userHandler.users(i)), values_[i], "referenceValueOf decreased");
        }

        assertGe(vault.totalReferenceValue(), total_, "totalReferenceValue decreased");

        invariant_vault();
    }

    // Processes redeems until no call makes progress.
    function _processRedeemsWithoutTopUp() internal {
        for (uint256 i = 0; i < 100; i++) {
            uint256 pending_   = vault.pendingRedeemShares();
            uint256 processed_ = vault.processedRedeemCount();

            vm.prank(operator);
            vault.processPendingRedeems(type(uint256).max, type(uint256).max);

            if (vault.pendingRedeemShares() == pending_ && vault.processedRedeemCount() == processed_) return;
        }

        revert("unwind: redeems never stop making progress");
    }

    // Tops the vault up as needed until every redeem is filled.
    function _processRedeemsWithTopUp() internal {
        uint256 topUp_ = 1;

        for (uint256 i = 0; i < 100; i++) {
            if (vault.pendingRedeemRequestsLength() == 0) return;

            uint256 owed_      = vault.convertToAssets(vault.pendingRedeemShares());
            uint256 available_ = vault.availableLiquidAssets();

            asset.mint(address(vault), (available_ < owed_ ? owed_ - available_ : 0) + topUp_);

            vm.prank(operator);
            vault.processPendingRedeems(type(uint256).max, type(uint256).max);

            topUp_ *= 2;
        }

        revert("unwind: redeems not filled");
    }

    function _logMetrics() internal view {
        if (!vm.envOr("INVARIANT_METRICS", false)) return;

        console.log("instantFillFull           ", userHandler.instantFillFull());
        console.log("instantFillPartial        ", userHandler.instantFillPartial());
        console.log("instantFillNoCapacity     ", userHandler.instantFillNoCapacity());
        console.log("instantFillOverTombstones ", userHandler.instantFillOverTombstones());
        console.log("instantFillBlockedByQueue ", userHandler.instantFillBlockedByQueue());
        console.log("zeroShareDepositFills     ", operatorHandler.zeroShareDepositFills());
        console.log("zeroAssetRedeemFills      ", operatorHandler.zeroAssetRedeemFills());
        console.log("multiEntryRedeemFills     ", operatorHandler.multiEntryRedeemFills());
        console.log("impairments               ", operatorHandler.impairments());
        console.log("oracleLosses              ", externalHandler.oracleLosses());
        console.log("upgrades                  ", operatorHandler.upgrades());
        console.log("zeroShareRedeemRequests   ", userHandler.zeroShareRedeemRequests());
        console.log("roundTrips                ", userHandler.roundTrips());
        console.log("roundTripsPartlyCancelled ", userHandler.roundTripsPartlyCancelled());
        console.log("instantFillsMatchingQueue ", userHandler.instantFillsMatchingQueue());
        console.log("priceDrops                ", externalHandler.priceDrops());
        console.log("priceRises                ", externalHandler.priceRises());
        console.log("totalClaimable            ", vault.totalClaimable());
        console.log("deposit requests          ", userHandler.ghosts(HandlerBase.Queue.DEPOSIT).length);
        console.log("redeem requests           ", userHandler.ghosts(HandlerBase.Queue.REDEEM).length);
    }

}

/**********************************************************************************************/
/*** Mainnet fork configurations                                                            ***/
/**********************************************************************************************/

// Spark's setup: spUSDC as both asset and oracle, so the reference unit is USDC.
contract SpUsdcInstantFillInvariantTest is InvariantTestBase {

    function _forkAsset()   internal pure override returns (address) { return Ethereum.SPARK_VAULT_V2_SPUSDC; }
    function _forkOracle()  internal pure override returns (address) { return Ethereum.SPARK_VAULT_V2_SPUSDC; }
    function _instantFill() internal pure override returns (bool)    { return true; }

}

contract SpUsdcNoInstantFillInvariantTest is InvariantTestBase {

    function _forkAsset()   internal pure override returns (address) { return Ethereum.SPARK_VAULT_V2_SPUSDC; }
    function _forkOracle()  internal pure override returns (address) { return Ethereum.SPARK_VAULT_V2_SPUSDC; }
    function _instantFill() internal pure override returns (bool)    { return false; }

}

// Spark's setup with the VSR at 0%: spUSDC's price only rises, so the vault can never be short.
contract SpUsdcStrictInvariantTest is InvariantTestBase {

    function _forkAsset()   internal pure override returns (address) { return Ethereum.SPARK_VAULT_V2_SPUSDC; }
    function _forkOracle()  internal pure override returns (address) { return Ethereum.SPARK_VAULT_V2_SPUSDC; }
    function _instantFill() internal pure override returns (bool)    { return true; }
    function _strict()      internal pure override returns (bool)    { return true; }

}

contract SpUsdtInvariantTest is InvariantTestBase {

    function _forkAsset()   internal pure override returns (address) { return Ethereum.SPARK_VAULT_V2_SPUSDT; }
    function _forkOracle()  internal pure override returns (address) { return Ethereum.SPARK_VAULT_V2_SPUSDT; }
    function _instantFill() internal pure override returns (bool)    { return true; }

}

// 18 decimals, reference unit USDS.
contract SUsdsInvariantTest is InvariantTestBase {

    function _forkAsset()   internal pure override returns (address) { return Ethereum.SUSDS; }
    function _forkOracle()  internal pure override returns (address) { return Ethereum.SUSDS; }
    function _instantFill() internal pure override returns (bool)    { return true; }

}

// stUSDS can lose value (`cut`), so its price can fall for real. As the README advises for an
// asset that can lose value, `instantFill` is off.
contract StUsdsInvariantTest is InvariantTestBase {

    function _forkAsset()   internal pure override returns (address) { return STUSDS; }
    function _forkOracle()  internal pure override returns (address) { return STUSDS; }
    function _instantFill() internal pure override returns (bool)    { return false; }

}

// No oracle: the reference unit is spUSDC itself, so holders earn spUSDC's yield plus the VSR.
contract SpUsdcNoOracleInvariantTest is InvariantTestBase {

    function _forkAsset()   internal pure override returns (address) { return Ethereum.SPARK_VAULT_V2_SPUSDC; }
    function _instantFill() internal pure override returns (bool)    { return true; }

}

// USDC's blacklist blocks both sides of a transfer, so payouts to blocked recipients go to claims.
contract UsdcInvariantTest is InvariantTestBase {

    function _forkAsset()   internal pure override returns (address) { return Ethereum.USDC; }
    function _instantFill() internal pure override returns (bool)    { return true; }

}

// USDT returns no value from `transfer`, and its blacklist only blocks senders.
contract UsdtInvariantTest is InvariantTestBase {

    function _forkAsset()   internal pure override returns (address) { return Ethereum.USDT; }
    function _instantFill() internal pure override returns (bool)    { return true; }

}

contract UsdsInvariantTest is InvariantTestBase {

    function _forkAsset()   internal pure override returns (address) { return Ethereum.USDS; }
    function _instantFill() internal pure override returns (bool)    { return true; }

}

// sUSDC can't be its own oracle: its shares have 18 decimals but convert to 6-decimal USDC, which
// the README rules out. It works as an asset without one.
contract SUsdcNoOracleInvariantTest is InvariantTestBase {

    function _forkAsset()   internal pure override returns (address) { return Ethereum.SUSDC; }
    function _instantFill() internal pure override returns (bool)    { return true; }

}

/**********************************************************************************************/
/*** Mock configurations                                                                    ***/
/**********************************************************************************************/

// What a fork cannot do: oracle prices that jump either way by up to 1000x, a blocklist that also
// blocks recipients of a token without return values, and amounts near the uint128 capacity.

// Like spUSDC as both asset and oracle, but with a price that can also fall.
contract MockOracleInstantFillInvariantTest is InvariantTestBase {

    function _hasOracle()   internal pure override returns (bool) { return true; }
    function _instantFill() internal pure override returns (bool) { return true; }

}

contract MockOracleNoInstantFillInvariantTest is InvariantTestBase {

    function _hasOracle()   internal pure override returns (bool) { return true;  }
    function _instantFill() internal pure override returns (bool) { return false; }

}

// No oracle, no return value from `transfer`, and recipients can be blocked.
contract MockNoOracleInstantFillInvariantTest is InvariantTestBase {

    function _instantFill() internal pure override returns (bool) { return true; }
    function _noReturn()    internal pure override returns (bool) { return true; }

}

// An 18-decimal asset and amounts up to 1e18 whole tokens per action, towards the uint128 capacity
// limit, so that products like `shares * chi` and `assets * price` run at their largest.
contract MockLargeAmountsInvariantTest is InvariantTestBase {

    function _hasOracle()   internal pure override returns (bool)    { return true; }
    function _instantFill() internal pure override returns (bool)    { return true; }
    function _decimals()    internal pure override returns (uint8)   { return 18;   }
    function _maxAmount()   internal pure override returns (uint256) { return 1e36; }

}

// VSR at 0% and a price that only rises, in jumps of up to 1000x: the vault can never be short.
contract MockStrictSolvencyInvariantTest is InvariantTestBase {

    function _hasOracle()   internal pure override returns (bool) { return true; }
    function _instantFill() internal pure override returns (bool) { return true; }
    function _strict()      internal pure override returns (bool) { return true; }

}
