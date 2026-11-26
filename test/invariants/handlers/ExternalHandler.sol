// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { HandlerBase, Setup } from "./HandlerBase.sol";

interface IStUsdsLike {
    function cut(uint256 rad) external;
    function totalAssets() external view returns (uint256);
}

// Everything outside the vault's own interface: time, the oracle price, the asset's blocklist,
// donations, and the taker returning, gaining or losing assets.
contract ExternalHandler is HandlerBase {

    // Caps cumulative warping so deep campaigns cannot push chi towards overflow.
    uint256 public constant MAX_TOTAL_WARP = 20 * 365 days;

    // The oracle price stays within 1000x of its initial value either way.
    uint256 public constant MIN_PRICE = RAY / 1_000;
    uint256 public constant MAX_PRICE = RAY * 1_000;

    uint256 public totalWarped;

    // Reachability counters.
    uint256 public priceDrops;
    uint256 public priceRises;
    uint256 public oracleLosses;

    constructor(Setup memory setup_, uint256 numUsers_) HandlerBase(setup_, numUsers_) {}

    /**********************************************************************************************/
    /*** Time                                                                                   ***/
    /**********************************************************************************************/

    function warp(uint256 secs_) public anyAction {
        uint256 nowChi_ = vault.nowChi();

        secs_ = _bound(secs_, 0, _min(10 days, MAX_TOTAL_WARP - totalWarped));

        totalWarped += secs_;

        vm.warp(block.timestamp + secs_);

        assertGe(vault.nowChi(), nowChi_, "warp: nowChi decreased");
    }

    function drip() public anyAction protocolAction {
        vault.drip();
    }

    /**********************************************************************************************/
    /*** Oracle                                                                                 ***/
    /**********************************************************************************************/

    // Small steps and large jumps. In strict mode the price can only rise.
    function setPrice(uint256 price_, uint256 mode_) public anyAction {
        if (address(mockOracle) == address(0)) return;  // Real oracles move with time only

        uint256 current_ = mockOracle.price();

        if (mode_ % 3 == 0) {
            // Within 0.1% of the current price.
            price_ = _bound(price_, current_ - current_ / 1_000, current_ + current_ / 1_000);
        } else {
            price_ = _bound(price_, MIN_PRICE, MAX_PRICE);
        }

        // Clamp, as `_bound` wraps out-of-range values around.
        if (price_ < MIN_PRICE) price_ = MIN_PRICE;
        if (price_ > MAX_PRICE) price_ = MAX_PRICE;

        if (strict && price_ < current_) price_ = _min(current_ + (current_ - price_), MAX_PRICE);

        if (price_ < current_) priceDrops++;
        if (price_ > current_) priceRises++;

        int256 surplus_ = _surplus();

        mockOracle.setPrice(price_);

        // A rising price can only grow the surplus while the vault's net assets are positive,
        // which strict mode keeps them.
        if (strict) assertGe(_surplus(), surplus_, "setPrice: surplus decreased");
    }

    // A real loss on stUSDS: `cut` lowers its chi, so its price falls. At most 10% of its assets
    // per call, and never below half its initial price.
    function oracleLoss(uint256 assets_) public anyAction {
        if (lossOracle == address(0) || strict) return;

        uint256 price_ = _price();

        if (price_ < RAY / 2) return;

        uint256 total_ = IStUsdsLike(lossOracle).totalAssets();

        assets_ = _bound(assets_, 1, total_ / 10);

        vm.prank(lossCaller);
        IStUsdsLike(lossOracle).cut(assets_ * RAY);

        assertLe(_price(), price_, "oracleLoss: price rose");

        if (_price() < price_) oracleLosses++;
    }

    /**********************************************************************************************/
    /*** Asset                                                                                  ***/
    /**********************************************************************************************/

    // Payouts to a blocked recipient are credited as claimable instead of reverting.
    function setBlocked(uint256 userSeed_, bool blocked_) public anyAction protocolAction {
        asset.setBlocked(_randomUser(userSeed_), blocked_);
    }

    // Strict mode never hands the vault assets, so its solvency checks catch any rounding leak.
    function donate(uint256 assets_) public anyAction protocolAction {
        if (strict) return;

        asset.mint(address(vault), _bound(assets_, 0, maxAmount));
    }

    /**********************************************************************************************/
    /*** Taker                                                                                  ***/
    /**********************************************************************************************/

    function returnTaken(uint256 assets_) public anyAction protocolAction {
        assets_ = _bound(assets_, 0, asset.balanceOf(taker));

        // Mock transfer, so the call does not depend on whether `transfer` returns a value.
        asset.burn(taker, assets_);
        asset.mint(address(vault), assets_);
    }

    function takerGain(uint256 assets_) public anyAction protocolAction {
        if (strict) return;

        asset.mint(taker, _bound(assets_, 0, maxAmount));
    }

    // Losses on deployed capital. Strict mode models a vault that never gains or loses value.
    function takerLoss(uint256 assets_) public anyAction {
        if (strict) return;

        asset.burn(taker, _bound(assets_, 0, asset.balanceOf(taker)));
    }

}
