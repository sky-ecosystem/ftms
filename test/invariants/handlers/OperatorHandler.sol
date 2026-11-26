// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IFTMS } from "../../../src/IFTMS.sol";
import { FTMS }  from "../../../src/FTMS.sol";

import { HandlerBase, Setup } from "./HandlerBase.sol";

// Every privileged role: admin, operator, taker, redeem fee setter, pauser, unpauser and loss
// manager.
contract OperatorHandler is HandlerBase {

    // Lowest chi an impairment may leave (the contract allows down to zero, which bricks it).
    uint256 internal constant MIN_CHI = 1e18;

    // Ghost flag read by the invariants.
    bool public capacityLoweredBelowSupply;

    // Reachability counters.
    uint256 public zeroShareDepositFills;
    uint256 public zeroAssetRedeemFills;
    uint256 public multiEntryRedeemFills;  // several entries filled, then liquidity ran out
    uint256 public impairments;
    uint256 public upgrades;

    constructor(Setup memory setup_, uint256 numUsers_) HandlerBase(setup_, numUsers_) {}

    /**********************************************************************************************/
    /*** Queue processing                                                                       ***/
    /**********************************************************************************************/

    function processPendingDeposits(uint256 maxAssets_, uint256 maxRequests_)
        public
        anyAction
        protocolAction
    {
        if (vault.paused()) {
            vm.prank(operator);
            vm.expectRevert(IFTMS.IsPaused.selector);
            vault.processPendingDeposits(maxAssets_, maxRequests_);
            return;
        }

        ( maxAssets_, maxRequests_ ) =
            _boundProcessing(Queue.DEPOSIT, vault.pendingDepositAssets(), maxAssets_, maxRequests_);

        Fill memory fill_ = _fillSnapshot(Queue.DEPOSIT);

        uint256 capacityAssets_ = _capacityAssets();

        vm.prank(operator);
        vault.processPendingDeposits(maxAssets_, maxRequests_);

        uint256 filled_  = fill_.pending - vault.pendingDepositAssets();
        uint256 minted_  = vault.totalSupply() - fill_.totalSupply;
        uint256 entries_ = _checkOnlyRecipientsPaid(fill_);

        if (filled_ != 0 && minted_ == 0) zeroShareDepositFills++;

        assertLe(filled_, maxAssets_, "processPendingDeposits: above maxAssets");

        // With every request in reach, the fill goes as far as the pending assets, `maxAssets` and
        // the capacity allow.
        if (maxRequests_ >= fill_.window.length) {
            assertEq(
                filled_,
                _min(fill_.pending, _min(maxAssets_, capacityAssets_)),
                "processPendingDeposits: filled the wrong amount"
            );
        }
        assertLe(vault.processedDepositCount() - fill_.head, maxRequests_, "processPendingDeposits: above maxRequests");

        // Each entry is priced on its own, rounding down twice, so the shares minted fall short of
        // pricing the whole amount at once by less than `RAY / chi + 2` per entry.
        assertGe(
            minted_ + entries_ * (RAY / vault.nowChi() + 2),
            vault.convertToShares(filled_),
            "processPendingDeposits: too few shares"
        );

        if (fill_.totalSupply <= fill_.maxCapacity) {
            assertLe(vault.totalSupply(), fill_.maxCapacity, "processPendingDeposits: above capacity");
        }
    }

    function processPendingDepositCancellations(uint256 maxAssets_, uint256 maxRequests_)
        public
        anyAction
        protocolAction
    {
        // Not pause-gated.
        ( maxAssets_, maxRequests_ ) = _boundProcessing(
            Queue.DEPOSIT_CANCELLATION,
            vault.pendingCancelledDepositAssets(),
            maxAssets_,
            maxRequests_
        );

        Fill memory fill_ = _fillSnapshot(Queue.DEPOSIT_CANCELLATION);

        vm.prank(operator);
        vault.processPendingDepositCancellations(maxAssets_, maxRequests_);

        uint256 paid_ = _assetsOwedOrPaid() - fill_.owedOrPaid;

        _checkOnlyRecipientsPaid(fill_);

        // Cancellations are refunded one to one, whether paid out or credited as claimable.
        assertEq(paid_, fill_.pending - vault.pendingCancelledDepositAssets(), "processPendingDepositCancellations: refund");
        assertLe(paid_, maxAssets_,                                            "processPendingDepositCancellations: above maxAssets");

        if (maxRequests_ >= fill_.window.length) {
            assertEq(
                paid_,
                _min(fill_.pending, _min(maxAssets_, fill_.liquidity)),
                "processPendingDepositCancellations: refunded the wrong amount"
            );
        }
        assertLe(
            vault.processedDepositCancellationCount() - fill_.head,
            maxRequests_,
            "processPendingDepositCancellations: above maxRequests"
        );
    }

    function processPendingRedeems(uint256 maxShares_, uint256 maxRequests_)
        public
        anyAction
        protocolAction
    {
        if (vault.paused()) {
            vm.prank(operator);
            vm.expectRevert(IFTMS.IsPaused.selector);
            vault.processPendingRedeems(maxShares_, maxRequests_);
            return;
        }

        ( maxShares_, maxRequests_ ) =
            _boundProcessing(Queue.REDEEM, vault.pendingRedeemShares(), maxShares_, maxRequests_);

        Fill memory fill_ = _fillSnapshot(Queue.REDEEM);

        vm.prank(operator);
        vault.processPendingRedeems(maxShares_, maxRequests_);

        uint256 paid_    = _assetsOwedOrPaid() - fill_.owedOrPaid;
        uint256 burned_  = fill_.pending - vault.pendingRedeemShares();
        uint256 entries_ = _checkOnlyRecipientsPaid(fill_);

        if (burned_ != 0 && paid_ == 0)                          zeroAssetRedeemFills++;
        if (entries_ > 1 && vault.pendingRedeemShares() != 0
            && vault.processedRedeemCount() > fill_.head)        multiEntryRedeemFills++;

        assertLe(burned_, maxShares_,          "processPendingRedeems: above maxShares");

        // With every request in reach, filling stops only once the queue is empty, `maxShares` is
        // used up, the remaining liquidity does not buy a single share, or after a partial fill
        // (which ends the call by design, though rounding can leave liquidity for a few more shares).
        if (maxRequests_ >= fill_.window.length) {
            assertTrue(
                vault.pendingRedeemShares() == 0 || burned_ == maxShares_ || !_liquidityBuysAShare() ||
                _endedOnPartialFill(fill_),
                "processPendingRedeems: stopped early"
            );
        }
        assertLe(vault.processedRedeemCount() - fill_.head, maxRequests_, "processPendingRedeems: above maxRequests");
        assertLe(paid_,   fill_.liquidity,     "processPendingRedeems: paid more than the liquidity");

        // Each entry is paid on its own, rounding down twice, so the payout falls short of paying
        // all burned shares at once by less than `RAY / price + 2` per entry.
        assertGe(
            paid_ + entries_ * (RAY / _price() + 2),
            vault.convertToAssets(burned_),
            "processPendingRedeems: paid too little"
        );
    }

    /**********************************************************************************************/
    /*** Fill checks                                                                            ***/
    /**********************************************************************************************/

    struct Fill {
        Queue           queue;
        uint256         head;
        IFTMS.Request[] window;
        uint256         pending;
        uint256         totalSupply;
        uint256         maxCapacity;
        uint256         liquidity;
        uint256         owedOrPaid;
        uint256[]       assets;     // per user: asset balance
        uint256[]       claimable;  // per user
        uint256[]       shares;     // per user
    }

    function _fillSnapshot(Queue queue_) internal view returns (Fill memory fill_) {
        fill_.queue = queue_;

        ( fill_.head, fill_.window ) = _pendingRequests(queue_);

        fill_.pending =
            queue_ == Queue.DEPOSIT              ? vault.pendingDepositAssets() :
            queue_ == Queue.DEPOSIT_CANCELLATION ? vault.pendingCancelledDepositAssets() :
                                                   vault.pendingRedeemShares();

        fill_.totalSupply = vault.totalSupply();
        fill_.maxCapacity = vault.maxCapacity();
        fill_.liquidity   = vault.availableLiquidAssets();
        fill_.owedOrPaid  = _assetsOwedOrPaid();
        fill_.assets      = new uint256[](users.length);
        fill_.claimable   = new uint256[](users.length);
        fill_.shares      = new uint256[](users.length);

        for (uint256 i = 0; i < users.length; i++) {
            fill_.assets[i]    = asset.balanceOf(users[i]);
            fill_.claimable[i] = vault.claimableAssetsOf(users[i]);
            fill_.shares[i]    = vault.balanceOf(users[i]);
        }
    }

    // Only the recipients of the entries a fill touched (those the head moved past, plus the new
    // head) receive assets, claimable assets or shares. Returns the number of entries touched.
    function _checkOnlyRecipientsPaid(Fill memory fill_) internal view returns (uint256 touched_) {
        ( uint256 head_, ) = _pendingRequests(fill_.queue);

        touched_ = _min(head_ - fill_.head + 1, fill_.window.length);

        for (uint256 i = 0; i < users.length; i++) {
            bool recipient_;

            for (uint256 j = 0; j < touched_; j++) {
                if (fill_.window[j].recipient == users[i]) recipient_ = true;
            }

            if (recipient_) continue;

            assertEq(asset.balanceOf(users[i]),         fill_.assets[i],    "fill paid a non-recipient");
            assertEq(vault.claimableAssetsOf(users[i]), fill_.claimable[i], "fill credited a non-recipient");
            assertEq(vault.balanceOf(users[i]),         fill_.shares[i],    "fill minted to a non-recipient");
        }
    }

    // The call partially filled the entry now at the head.
    function _endedOnPartialFill(Fill memory fill_) internal view returns (bool) {
        uint256 head_ = vault.processedRedeemCount();

        if (head_ - fill_.head >= fill_.window.length) return false;

        ( , , , uint256 amount_ ) = vault.getPendingRedeemRequest(head_);

        return amount_ != 0 && amount_ < fill_.window[head_ - fill_.head].amount;
    }

    /**********************************************************************************************/
    /*** Operator settings                                                                      ***/
    /**********************************************************************************************/

    // Often zero, just below or just above the supply, to reach the capacity edges.
    function setCapacity(uint256 capacity_, uint256 mode_) public anyAction protocolAction {
        uint256 supply_ = vault.totalSupply();
        uint256 max_    = type(uint128).max;

        mode_ = mode_ % 5;

        if      (mode_ == 0) capacity_ = 0;
        else if (mode_ == 1) capacity_ = _bound(capacity_, 0, supply_);
        else if (mode_ == 2) capacity_ = _min(supply_ + _bound(capacity_, 0, unit), max_);
        else if (mode_ == 3) capacity_ = _bound(capacity_, supply_, _min(supply_ + 1e30, max_));
        else                 capacity_ = max_;

        vm.prank(operator);
        vault.setCapacity(capacity_);

        if (capacity_ < supply_) capacityLoweredBelowSupply = true;
    }

    function setVSR(uint256 vsr_) public anyAction protocolAction {
        vsr_ = _bound(vsr_, vault.minVSR(), vault.maxVSR());

        vm.prank(operator);
        vault.setVSR(vsr_);
    }

    /**********************************************************************************************/
    /*** Taker                                                                                  ***/
    /**********************************************************************************************/

    // Often everything it can, including assets backing pending deposits and cancellations.
    function take(uint256 assets_) public anyAction protocolAction {
        uint256 available_ = vault.availableLiquidAssets();
        uint256 balance_   = asset.balanceOf(address(vault));

        // Sometimes try to take claimable assets too, which must revert.
        if (assets_ % 4 == 3 && balance_ > available_) {
            vm.prank(taker);
            vm.expectRevert(IFTMS.InsufficientAssets.selector);
            vault.take(_bound(assets_, available_ + 1, balance_));
            return;
        }

        // Sometimes leave just enough for the first pending redeem and part of the second, so that
        // the next fill runs out of liquidity partway through the queue.
        IFTMS.Request[] memory redeems_ = vault.pendingRedeemRequests();

        if (assets_ % 4 == 1 && redeems_.length >= 2) {
            uint256 target_ =
                vault.convertToAssets(redeems_[0].amount) +
                _bound(assets_, 0, vault.convertToAssets(redeems_[1].amount));

            if (available_ > target_) {
                vm.prank(taker);
                vault.take(available_ - target_);
                return;
            }
        }

        assets_ = assets_ % 2 == 0 ? available_ : _bound(assets_, 0, available_);

        uint256 takerBalance_ = asset.balanceOf(taker);

        vm.prank(taker);
        vault.take(assets_);

        assertEq(asset.balanceOf(taker),          takerBalance_ + assets_, "take: taker not paid");
        assertEq(asset.balanceOf(address(vault)), balance_      - assets_, "take: vault balance");
    }

    /**********************************************************************************************/
    /*** Admin and fee settings                                                                 ***/
    /**********************************************************************************************/

    function setVSRBounds(uint256 minVSR_, uint256 maxVSR_) public anyAction protocolAction {
        if (strict) return;  // VSR stays at 0%

        minVSR_ = _bound(minVSR_, RAY,     vault.MAX_VSR());
        maxVSR_ = _bound(maxVSR_, minVSR_, vault.MAX_VSR());

        vm.prank(admin);
        vault.setVSRBounds(minVSR_, maxVSR_);
    }

    function setMaxRedeemFeeRate(uint256 feeRate_) public anyAction protocolAction {
        feeRate_ = _bound(feeRate_, 0, vault.MAX_REDEEM_FEE());

        vm.prank(admin);
        vault.setMaxRedeemFeeRate(feeRate_);
    }

    function setRedeemFeeRate(uint256 feeRate_) public anyAction protocolAction {
        if (strict) return;  // Fees would hand the vault a surplus that hides rounding leaks

        // Often a round rate, so that `shares * feeRate` lands exactly on a multiple of 1e18 and
        // tests the fee's rounding up at its edge.
        uint256 max_ = vault.maxRedeemFeeRate();

        if      (feeRate_ % 4 == 0) feeRate_ = max_;
        else if (feeRate_ % 4 == 1) feeRate_ = _min(0.001e18, max_);
        else                        feeRate_ = _bound(feeRate_, 0, max_);

        vm.prank(redeemFeeSetter);
        vault.setRedeemFeeRate(feeRate_);
    }

    // The minimums are often 1, to reach 1-unit requests and their rounding.
    function setMinDeposit(uint256 minDeposit_) public anyAction protocolAction {
        minDeposit_ = minDeposit_ % 2 == 0 ? 1 : _bound(minDeposit_, 1, 1_000 * unit);

        vm.prank(admin);
        vault.setMinDeposit(minDeposit_);
    }

    function setMinDepositCancellation(uint256 minDepositCancellation_) public anyAction protocolAction {
        minDepositCancellation_ =
            minDepositCancellation_ % 2 == 0 ? 1 : _bound(minDepositCancellation_, 1, 1_000 * unit);

        vm.prank(admin);
        vault.setMinDepositCancellation(minDepositCancellation_);
    }

    function setMinRedeem(uint256 minRedeem_) public anyAction protocolAction {
        minRedeem_ = minRedeem_ % 2 == 0 ? 1 : _bound(minRedeem_, 1, 1_000 * unit);

        vm.prank(admin);
        vault.setMinRedeem(minRedeem_);
    }

    /**********************************************************************************************/
    /*** Pause and impairment                                                                   ***/
    /**********************************************************************************************/

    function pause(uint256 seed_) public anyAction protocolAction {
        if (seed_ % 4 != 0) return;  // Keep the vault unpaused most of the time

        vm.prank(pauser);
        vault.pause();
    }

    function unpause() public anyAction protocolAction {
        vm.prank(unpauser);
        vault.unpause();
    }

    // The only action that lowers chi. It can only lower the total reference value, so the surplus
    // can only grow.
    function impair(uint256 referenceValue_, bool unpause_) public anyAction {
        if (strict) return;  // Impairments would hand the vault a surplus that hides rounding leaks

        uint256 supply_ = vault.totalSupply();

        if (supply_ == 0) return;

        uint256 total_   = vault.totalReferenceValue();
        uint256 minLeft_ = (MIN_CHI * supply_ + RAY - 1) / RAY;

        if (total_ <= minLeft_) return;

        referenceValue_ = _bound(referenceValue_, 1, total_ - minLeft_);

        if (!vault.paused()) {
            vm.prank(pauser);
            vault.pause();
        }

        uint256 nowChi_  = vault.nowChi();
        int256  surplus_ = _surplus();

        vm.prank(lossManager);
        vault.impair(referenceValue_);

        impairments++;

        assertLe(vault.nowChi(), nowChi_,  "impair: chi increased");
        assertGe(_surplus(),     surplus_, "impair: surplus decreased");

        // The total reference value falls by at least the impairment: chi is the remaining value
        // per share, rounded down.
        assertEq(vault.chi(), ((total_ - referenceValue_) * RAY) / supply_, "impair: chi");
        assertLe(vault.totalReferenceValue(), total_ - referenceValue_,      "impair: total fell too little");

        // Usually resume right after, as an operator would.
        if (unpause_ || referenceValue_ % 4 != 0) {
            vm.prank(unpauser);
            vault.unpause();
        }
    }

    /**********************************************************************************************/
    /*** Upgrade                                                                                ***/
    /**********************************************************************************************/

    // Upgrades to a fresh implementation in any state. Nothing stored may change and the proxy
    // stays initialized. Point `new FTMS()` at a new version to check its storage layout against
    // live state.
    function upgrade() public anyAction protocolAction {
        bytes32 before_ = _stateDigest();

        address implementation_ = address(new FTMS());

        vm.prank(admin);
        vault.upgradeToAndCall(implementation_, "");

        upgrades++;

        assertEq(vault.implementation(), implementation_, "upgrade: implementation");
        assertEq(_stateDigest(),         before_,         "upgrade: state changed");

        vm.expectRevert(bytes4(keccak256("InvalidInitialization()")));
        vault.initialize(token, address(oracle), false, "X", "X", address(this), 1, 1, 1);

        // Nor can the implementation itself.
        vm.expectRevert(bytes4(keccak256("InvalidInitialization()")));
        FTMS(implementation_).initialize(token, address(oracle), false, "X", "X", address(this), 1, 1, 1);
    }

    function _stateDigest() internal view returns (bytes32 digest_) {
        digest_ = keccak256(abi.encode(
            vault.asset(), vault.referenceOracle(), vault.paused(), vault.instantFill(), vault.decimals(),
            vault.name(), vault.symbol(), vault.DOMAIN_SEPARATOR(),
            vault.rho(), vault.chi(), vault.vsr(), vault.minVSR(), vault.maxVSR()
        ));

        digest_ = keccak256(abi.encode(
            digest_,
            vault.maxCapacity(), vault.minDeposit(), vault.minDepositCancellation(), vault.minRedeem(),
            vault.redeemFeeRate(), vault.maxRedeemFeeRate(), vault.totalSupply(), vault.totalClaimable()
        ));

        digest_ = keccak256(abi.encode(
            digest_,
            vault.pendingDepositAssets(), vault.pendingCancelledDepositAssets(), vault.pendingRedeemShares(),
            vault.processedDepositCount(), vault.processedDepositCancellationCount(), vault.processedRedeemCount(),
            vault.pendingDepositRequestsLength(), vault.pendingDepositCancellationRequestsLength(),
            vault.pendingRedeemRequestsLength()
        ));

        digest_ = keccak256(abi.encode(
            digest_,
            vault.pendingDepositRequests(), vault.pendingDepositCancellationRequests(), vault.pendingRedeemRequests()
        ));

        address[7] memory roleHolders_ = [admin, lossManager, operator, pauser, redeemFeeSetter, taker, unpauser];
        bytes32[7] memory roles_ = [
            vault.DEFAULT_ADMIN_ROLE(), vault.LOSS_MANAGER_ROLE(), vault.OPERATOR_ROLE(), vault.PAUSER_ROLE(),
            vault.REDEEM_FEE_SETTER_ROLE(), vault.TAKER_ROLE(), vault.UNPAUSER_ROLE()
        ];

        for (uint256 i = 0; i < roles_.length; i++) {
            digest_ = keccak256(abi.encode(
                digest_, vault.hasRole(roles_[i], roleHolders_[i]), vault.getRoleMemberCount(roles_[i])
            ));
        }

        for (uint256 i = 0; i < users.length; i++) {
            address user_ = users[i];

            digest_ = keccak256(abi.encode(
                digest_, vault.balanceOf(user_), vault.claimableAssetsOf(user_), vault.nonces(user_),
                vault.allowance(user_, users[(i + 1) % users.length])
            ));
        }
    }

    /**********************************************************************************************/
    /*** Internal Helpers                                                                       ***/
    /**********************************************************************************************/

    // Grows by every asset paid out by the vault or credited as claimable.
    function _assetsOwedOrPaid() internal view returns (uint256) {
        return type(uint192).max - asset.balanceOf(address(vault)) + vault.totalClaimable();
    }

    // One call in four is unbounded on each axis, the rest stay around the queue size.
    function _boundProcessing(Queue queue_, uint256 pending_, uint256 maxAmount_, uint256 maxRequests_)
        internal view returns (uint256, uint256)
    {
        ( , IFTMS.Request[] memory requests_ ) = _pendingRequests(queue_);

        maxAmount_   = maxAmount_   % 4 == 0 ? type(uint256).max : _bound(maxAmount_,   0, pending_ + 1);
        maxRequests_ = maxRequests_ % 4 == 0 ? type(uint256).max : _bound(maxRequests_, 0, requests_.length + 1);

        return ( maxAmount_, maxRequests_ );
    }

}
