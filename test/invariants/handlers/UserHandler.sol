// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IERC20, SafeERC20 } from "../../../lib/oz/contracts/token/ERC20/utils/SafeERC20.sol";

import { IFTMS } from "../../../src/IFTMS.sol";

import { HandlerBase, Setup } from "./HandlerBase.sol";

contract UserHandler is HandlerBase {

    // Only this handler pushes requests, so these mirror each queue entry by entry: the owner, the
    // latest recipient, and the amount requested minus (for deposits) what the owner cancelled. An
    // entry's amount can only fall below its ghost if it was (partially) filled, which FIFO only
    // allows for the first pending entry.
    struct GhostEntry {
        address owner;
        address recipient;
        uint256 amount;
    }

    mapping (Queue => GhostEntry[]) internal _ghosts;

    // Reachability counters for the instant fill paths.
    uint256 public instantFillFull;
    uint256 public instantFillPartial;
    uint256 public instantFillNoCapacity;
    uint256 public instantFillOverTombstones;  // the head jumped over cancelled entries
    uint256 public instantFillBlockedByQueue;
    uint256 public instantFillsMatchingQueue;  // compared against the operator path
    uint256 public roundTrips;
    uint256 public zeroShareRedeemRequests;  // the whole request burned as fee (Spark PR #69)
    uint256 public roundTripsPartlyCancelled;

    // Not one of `users`: round trips are reverted afterwards, so they never touch the ghosts.
    address public roundTripper = makeAddr("roundTripper");

    constructor(Setup memory setup_, uint256 numUsers_) HandlerBase(setup_, numUsers_) {}

    function ghosts(Queue queue_) external view returns (GhostEntry[] memory) {
        return _ghosts[queue_];
    }

    /**********************************************************************************************/
    /*** Requests                                                                               ***/
    /**********************************************************************************************/

    function requestDeposit(uint256 assets_, uint256 userSeed_, uint256 recipientSeed_)
        public
        anyAction
        protocolAction
    {
        _requestDeposit(assets_, userSeed_, recipientSeed_);
    }

    function _requestDeposit(uint256 assets_, uint256 userSeed_, uint256 recipientSeed_) internal {
        address user_      = _randomUser(userSeed_);
        address recipient_ = _randomUser(recipientSeed_);

        if (vault.paused()) {
            uint256 minDeposit_ = vault.minDeposit();

            vm.prank(user_);
            vm.expectRevert(IFTMS.IsPaused.selector);
            vault.requestDeposit(minDeposit_, recipient_, 0);
            return;
        }

        if (asset.blocked(user_)) return;  // The asset's `transferFrom` would revert

        // Often the minimum, to reach the smallest amounts and their rounding.
        assets_ = assets_ % 4 == 0 ? vault.minDeposit() : _bound(assets_, vault.minDeposit(), maxAmount);

        asset.mint(user_, assets_);

        DepositSnapshot memory before_ = _depositSnapshot(recipient_);

        // With nothing unfilled queued, the request will be filled instantly. First work out what
        // the operator path would do with it instead.
        bool compare_ = vault.instantFill() && before_.pendingDepositAssets == 0;

        DepositOutcome memory queued_;

        if (compare_) queued_ = _queuedOutcome(user_, recipient_, assets_);

        vm.startPrank(user_);
        SafeERC20.forceApprove(IERC20(token), address(vault), assets_);
        uint256 requestId_ = vault.requestDeposit(assets_, recipient_, 0);
        vm.stopPrank();

        assertEq(requestId_, _ghosts[Queue.DEPOSIT].length, "requestDeposit: unexpected request id");

        _ghosts[Queue.DEPOSIT].push(GhostEntry(user_, recipient_, assets_));

        _checkInstantFill(before_, requestId_, assets_, recipient_);

        if (compare_) {
            _checkOutcome(queued_, _outcome(requestId_, recipient_));
            instantFillsMatchingQueue++;
        }
    }

    function requestDepositCancellation(uint256 idSeed_, uint256 recipientSeed_, uint256 assets_)
        public
        anyAction
        protocolAction
    {
        // Not pause-gated.
        ( bool found_, uint256 requestId_, IFTMS.Request memory request_ ) =
            _randomOpenRequest(Queue.DEPOSIT, idSeed_);

        if (!found_) return;

        uint256 minCancellation_ = vault.minDepositCancellation();

        if (request_.amount < minCancellation_) return;

        // Often the whole request, to leave cancelled entries for the instant fill to jump over.
        assets_ = assets_ % 2 == 0 ? request_.amount : _bound(assets_, minCancellation_, request_.amount);

        address recipient_ = _randomUser(recipientSeed_);

        vm.prank(request_.owner);
        uint256 cancellationId_ = vault.requestDepositCancellation(requestId_, recipient_, assets_);

        assertEq(
            cancellationId_,
            _ghosts[Queue.DEPOSIT_CANCELLATION].length,
            "requestDepositCancellation: unexpected request id"
        );

        _ghosts[Queue.DEPOSIT][requestId_].amount -= assets_;
        _ghosts[Queue.DEPOSIT_CANCELLATION].push(GhostEntry(request_.owner, recipient_, assets_));
    }

    function requestRedeem(uint256 shares_, uint256 userSeed_, uint256 recipientSeed_)
        public
        anyAction
        protocolAction
    {
        address user_      = _randomUser(userSeed_);
        uint256 balance_   = vault.balanceOf(user_);
        uint256 minRedeem_ = vault.minRedeem();

        if (vault.paused()) {
            vm.prank(user_);
            vm.expectRevert(IFTMS.IsPaused.selector);
            vault.requestRedeem(minRedeem_, user_);
            return;
        }

        if (balance_ < minRedeem_) return;

        // Often the whole balance, the minimum, or a round amount (exact fees at round rates).
        if      (shares_ % 5 == 0) shares_ = balance_;
        else if (shares_ % 5 == 1) shares_ = minRedeem_;
        else if (shares_ % 5 == 2 && balance_ >= 1000) shares_ = _max(minRedeem_, balance_ / 1000 * 1000);
        else                       shares_ = _bound(shares_, minRedeem_, balance_);

        address recipient_ = _randomUser(recipientSeed_);

        // The fee is the fee rate of the shares, rounded up, and is burned. The rest is queued.
        uint256 fee_    = (shares_ * vault.redeemFeeRate() + vault.WAD() - 1) / vault.WAD();
        uint256 supply_ = vault.totalSupply();

        vm.prank(user_);
        uint256 requestId_ = vault.requestRedeem(shares_, recipient_);

        assertEq(requestId_, _ghosts[Queue.REDEEM].length, "requestRedeem: unexpected request id");

        ( , , , uint256 queuedShares_ ) = vault.getPendingRedeemRequest(requestId_);

        assertEq(queuedShares_,       shares_ - fee_,  "requestRedeem: queued shares");
        assertEq(vault.totalSupply(), supply_ - fee_,  "requestRedeem: fee not burned");
        assertEq(vault.balanceOf(user_), balance_ - shares_, "requestRedeem: shares taken");

        if (queuedShares_ == 0) zeroShareRedeemRequests++;

        _ghosts[Queue.REDEEM].push(GhostEntry(user_, recipient_, queuedShares_));
    }

    /**********************************************************************************************/
    /*** Recipient updates                                                                      ***/
    /**********************************************************************************************/

    function updateDepositRecipient(uint256 idSeed_, uint256 recipientSeed_)
        public
        anyAction
        protocolAction
    {
        ( bool found_, uint256 requestId_, IFTMS.Request memory request_ ) =
            _randomOpenRequest(Queue.DEPOSIT, idSeed_);

        if (!found_) return;

        address recipient_ = _randomUser(recipientSeed_);

        vm.prank(request_.owner);
        vault.updateDepositRecipient(requestId_, recipient_);

        _ghosts[Queue.DEPOSIT][requestId_].recipient = recipient_;
    }

    function updateDepositCancellationRecipient(uint256 idSeed_, uint256 recipientSeed_)
        public
        anyAction
        protocolAction
    {
        ( bool found_, uint256 requestId_, IFTMS.Request memory request_ ) =
            _randomOpenRequest(Queue.DEPOSIT_CANCELLATION, idSeed_);

        if (!found_) return;

        address recipient_ = _randomUser(recipientSeed_);

        vm.prank(request_.owner);
        vault.updateDepositCancellationRecipient(requestId_, recipient_);

        _ghosts[Queue.DEPOSIT_CANCELLATION][requestId_].recipient = recipient_;
    }

    function updateRedeemRecipient(uint256 idSeed_, uint256 recipientSeed_)
        public
        anyAction
        protocolAction
    {
        ( bool found_, uint256 requestId_, IFTMS.Request memory request_ ) =
            _randomOpenRequest(Queue.REDEEM, idSeed_);

        if (!found_) return;

        address recipient_ = _randomUser(recipientSeed_);

        vm.prank(request_.owner);
        vault.updateRedeemRecipient(requestId_, recipient_);

        _ghosts[Queue.REDEEM][requestId_].recipient = recipient_;
    }

    /**********************************************************************************************/
    /*** Claims and share transfers                                                             ***/
    /**********************************************************************************************/

    // Anyone can claim on behalf of a recipient.
    function claim(uint256 recipientSeed_, uint256 callerSeed_) public anyAction protocolAction {
        uint256 start_ = _bound(recipientSeed_, 0, users.length - 1);

        for (uint256 i = 0; i < users.length; i++) {
            address recipient_ = users[(start_ + i) % users.length];

            if (vault.claimableAssetsOf(recipient_) == 0) continue;
            if (asset.blocked(recipient_))                continue;  // The transfer would revert

            uint256 claimable_ = vault.claimableAssetsOf(recipient_);
            uint256 balance_   = asset.balanceOf(recipient_);

            vm.prank(_randomUser(callerSeed_));
            vault.claim(recipient_);

            assertEq(asset.balanceOf(recipient_), balance_ + claimable_, "claim: wrong amount paid");
            return;
        }
    }

    function transfer(uint256 amount_, uint256 fromSeed_, uint256 toSeed_) public anyAction protocolAction {
        address from_ = _randomUser(fromSeed_);
        address to_   = _randomUser(toSeed_);

        amount_ = _bound(amount_, 0, vault.balanceOf(from_));

        uint256 fromBalance_ = vault.balanceOf(from_);
        uint256 toBalance_   = vault.balanceOf(to_);

        vm.prank(from_);
        assertTrue(vault.transfer(to_, amount_), "transfer: returned false");

        _checkTransfer(from_, to_, amount_, fromBalance_, toBalance_);
    }

    function _checkTransfer(address from_, address to_, uint256 amount_, uint256 fromBalance_, uint256 toBalance_)
        internal view
    {
        if (from_ == to_) {
            assertEq(vault.balanceOf(from_), fromBalance_, "transfer to self: balance changed");
        } else {
            assertEq(vault.balanceOf(from_), fromBalance_ - amount_, "transfer: sender balance");
            assertEq(vault.balanceOf(to_),   toBalance_   + amount_, "transfer: recipient balance");
        }
    }

    function transferFrom(uint256 amount_, uint256 ownerSeed_, uint256 spenderSeed_, uint256 toSeed_)
        public
        anyAction
        protocolAction
    {
        address owner_ = _randomUser(ownerSeed_);

        amount_ = _bound(amount_, 0, vault.balanceOf(owner_));

        // The exact amount, more than needed, or unlimited.
        uint256 allowance_ =
            ownerSeed_ % 3 == 0 ? amount_ :
            ownerSeed_ % 3 == 1 ? amount_ + _bound(spenderSeed_, 1, 1e30) :
                                  type(uint256).max;

        _transferFrom(owner_, _randomUser(spenderSeed_), _randomUser(toSeed_), amount_, allowance_);
    }

    function _transferFrom(address owner_, address spender_, address to_, uint256 amount_, uint256 allowance_)
        internal
    {
        vm.prank(owner_);
        vault.approve(spender_, allowance_);

        uint256 ownerBalance_ = vault.balanceOf(owner_);
        uint256 toBalance_    = vault.balanceOf(to_);

        vm.prank(spender_);
        assertTrue(vault.transferFrom(owner_, to_, amount_), "transferFrom: returned false");

        _checkTransfer(owner_, to_, amount_, ownerBalance_, toBalance_);

        // Spending your own shares or with an unlimited allowance leaves the allowance alone.
        assertEq(
            vault.allowance(owner_, spender_),
            spender_ == owner_ || allowance_ == type(uint256).max ? allowance_ : allowance_ - amount_,
            "transferFrom: allowance"
        );
    }

    /**********************************************************************************************/
    /*** Round trips                                                                            ***/
    /**********************************************************************************************/

    // A fresh user deposits, has the deposit filled as far as capacity allows, cancels the rest,
    // redeems every share, and has everything paid out, all at once. However the queues, price,
    // chi, capacity and fee stand, they can never get back more than they put in, and with no fee
    // they lose no more than rounding dust. The surplus checks only see the vault as a whole, so
    // they miss value moving between users. This check does not.
    // Everything is reverted afterwards, so no other state or ghost is affected.
    function roundTrip(uint256 assets_) public {
        if (vault.paused()) return;

        assets_ = _bound(assets_, 1, maxAmount);

        uint256 snapshot_ = vm.snapshotState();

        ( uint256 received_, bool cancelled_, uint256 maxLoss_, bool feeFree_ ) = _roundTrip(assets_);

        vm.revertToState(snapshot_);

        assertLe(received_, assets_, "round trip: profit");

        if (feeFree_) assertGe(received_ + maxLoss_, assets_, "round trip: lost more than dust");

        roundTrips++;
        if (cancelled_) roundTripsPartlyCancelled++;
    }

    function _roundTrip(uint256 assets_)
        internal returns (uint256 received_, bool cancelled_, uint256 maxLoss_, bool feeFree_)
    {
        address user_ = roundTripper;

        vm.startPrank(admin);
        vault.setMinDeposit(1);
        vault.setMinDepositCancellation(1);
        vault.setMinRedeem(1);
        vm.stopPrank();

        asset.mint(user_, assets_);

        vm.startPrank(user_);
        SafeERC20.forceApprove(IERC20(token), address(vault), assets_);
        uint256 depositId_ = vault.requestDeposit(assets_, user_, 0);
        vm.stopPrank();

        vm.prank(operator);
        vault.processPendingDeposits(type(uint256).max, type(uint256).max);

        if (vault.processedDepositCount() <= depositId_) {
            ( , , , uint256 unfilled_ ) = vault.getPendingDepositRequest(depositId_);

            if (unfilled_ != 0) {
                vm.prank(user_);
                vault.requestDepositCancellation(depositId_, user_, unfilled_);
                cancelled_ = true;
            }
        }

        uint256 shares_ = vault.balanceOf(user_);
        uint256 redeemId_;

        if (shares_ != 0) {
            vm.prank(user_);
            redeemId_ = vault.requestRedeem(shares_, user_);
        }

        // Enough liquidity for every pending cancellation and redeem, with a wide margin for the
        // per-entry rounding.
        asset.mint(
            address(vault),
            vault.pendingCancelledDepositAssets() + 2 * vault.convertToAssets(vault.pendingRedeemShares()) + 1e9
        );

        vm.startPrank(operator);
        vault.processPendingDepositCancellations(type(uint256).max, type(uint256).max);
        vault.processPendingRedeems(type(uint256).max, type(uint256).max);
        vm.stopPrank();

        assertEq(vault.pendingCancelledDepositAssets(), 0, "round trip: cancellation not paid");
        if (shares_ != 0) assertGt(vault.processedRedeemCount(), redeemId_, "round trip: redeem not filled");

        received_ = asset.balanceOf(user_) + vault.claimableAssetsOf(user_);

        // Four roundings down, the deposit's and the redeem's, each in reference value and then in
        // assets or shares: at most `(2 + chi / RAY) * RAY / price + 1` assets.
        maxLoss_ = (3 + vault.nowChi() / RAY) * (RAY / _price() + 1) + 1;
        feeFree_ = vault.redeemFeeRate() == 0;
    }

    /**********************************************************************************************/
    /*** Instant fill against the operator path                                                 ***/
    /**********************************************************************************************/

    struct DepositOutcome {
        uint256 totalSupply;
        uint256 recipientShares;
        uint256 processedDepositCount;
        uint256 pendingDepositAssets;
        uint256 unfilled;
    }

    // `instantFill` is the bool at byte 21 of slot 4 (`forge inspect FTMS storageLayout`).
    uint256 internal constant INSTANT_FILL_SLOT  = 4;
    uint256 internal constant INSTANT_FILL_SHIFT = 21 * 8;

    // The same request in a vault without `instantFill`, followed by the operator processing the
    // whole deposit queue. Reverted afterwards.
    function _queuedOutcome(address user_, address recipient_, uint256 assets_)
        internal returns (DepositOutcome memory outcome_)
    {
        uint256 snapshot_ = vm.snapshotState();

        address oracle_ = vault.referenceOracle();
        bool    paused_ = vault.paused();

        bytes32 slot_ = vm.load(address(vault), bytes32(INSTANT_FILL_SLOT));
        vm.store(address(vault), bytes32(INSTANT_FILL_SLOT), slot_ & ~bytes32(uint256(0xff) << INSTANT_FILL_SHIFT));

        assertFalse(vault.instantFill(),           "queued outcome: instantFill still set");
        assertEq(vault.referenceOracle(), oracle_, "queued outcome: storage layout");
        assertEq(vault.paused(),          paused_, "queued outcome: storage layout");

        vm.startPrank(user_);
        SafeERC20.forceApprove(IERC20(token), address(vault), assets_);
        uint256 requestId_ = vault.requestDeposit(assets_, recipient_, 0);
        vm.stopPrank();

        vm.prank(operator);
        vault.processPendingDeposits(type(uint256).max, type(uint256).max);

        outcome_ = _outcome(requestId_, recipient_);

        vm.revertToState(snapshot_);
    }

    function _outcome(uint256 requestId_, address recipient_) internal view returns (DepositOutcome memory outcome_) {
        outcome_.totalSupply           = vault.totalSupply();
        outcome_.recipientShares       = vault.balanceOf(recipient_);
        outcome_.processedDepositCount = vault.processedDepositCount();
        outcome_.pendingDepositAssets  = vault.pendingDepositAssets();

        if (outcome_.processedDepositCount <= requestId_) {
            ( , , , outcome_.unfilled ) = vault.getPendingDepositRequest(requestId_);
        }
    }

    function _checkOutcome(DepositOutcome memory queued_, DepositOutcome memory instant_) internal pure {
        assertEq(instant_.totalSupply,           queued_.totalSupply,           "instant vs queued: totalSupply");
        assertEq(instant_.recipientShares,       queued_.recipientShares,       "instant vs queued: recipient shares");
        assertEq(instant_.processedDepositCount, queued_.processedDepositCount, "instant vs queued: head");
        assertEq(instant_.pendingDepositAssets,  queued_.pendingDepositAssets,  "instant vs queued: pending assets");
        assertEq(instant_.unfilled,              queued_.unfilled,              "instant vs queued: request amount");
    }

    /**********************************************************************************************/
    /*** Instant fill checks                                                                    ***/
    /**********************************************************************************************/

    struct DepositSnapshot {
        uint256 pendingDepositAssets;
        uint256 processedDepositCount;
        uint256 totalSupply;
        uint256 recipientShares;
        uint256 maxCapacity;
        uint256 capacityAssets;
    }

    function _depositSnapshot(address recipient_) internal view returns (DepositSnapshot memory) {
        return DepositSnapshot({
            pendingDepositAssets  : vault.pendingDepositAssets(),
            processedDepositCount : vault.processedDepositCount(),
            totalSupply           : vault.totalSupply(),
            recipientShares       : vault.balanceOf(recipient_),
            maxCapacity           : vault.maxCapacity(),
            capacityAssets        : _capacityAssets()
        });
    }

    function _checkInstantFill(
        DepositSnapshot memory before_,
        uint256                requestId_,
        uint256                assets_,
        address                recipient_
    )
        internal
    {
        // A fully filled request is behind the head and deleted.
        uint256 unfilled_;

        if (vault.processedDepositCount() <= requestId_) {
            ( , , , unfilled_ ) = vault.getPendingDepositRequest(requestId_);
        }

        // No fill: nothing queued ahead is touched, the request waits in full.
        if (!vault.instantFill() || before_.pendingDepositAssets != 0) {
            if (vault.instantFill()) instantFillBlockedByQueue++;

            assertEq(vault.totalSupply(),           before_.totalSupply,                  "no instant fill: shares minted");
            assertEq(vault.processedDepositCount(), before_.processedDepositCount,        "no instant fill: head moved");
            assertEq(vault.pendingDepositAssets(),  before_.pendingDepositAssets + assets_, "no instant fill: pending assets");
            assertEq(unfilled_,                     assets_,                              "no instant fill: request amount");
            return;
        }

        // Nothing unfilled was queued: the request is filled up to the available capacity.
        uint256 filled_ = _min(assets_, before_.capacityAssets);
        uint256 shares_ = vault.convertReferenceValueToShares(_assetsToReferenceValue(filled_));

        if      (filled_ == assets_) instantFillFull++;
        else if (filled_ != 0)       instantFillPartial++;
        else                         instantFillNoCapacity++;

        if (requestId_ > before_.processedDepositCount) instantFillOverTombstones++;

        assertEq(vault.totalSupply(),          before_.totalSupply + shares_,     "instant fill: shares minted");
        assertEq(vault.balanceOf(recipient_),  before_.recipientShares + shares_, "instant fill: recipient shares");
        assertEq(vault.pendingDepositAssets(), assets_ - filled_,                 "instant fill: pending assets");
        assertEq(unfilled_,                    assets_ - filled_,                 "instant fill: request amount");

        assertEq(
            vault.processedDepositCount(),
            filled_ == assets_ ? requestId_ + 1 : requestId_,
            "instant fill: head"
        );

        if (before_.totalSupply <= before_.maxCapacity) {
            assertLe(vault.totalSupply(), before_.maxCapacity, "instant fill: above capacity");
        }
    }

}
