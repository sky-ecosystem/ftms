// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../../../lib/forge-std/src/Test.sol";

import { IFTMS } from "../../../src/IFTMS.sol";
import { FTMS }  from "../../../src/FTMS.sol";

import { MockReferenceOracle } from "../mocks/MockReferenceOracle.sol";

// The vault's asset, as the handlers drive it: a mock token, or a real token on a mainnet fork.
interface IAssetHarness {
    function token() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function blocked(address account) external view returns (bool);
    function mint(address account, uint256 amount) external;
    function burn(address account, uint256 amount) external;
    function setBlocked(address account, bool blocked) external;
}

interface IReferenceOracleLike {
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
}

// The addresses and settings every handler shares.
struct Setup {
    FTMS                 vault;
    IAssetHarness        asset;
    IReferenceOracleLike oracle;      // address(0) if the vault has no reference oracle
    MockReferenceOracle  mockOracle;  // the oracle if it is a mock, whose price can be set
    address              lossOracle;  // the oracle if it is stUSDS, whose price falls with `cut`
    address              lossCaller;  // stUSDS's clipper, allowed to `cut`
    bool                strict;     // VSR fixed at 0% and the oracle price can only rise
    uint256             maxAmount;  // Per action [asset units]
    address             admin;
    address             lossManager;
    address             operator;
    address             pauser;
    address             redeemFeeSetter;
    address             taker;
    address             unpauser;
}

contract HandlerBase is Test {

    enum Queue { DEPOSIT, DEPOSIT_CANCELLATION, REDEEM }

    uint256 public constant RAY = 1e27;

    uint256 public maxAmount;  // Per action [asset units]
    uint256 public unit;       // One whole asset [asset units]

    FTMS                 internal vault;
    IAssetHarness        internal asset;
    address              internal token;
    IReferenceOracleLike internal oracle;
    MockReferenceOracle  internal mockOracle;
    address              internal lossOracle;
    address              internal lossCaller;

    bool public strict;

    address public admin;
    address public lossManager;
    address public operator;
    address public pauser;
    address public redeemFeeSetter;
    address public taker;
    address public unpauser;

    // Every owner and recipient is drawn from this set, so every balance the invariants sum over
    // belongs to a tracked address. `makeAddr` is deterministic, so every handler sees the same set.
    address[] public users;

    /**********************************************************************************************/
    /*** Checks around every action                                                             ***/
    /**********************************************************************************************/

    struct Snapshot {
        uint256   depositCount;
        uint256   cancellationCount;
        uint256   redeemCount;
        uint256[] claimable;
        bool[]    blocked;
        uint256   nowChi;
        int256    surplus;
    }

    // Checks that hold around every call into the vault, whoever makes it.
    modifier anyAction() {
        Snapshot memory before_ = _snapshot();
        _;
        _checkAnyAction(before_);
    }

    // Checks around every action except time passing, oracle price moves, impairments and the
    // taker's gains or losses: the reference value per share never falls and the vault's surplus
    // (see `_surplus`) never shrinks, i.e. every action rounds in the vault's favour.
    modifier protocolAction() {
        Snapshot memory before_ = _snapshot();
        _;
        _checkProtocolAction(before_);
    }

    constructor(Setup memory setup_, uint256 numUsers_) {
        vault      = setup_.vault;
        asset      = setup_.asset;
        token      = setup_.asset.token();
        oracle     = setup_.oracle;
        mockOracle = setup_.mockOracle;
        lossOracle = setup_.lossOracle;
        lossCaller = setup_.lossCaller;
        strict     = setup_.strict;

        maxAmount = setup_.maxAmount;
        unit      = 10 ** setup_.asset.decimals();

        admin           = setup_.admin;
        lossManager     = setup_.lossManager;
        operator        = setup_.operator;
        pauser          = setup_.pauser;
        redeemFeeSetter = setup_.redeemFeeSetter;
        taker           = setup_.taker;
        unpauser        = setup_.unpauser;

        for (uint256 i = 0; i < numUsers_; i++) {
            users.push(makeAddr(string(abi.encodePacked("user", vm.toString(i)))));
        }
    }

    function numUsers() external view returns (uint256) {
        return users.length;
    }

    function surplus() external view returns (int256) {
        return _surplus();
    }

    /**********************************************************************************************/
    /*** Internal Helpers                                                                       ***/
    /**********************************************************************************************/

    function _snapshot() internal view returns (Snapshot memory snapshot_) {
        snapshot_.depositCount      = vault.processedDepositCount();
        snapshot_.cancellationCount = vault.processedDepositCancellationCount();
        snapshot_.redeemCount       = vault.processedRedeemCount();
        snapshot_.claimable         = new uint256[](users.length);
        snapshot_.blocked           = new bool[](users.length);
        snapshot_.nowChi            = vault.nowChi();
        snapshot_.surplus           = _surplus();

        for (uint256 i = 0; i < users.length; i++) {
            snapshot_.claimable[i] = vault.claimableAssetsOf(users[i]);
            snapshot_.blocked[i]   = asset.blocked(users[i]);
        }
    }

    function _checkAnyAction(Snapshot memory before_) internal view {
        assertGe(vault.processedDepositCount(),             before_.depositCount,      "deposit head moved back");
        assertGe(vault.processedDepositCancellationCount(), before_.cancellationCount, "cancellation head moved back");
        assertGe(vault.processedRedeemCount(),              before_.redeemCount,       "redeem head moved back");

        // A payout is only credited as claimable when its transfer fails, which the mock asset
        // only does for blocked recipients.
        for (uint256 i = 0; i < users.length; i++) {
            if (before_.blocked[i]) continue;

            assertLe(
                vault.claimableAssetsOf(users[i]),
                before_.claimable[i],
                "claimable credited to unblocked recipient"
            );
        }
    }

    function _checkProtocolAction(Snapshot memory before_) internal view {
        assertGe(vault.nowChi(), before_.nowChi,  "nowChi decreased");
        assertGe(_surplus(),     before_.surplus, "surplus decreased");
    }

    // The vault's net asset position valued at the oracle price, minus the reference value of all
    // shares, exactly, scaled by RAY:
    //   (assets held by the vault and the taker - pending deposits - pending cancellations
    //    - claimable) * price - totalSupply * nowChi
    function _surplus() internal view returns (int256) {
        int256 netAssets_ =
            int256(asset.balanceOf(address(vault)) + asset.balanceOf(taker)) -
            int256(vault.pendingDepositAssets() + vault.pendingCancelledDepositAssets() + vault.totalClaimable());

        return netAssets_ * int256(_price()) - int256(vault.totalSupply() * vault.nowChi());
    }

    // The reference value of one asset unit [ray]. Exact for the mock and for chi-based ERC-4626
    // vaults, whose `convertToAssets(x)` is `x * chi / RAY`.
    function _price() internal view returns (uint256) {
        return address(oracle) == address(0) ? RAY : oracle.convertToAssets(RAY);
    }

    function _assetsToReferenceValue(uint256 assets_) internal view returns (uint256) {
        return address(oracle) == address(0) ? assets_ : oracle.convertToAssets(assets_);
    }

    function _referenceValueToAssets(uint256 referenceValue_) internal view returns (uint256) {
        return address(oracle) == address(0) ? referenceValue_ : oracle.convertToShares(referenceValue_);
    }

    // The available capacity in assets, worked out independently of the vault's conversions.
    function _capacityAssets() internal view returns (uint256) {
        return _referenceValueToAssets(vault.availableCapacity() * vault.nowChi() / RAY);
    }

    // Whether the vault's liquidity buys at least one share, worked out independently.
    function _liquidityBuysAShare() internal view returns (bool) {
        return _assetsToReferenceValue(vault.availableLiquidAssets()) * RAY / vault.nowChi() != 0;
    }

    function _pendingRequests(Queue queue_)
        internal view returns (uint256 head_, IFTMS.Request[] memory requests_)
    {
        if (queue_ == Queue.DEPOSIT) {
            return ( vault.processedDepositCount(), vault.pendingDepositRequests() );
        }

        if (queue_ == Queue.DEPOSIT_CANCELLATION) {
            return ( vault.processedDepositCancellationCount(), vault.pendingDepositCancellationRequests() );
        }

        return ( vault.processedRedeemCount(), vault.pendingRedeemRequests() );
    }

    // A random request with a nonzero amount in the pending window of a queue, or `found_ == false`.
    function _randomOpenRequest(Queue queue_, uint256 seed_)
        internal view returns (bool found_, uint256 requestId_, IFTMS.Request memory request_)
    {
        ( uint256 head_, IFTMS.Request[] memory requests_ ) = _pendingRequests(queue_);

        if (requests_.length == 0) return ( false, 0, request_ );

        uint256 start_ = _bound(seed_, 0, requests_.length - 1);

        for (uint256 i = 0; i < requests_.length; i++) {
            uint256 index_ = (start_ + i) % requests_.length;

            if (requests_[index_].amount != 0) {
                return ( true, head_ + index_, requests_[index_] );
            }
        }
    }

    function _randomUser(uint256 seed_) internal view returns (address) {
        return users[_bound(seed_, 0, users.length - 1)];
    }

    function _min(uint256 a_, uint256 b_) internal pure returns (uint256) {
        return a_ < b_ ? a_ : b_;
    }

    function _max(uint256 a_, uint256 b_) internal pure returns (uint256) {
        return a_ > b_ ? a_ : b_;
    }

}
