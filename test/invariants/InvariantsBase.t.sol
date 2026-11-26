// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../../lib/forge-std/src/Test.sol";

import { ERC1967Proxy } from "../../lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { IFTMS } from "../../src/IFTMS.sol";
import { FTMS }  from "../../src/FTMS.sol";

import { Ethereum } from "../../lib/spark-address-registry/src/Ethereum.sol";

import { ExternalHandler } from "./handlers/ExternalHandler.sol";
import { HandlerBase, IAssetHarness, IReferenceOracleLike, Setup } from "./handlers/HandlerBase.sol";
import { OperatorHandler } from "./handlers/OperatorHandler.sol";
import { UserHandler }     from "./handlers/UserHandler.sol";

import { ForkAsset }           from "./mocks/ForkAsset.sol";
import { MockAsset }           from "./mocks/MockAsset.sol";
import { MockReferenceOracle } from "./mocks/MockReferenceOracle.sol";

// Runs either on a mainnet fork with real tokens and oracles, or on local mocks, whose price can
// jump either way and whose blocklist blocks recipients as well as senders.
abstract contract InvariantsBase is Test {

    // The block the unit tests fork from.
    uint256 internal constant FORK_BLOCK = 26148600;

    address internal constant STUSDS      = 0x99CD4Ec3f88A45940936F469E4bB72A2A701EEB9;
    address internal constant STUSDS_CLIP = 0x836F56750517b1528B5078Cba4Ac4B94fBE4A399;

    uint256 internal constant RAY = 1e27;

    uint256 internal constant NUM_USERS = 6;

    uint256 internal constant FIVE_PCT_VSR = 1.000000001547125957863212448e27;

    bytes32 internal constant LOSS_MANAGER_ROLE      = keccak256("LOSS_MANAGER_ROLE");
    bytes32 internal constant OPERATOR_ROLE          = keccak256("OPERATOR_ROLE");
    bytes32 internal constant PAUSER_ROLE            = keccak256("PAUSER_ROLE");
    bytes32 internal constant REDEEM_FEE_SETTER_ROLE = keccak256("REDEEM_FEE_SETTER_ROLE");
    bytes32 internal constant TAKER_ROLE             = keccak256("TAKER_ROLE");
    bytes32 internal constant UNPAUSER_ROLE          = keccak256("UNPAUSER_ROLE");

    address internal admin           = makeAddr("admin");
    address internal lossManager     = makeAddr("lossManager");
    address internal operator        = makeAddr("operator");
    address internal pauser          = makeAddr("pauser");
    address internal redeemFeeSetter = makeAddr("redeemFeeSetter");
    address internal taker           = makeAddr("taker");
    address internal unpauser        = makeAddr("unpauser");

    FTMS                 internal vault;
    IAssetHarness        internal asset;
    IReferenceOracleLike internal oracle;
    MockReferenceOracle  internal mockOracle;

    ExternalHandler internal externalHandler;
    OperatorHandler internal operatorHandler;
    UserHandler     internal userHandler;

    /**********************************************************************************************/
    /*** Configuration                                                                          ***/
    /**********************************************************************************************/

    function _instantFill() internal pure virtual returns (bool);

    // Mainnet fork: the real asset, `address(0)` to run on mocks instead.
    function _forkAsset() internal pure virtual returns (address) {
        return address(0);
    }

    // Mainnet fork: the real reference oracle, or `address(0)` for none.
    function _forkOracle() internal pure virtual returns (address) {
        return address(0);
    }

    // Mocks: whether the vault has a (mock) reference oracle.
    function _hasOracle() internal pure virtual returns (bool) {
        return false;
    }

    // The asset's `transfer` returns no value, like USDT.
    function _noReturn() internal pure virtual returns (bool) {
        return false;
    }

    function _decimals() internal pure virtual returns (uint8) {
        return 6;
    }

    // The most a single action deposits, donates or gains.
    function _maxAmount() internal view virtual returns (uint256) {
        return 1_000_000_000 * 10 ** asset.decimals();
    }

    // VSR fixed at 0% and an oracle price that can only rise, so the vault can never be short.
    function _strict() internal pure virtual returns (bool) {
        return false;
    }

    /**********************************************************************************************/
    /*** Setup                                                                                  ***/
    /**********************************************************************************************/

    function setUp() public virtual {
        if (_forkAsset() != address(0)) {
            vm.createSelectFork(getChain("mainnet").rpcUrl, FORK_BLOCK);

            ForkAsset.Blocklist blocklist_ =
                _forkAsset() == Ethereum.USDC ? ForkAsset.Blocklist.USDC :
                _forkAsset() == Ethereum.USDT ? ForkAsset.Blocklist.USDT :
                                                ForkAsset.Blocklist.NONE;

            asset  = new ForkAsset(_forkAsset(), blocklist_);
            oracle = IReferenceOracleLike(_forkOracle());
        } else {
            asset = new MockAsset(_noReturn(), _decimals());

            if (_hasOracle()) {
                mockOracle = new MockReferenceOracle();
                oracle     = IReferenceOracleLike(address(mockOracle));
            }
        }

        vault = FTMS(
            address(new ERC1967Proxy(
                address(new FTMS()),
                abi.encodeCall(
                    IFTMS.initialize,
                    (asset.token(), address(oracle), _instantFill(), "FTMS", "FTMS", admin, 1, 1, 1)
                )
            ))
        );

        vm.startPrank(admin);

        vault.grantRole(LOSS_MANAGER_ROLE,      lossManager);
        vault.grantRole(OPERATOR_ROLE,          operator);
        vault.grantRole(PAUSER_ROLE,            pauser);
        vault.grantRole(REDEEM_FEE_SETTER_ROLE, redeemFeeSetter);
        vault.grantRole(TAKER_ROLE,             taker);
        vault.grantRole(UNPAUSER_ROLE,          unpauser);

        vault.setMaxRedeemFeeRate(vault.MAX_REDEEM_FEE());

        if (!_strict()) vault.setVSRBounds(RAY, vault.MAX_VSR());

        vm.stopPrank();

        vm.startPrank(operator);
        vault.setCapacity(1_000_000_000 * 10 ** asset.decimals());
        if (!_strict()) vault.setVSR(FIVE_PCT_VSR);
        vm.stopPrank();

        Setup memory setup_ = Setup({
            vault           : vault,
            asset           : asset,
            oracle          : oracle,
            mockOracle      : mockOracle,
            lossOracle      : _forkOracle() == STUSDS ? STUSDS      : address(0),
            lossCaller      : _forkOracle() == STUSDS ? STUSDS_CLIP : address(0),
            strict          : _strict(),
            maxAmount       : _maxAmount(),
            admin           : admin,
            lossManager     : lossManager,
            operator        : operator,
            pauser          : pauser,
            redeemFeeSetter : redeemFeeSetter,
            taker           : taker,
            unpauser        : unpauser
        });

        userHandler     = new UserHandler(setup_, NUM_USERS);
        operatorHandler = new OperatorHandler(setup_, NUM_USERS);
        externalHandler = new ExternalHandler(setup_, NUM_USERS);

        vm.label(address(vault),           "vault");
        vm.label(asset.token(),            "asset");
        vm.label(address(asset),           "assetHarness");
        vm.label(address(oracle),          "oracle");
        vm.label(address(userHandler),     "userHandler");
        vm.label(address(operatorHandler), "operatorHandler");
        vm.label(address(externalHandler), "externalHandler");

        // Foundry fuzzes every non-view function of these contracts.
        targetContract(address(userHandler));
        targetContract(address(operatorHandler));
        targetContract(address(externalHandler));

        // The handlers prank every call into the vault, so the fuzzer's sender does not matter.
        // A fixed one spares a fork an RPC lookup for every new random address.
        targetSender(makeAddr("fuzzer"));
    }

    /**********************************************************************************************/
    /*** Invariants                                                                             ***/
    /**********************************************************************************************/

    function invariant_vault() public {
        _assertSharesAccounting();
        _assertQueues();
        _assertClaimables();
        _assertCapacity();
        _assertChi();
        _assertDrip();
        _assertConfigBounds();
        _assertRoles();
        _assertViews();
        _assertSolvency();
    }

    // Every share is held by a user or escrowed by the vault for a pending redeem.
    function _assertSharesAccounting() internal view {
        uint256 sum_ = vault.balanceOf(address(vault));

        for (uint256 i = 0; i < NUM_USERS; i++) {
            sum_ += vault.balanceOf(userHandler.users(i));
        }

        assertEq(sum_,                             vault.totalSupply(),         "sum(balances) + escrow != totalSupply");
        assertEq(vault.balanceOf(address(vault)), vault.pendingRedeemShares(), "escrow != pendingRedeemShares");
    }

    // Each pending counter is the sum of its queue's pending window (so no unfilled request was
    // skipped by moving the head), every entry keeps its owner and latest recipient, and every
    // entry's amount is untouched except the first pending one's (FIFO).
    function _assertQueues() internal view {
        _assertQueue(HandlerBase.Queue.DEPOSIT,              vault.processedDepositCount(),             vault.pendingDepositRequests(),             vault.pendingDepositAssets());
        _assertQueue(HandlerBase.Queue.DEPOSIT_CANCELLATION, vault.processedDepositCancellationCount(), vault.pendingDepositCancellationRequests(), vault.pendingCancelledDepositAssets());
        _assertQueue(HandlerBase.Queue.REDEEM,               vault.processedRedeemCount(),              vault.pendingRedeemRequests(),              vault.pendingRedeemShares());
    }

    function _assertQueue(HandlerBase.Queue queue_, uint256 head_, IFTMS.Request[] memory requests_, uint256 pending_)
        internal view
    {
        UserHandler.GhostEntry[] memory ghosts_ = userHandler.ghosts(queue_);

        string memory name_ = queue_ == HandlerBase.Queue.DEPOSIT ? "deposit" : queue_ == HandlerBase.Queue.REDEEM ? "redeem" : "cancellation";

        assertEq(head_ + requests_.length, ghosts_.length, string.concat(name_, ": queue length"));

        uint256 sum_;

        for (uint256 i = 0; i < requests_.length; i++) {
            IFTMS.Request          memory request_ = requests_[i];
            UserHandler.GhostEntry memory ghost_   = ghosts_[head_ + i];

            sum_ += request_.amount;

            if (i == 0) {
                assertLe(request_.amount, ghost_.amount, string.concat(name_, ": head above request"));
            } else {
                assertEq(request_.amount, ghost_.amount, string.concat(name_, ": filled out of order"));
            }

            // Fully cancelled deposit entries are deleted.
            if (request_.amount == 0) continue;

            assertEq(request_.owner,     ghost_.owner,     string.concat(name_, ": owner"));
            assertEq(request_.recipient, ghost_.recipient, string.concat(name_, ": recipient"));
        }

        assertEq(sum_, pending_, string.concat(name_, ": pending != sum(queue)"));
    }

    // Claimable assets are held by the vault, so `take` cannot reach them.
    function _assertClaimables() internal view {
        uint256 sum_;

        for (uint256 i = 0; i < NUM_USERS; i++) {
            sum_ += vault.claimableAssetsOf(userHandler.users(i));
        }

        assertEq(sum_, vault.totalClaimable(),                                "sum(claimable) != totalClaimable");
        assertGe(asset.balanceOf(address(vault)), vault.totalClaimable(),     "vault holds less than claimable");
        assertEq(vault.availableLiquidAssets(), asset.balanceOf(address(vault)) - vault.totalClaimable(), "availableLiquidAssets");
    }

    function _assertCapacity() internal view {
        uint256 capacity_ = vault.maxCapacity();
        uint256 supply_   = vault.totalSupply();

        assertEq(vault.availableCapacity(), capacity_ > supply_ ? capacity_ - supply_ : 0, "availableCapacity");

        if (!operatorHandler.capacityLoweredBelowSupply()) {
            assertLe(supply_, capacity_, "totalSupply above maxCapacity");
        }
    }

    function _assertChi() internal view {
        assertGt(uint256(vault.chi()), 0,                     "chi is zero");
        assertLe(vault.rho(),          block.timestamp,       "rho in the future");
        assertGe(vault.nowChi(),       uint256(vault.chi()),  "nowChi < chi");
        assertGe(vault.vsr(),          RAY,                   "vsr below 0%");
    }

    // Dripping brings chi up to `nowChi` and `rho` up to now. Reverted afterwards, so the campaign
    // keeps exercising stale chi.
    function _assertDrip() internal {
        uint256 snapshot_ = vm.snapshotState();
        uint256 nowChi_   = vault.nowChi();

        assertEq(uint256(vault.drip()), nowChi_,         "drip: return != nowChi");
        assertEq(uint256(vault.chi()),  nowChi_,         "drip: chi != nowChi");
        assertEq(vault.rho(),           block.timestamp, "drip: rho not updated");
        assertEq(vault.nowChi(),        nowChi_,         "drip: nowChi changed");

        vm.revertToState(snapshot_);
    }

    // Lowering a bound does not clamp the live value (`vsr`, `redeemFeeRate`), so only the
    // constant caps hold for those.
    function _assertConfigBounds() internal view {
        assertGe(vault.minVSR(), RAY,              "config: minVSR < RAY");
        assertLe(vault.maxVSR(), vault.MAX_VSR(),  "config: maxVSR > MAX_VSR");
        assertLe(vault.minVSR(), vault.maxVSR(),   "config: minVSR > maxVSR");
        assertLe(vault.vsr(),    vault.MAX_VSR(),  "config: vsr > MAX_VSR");

        assertLe(vault.redeemFeeRate(),    vault.MAX_REDEEM_FEE(), "config: redeemFeeRate > MAX_REDEEM_FEE");
        assertLe(vault.maxRedeemFeeRate(), vault.MAX_REDEEM_FEE(), "config: maxRedeemFeeRate > MAX_REDEEM_FEE");

        assertGt(vault.minDeposit(),             0, "config: minDeposit zero");
        assertGt(vault.minDepositCancellation(), 0, "config: minDepositCancellation zero");
        assertGt(vault.minRedeem(),              0, "config: minRedeem zero");

        assertLe(vault.maxCapacity(), type(uint128).max, "config: maxCapacity > uint128");
    }

    // Nothing in the campaign grants or revokes roles, so each role keeps exactly its one holder.
    function _assertRoles() internal view {
        address[7] memory holders_ = [admin, lossManager, operator, pauser, redeemFeeSetter, taker, unpauser];
        bytes32[7] memory roles_   = [
            vault.DEFAULT_ADMIN_ROLE(), LOSS_MANAGER_ROLE, OPERATOR_ROLE, PAUSER_ROLE,
            REDEEM_FEE_SETTER_ROLE, TAKER_ROLE, UNPAUSER_ROLE
        ];

        for (uint256 i = 0; i < roles_.length; i++) {
            assertTrue(vault.hasRole(roles_[i], holders_[i]),       "roles: holder lost its role");
            assertEq(vault.getRoleMemberCount(roles_[i]), 1,        "roles: unexpected role member count");
            assertEq(vault.getRoleMember(roles_[i], 0), holders_[i], "roles: unexpected role member");
        }
    }

    // The read-only functions the handlers do not use agree with the state they summarise.
    function _assertViews() internal view {
        _assertQueueViews(HandlerBase.Queue.DEPOSIT);
        _assertQueueViews(HandlerBase.Queue.DEPOSIT_CANCELLATION);
        _assertQueueViews(HandlerBase.Queue.REDEEM);

        uint256 nowChi_ = vault.nowChi();
        uint256 supply_ = vault.totalSupply();

        assertEq(vault.totalReferenceValue(), supply_ * nowChi_ / RAY,                    "views: totalReferenceValue");
        assertEq(vault.totalAssets(),         _toAssets(supply_ * nowChi_ / RAY),         "views: totalAssets");
        assertEq(vault.availableLiquidReferenceValue(), _toReference(vault.availableLiquidAssets()), "views: availableLiquidReferenceValue");

        for (uint256 i = 0; i < NUM_USERS; i++) {
            address user_    = userHandler.users(i);
            uint256 balance_ = vault.balanceOf(user_);

            assertEq(vault.referenceValueOf(user_), balance_ * nowChi_ / RAY,            "views: referenceValueOf");
            assertEq(vault.assetsOf(user_),         _toAssets(balance_ * nowChi_ / RAY), "views: assetsOf");

            assertEq(vault.convertSharesToReferenceValue(balance_), balance_ * nowChi_ / RAY, "views: convertSharesToReferenceValue");
            assertEq(vault.convertReferenceValueToShares(balance_), balance_ * RAY / nowChi_, "views: convertReferenceValueToShares");
            assertEq(vault.convertToAssets(balance_), _toAssets(balance_ * nowChi_ / RAY),   "views: convertToAssets");
            assertEq(vault.convertToShares(balance_), _toReference(balance_) * RAY / nowChi_, "views: convertToShares");
        }
    }

    function _assertQueueViews(HandlerBase.Queue queue_) internal view {
        ( uint256 head_, uint256 length_, IFTMS.Request[] memory window_ ) = _queueViews(queue_);

        assertEq(length_, window_.length, "views: pending length");

        uint256 total_ = head_ + window_.length;

        for (uint256 i = 0; i < window_.length; i++) {
            IFTMS.Request memory request_ = _getRequest(queue_, head_ + i);

            assertEq(request_.owner,     window_[i].owner,     "views: request owner");
            assertEq(request_.recipient, window_[i].recipient, "views: request recipient");
            assertEq(request_.timestamp, window_[i].timestamp, "views: request timestamp");
            assertEq(request_.amount,    window_[i].amount,    "views: request amount");
        }

        // Pages from every start, with lengths that end inside, at, and past the end of the queue.
        for (uint256 start_ = head_; start_ <= total_; start_++) {
            for (uint256 n_ = 0; n_ <= total_ - start_ + 1; n_ += 1 + (total_ - start_) / 3) {
                IFTMS.Request[] memory page_ = _getRequests(queue_, start_, n_);

                uint256 expected_ = n_ < total_ - start_ ? n_ : total_ - start_;

                assertEq(page_.length, expected_, "views: page length");

                for (uint256 j = 0; j < page_.length; j++) {
                    assertEq(page_[j].owner,     window_[start_ - head_ + j].owner,     "views: page owner");
                    assertEq(page_[j].recipient, window_[start_ - head_ + j].recipient, "views: page recipient");
                    assertEq(page_[j].amount,    window_[start_ - head_ + j].amount,    "views: page amount");
                }
            }
        }
    }

    function _queueViews(HandlerBase.Queue queue_)
        internal view returns (uint256 head_, uint256 length_, IFTMS.Request[] memory window_)
    {
        if (queue_ == HandlerBase.Queue.DEPOSIT) {
            return ( vault.processedDepositCount(), vault.pendingDepositRequestsLength(), vault.pendingDepositRequests() );
        }

        if (queue_ == HandlerBase.Queue.DEPOSIT_CANCELLATION) {
            return (
                vault.processedDepositCancellationCount(),
                vault.pendingDepositCancellationRequestsLength(),
                vault.pendingDepositCancellationRequests()
            );
        }

        return ( vault.processedRedeemCount(), vault.pendingRedeemRequestsLength(), vault.pendingRedeemRequests() );
    }

    function _getRequest(HandlerBase.Queue queue_, uint256 id_) internal view returns (IFTMS.Request memory r_) {
        if (queue_ == HandlerBase.Queue.DEPOSIT) {
            ( r_.owner, r_.recipient, r_.timestamp, r_.amount ) = vault.getPendingDepositRequest(id_);
        } else if (queue_ == HandlerBase.Queue.DEPOSIT_CANCELLATION) {
            ( r_.owner, r_.recipient, r_.timestamp, r_.amount ) = vault.getPendingDepositCancellationRequest(id_);
        } else {
            ( r_.owner, r_.recipient, r_.timestamp, r_.amount ) = vault.getPendingRedeemRequest(id_);
        }
    }

    function _getRequests(HandlerBase.Queue queue_, uint256 start_, uint256 length_)
        internal view returns (IFTMS.Request[] memory)
    {
        if (queue_ == HandlerBase.Queue.DEPOSIT)              return vault.getPendingDepositRequests(start_, length_);
        if (queue_ == HandlerBase.Queue.DEPOSIT_CANCELLATION) return vault.getPendingDepositCancellationRequests(start_, length_);
        return vault.getPendingRedeemRequests(start_, length_);
    }

    // Reference value to assets and back, straight from the oracle.
    function _toAssets(uint256 referenceValue_) internal view returns (uint256) {
        return address(oracle) == address(0) ? referenceValue_ : oracle.convertToShares(referenceValue_);
    }

    function _toReference(uint256 assets_) internal view returns (uint256) {
        return address(oracle) == address(0) ? assets_ : oracle.convertToAssets(assets_);
    }

    // With the VSR at 0% and a price that only rises, the vault's net assets always cover the
    // value of all shares.
    function _assertSolvency() internal view {
        if (_strict()) assertGe(userHandler.surplus(), 0, "vault is short");
    }

}
