// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IERC20 } from "../lib/oz/contracts/token/ERC20/IERC20.sol";

import { ISparkPrimeVault } from "../src/ISparkPrimeVault.sol";

import { TestBase, ISparkVaultLike } from "./TestBase.t.sol";

abstract contract SparkPrimeVaultTests is TestBase {

    uint16 internal constant REFERRAL = type(uint16).max;

    address internal user = makeAddr("user");

    function setUp() public override virtual {
        super.setUp();

        vm.label(user, "user");

        skip(365 days);

        vaultState.availableCapacityValue = spPrime.convertSharesToReferenceValue(VAULT_CAPACITY);
    }

}

contract RequestDepositTests is SparkPrimeVaultTests {

    // Failure tests

    function test_requestDeposit_isPaused() external {
        _pause();

        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vm.prank(user);
        spPrime.requestDeposit(100e6, user, 0);
    }

    function test_requestDeposit_zeroRecipient() external {
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vm.prank(user);
        spPrime.requestDeposit(100e6, address(0), 0);
    }

    function test_requestDeposit_vaultIsRecipient() external {
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vm.prank(user);
        spPrime.requestDeposit(100e6, address(spPrime), 0);
    }

    function test_requestDeposit_belowMinDepositBoundary() external {
        deal(address(spUSDC), user, MINIMUM_DEPOSIT);

        vm.prank(user);
        spUSDC.approve(address(spPrime), MINIMUM_DEPOSIT);

        vm.expectRevert(ISparkPrimeVault.BelowMinDeposit.selector);
        vm.prank(user);
        spPrime.requestDeposit(MINIMUM_DEPOSIT - 1, user, 0);

        vm.prank(user);
        spPrime.requestDeposit(MINIMUM_DEPOSIT, user, 0);
    }

    function test_requestDeposit_insufficientAllowanceBoundary() external {
        deal(address(spUSDC), user, 1_000_000e6 + 1);

        vm.prank(user);
        spUSDC.approve(address(spPrime), 1_000_000e6);

        vm.prank(user);
        vm.expectRevert("SparkVault/insufficient-allowance");
        spPrime.requestDeposit(1_000_000e6 + 1, user, 0);

        vm.prank(user);
        spPrime.requestDeposit(1_000_000e6, user, 0);
    }

    function test_requestDeposit_insufficientBalanceBoundary() external {
        deal(address(spUSDC), user, 1_000_000e6);

        vm.prank(user);
        spUSDC.approve(address(spPrime), 1_000_000e6 + 1);

        vm.prank(user);
        vm.expectRevert("SparkVault/insufficient-balance");
        spPrime.requestDeposit(1_000_000e6 + 1, user, 0);

        vm.prank(user);
        spPrime.requestDeposit(1_000_000e6, user, 0);
    }

    // Success tests

    function test_requestDeposit_partialFill() external {
        _requestDeposit(user, 1_000_000e6);  // Deposit Request 0 (Filled instantly)

        _setCapacity(spPrime.convertReferenceValueToShares(1_500_000e6));

        vaultState.rho                    = vm.getBlockTimestamp();
        vaultState.chi                    = 1.049999999999999999961070145e27;
        vaultState.totalValue             = 1_000_000e6 - 2;
        vaultState.availableCapacityValue = 500_000e6;
        vaultState.availableLiquidValue   = 1_000_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 0;
        vaultState.depositRequests.processedCount    = 1;

        AccountBalances memory userBalances = AccountBalances({
            account           : user,
            assets            : 0,
            shareValue        : 1_000_000e6 - 2,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        AccountBalances memory vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 1_000_000e6 - 1,
            claimableAssetsOf : 0
        });

        _assertVaultState();

        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        uint256 savingsShares = _dealSavingsShares(user, 800_000e6);

        uint256 expectedConvertedAssets       = 500_000e6 - 1;
        uint256 expectedSavingsSharesMinted   = spUSDC.convertToShares(800_000e6);
        uint256 expectedSavingsSharesConsumed = spUSDC.convertToShares(expectedConvertedAssets) + 1;
        uint256 expectedSharesMinted          = spPrime.convertReferenceValueToShares(expectedConvertedAssets);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Referral(REFERRAL, 1, user, user, expectedSavingsSharesMinted);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositRequest(1, user, user, expectedSavingsSharesMinted);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(1, user, user, expectedSavingsSharesConsumed, expectedConvertedAssets, expectedSharesMinted);

        vm.prank(user);
        uint256 requestId = spPrime.requestDeposit(savingsShares, user, REFERRAL);

        assertEq(requestId, 1);

        _assertDepositRequest(1, user, user, 300_000e6);

        vaultState.totalValue             += 500_000e6 - 1;
        vaultState.availableCapacityValue  = 2;
        vaultState.availableLiquidValue   += 800_000e6;

        vaultState.depositRequests.pendingShareValue += 300_000e6;
        vaultState.depositRequests.length             = 1;
        vaultState.depositRequests.processedCount     = 1;

        userBalances.shareValue += 500_000e6 - 1;

        vaultBalances.savingsShareValue += 800_000e6;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
    }

    function test_requestDeposit_queued() external {
        _requestDeposit(user, 1_000_000e6);  // Deposit Request 0 (Filled instantly)

        _setCapacity(spPrime.convertReferenceValueToShares(1_000_000e6));

        vaultState.rho                    = vm.getBlockTimestamp();
        vaultState.chi                    = 1.049999999999999999961070145e27;
        vaultState.totalValue             = 1_000_000e6 - 2;
        vaultState.availableCapacityValue = 0;
        vaultState.availableLiquidValue   = 1_000_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 0;
        vaultState.depositRequests.processedCount    = 1;

        AccountBalances memory userBalances = AccountBalances({
            account           : user,
            assets            : 0,
            shareValue        : 1_000_000e6 - 2,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        AccountBalances memory vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 1_000_000e6 - 1,
            claimableAssetsOf : 0
        });

        _assertVaultState();

        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        uint256 savingsShares = _dealSavingsShares(user, 800_000e6);

        uint256 expectedSavingsSharesMinted = spUSDC.convertToShares(800_000e6);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Referral(REFERRAL, 1, user, user, expectedSavingsSharesMinted);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositRequest(1, user, user, expectedSavingsSharesMinted);

        vm.prank(user);
        uint256 requestId = spPrime.requestDeposit(savingsShares, user, REFERRAL);

        assertEq(requestId, 1);

        _assertDepositRequest(1, user, user, 800_000e6 - 1);

        vaultState.availableLiquidValue  += 800_000e6;

        vaultState.depositRequests.pendingShareValue = 800_000e6 - 1;
        vaultState.depositRequests.length            = 1;
        vaultState.depositRequests.processedCount    = 1;

        vaultBalances.savingsShareValue += 800_000e6;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
    }

    function test_requestDeposit_afterTombstones() external {
        _setCapacity(0);

        _requestDeposit(user, 1_000e6);
        _requestDeposit(user, 1_000e6);
        _requestDeposit(user, 1_000e6);

        _requestDepositCancellation(user, 0, user, spUSDC.convertToShares(1_000e6));
        _requestDepositCancellation(user, 1, user, spUSDC.convertToShares(1_000e6));
        _requestDepositCancellation(user, 2, user, spUSDC.convertToShares(1_000e6));

        _setCapacity(VAULT_CAPACITY);

        uint256 savingsShares = _dealSavingsShares(user, 200_000e6);

        vaultState.rho                   = vm.getBlockTimestamp();
        vaultState.chi                   = 1.049999999999999999961070145e27;
        vaultState.availableLiquidValue  = 3_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 3;
        vaultState.depositRequests.processedCount    = 0;

        vaultState.depositCancellationRequests.pendingShareValue = 3_000e6 - 1;
        vaultState.depositCancellationRequests.length            = 3;
        vaultState.depositCancellationRequests.processedCount    = 0;

        AccountBalances memory userBalances = AccountBalances({
            account           : user,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 200_000e6 - 1,
            claimableAssetsOf : 0
        });

        AccountBalances memory vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 3_000e6 - 1,
            claimableAssetsOf : 0
        });

        _assertVaultState();

        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        _assertEmptyDepositRequest(0);
        _assertEmptyDepositRequest(1);
        _assertEmptyDepositRequest(2);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Referral(REFERRAL, 3, user, user, spUSDC.convertToShares(200_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositRequest(3, user, user, spUSDC.convertToShares(200_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(3, user, user, spUSDC.convertToShares(200_000e6), 200_000e6 - 1, spPrime.convertReferenceValueToShares(200_000e6) - 1);

        vm.prank(user);
        uint256 requestId = spPrime.requestDeposit(savingsShares, user, REFERRAL);

        assertEq(requestId, 3);

        for (uint256 i = 0; i < 4; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingDepositRequest(i);
        }

        vaultState.availableCapacityValue -= 200_000e6 - 2;
        vaultState.availableLiquidValue   += 200_000e6;
        vaultState.totalValue             += 200_000e6 - 2;

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 0;
        vaultState.depositRequests.processedCount    = 4;

        userBalances.savingsShareValue  = 0;
        userBalances.shareValue        += 200_000e6 - 2;

        vaultBalances.savingsShareValue += 200_000e6;

        _assertVaultState();

        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
    }

}

contract RequestRedeemTests is SparkPrimeVaultTests {

    // Failure tests

    function test_requestRedeem_isPaused() external {
        _pause();

        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vm.prank(user);
        spPrime.requestRedeem(100e6, user);
    }

    function test_requestRedeem_zeroRecipient() external {
        vm.expectRevert(ISparkPrimeVault.ZeroRecipient.selector);
        vm.prank(user);
        spPrime.requestRedeem(100e6, address(0));
    }

    function test_requestRedeem_vaultIsRecipient() external {
        vm.expectRevert(ISparkPrimeVault.VaultIsRecipient.selector);
        vm.prank(user);
        spPrime.requestRedeem(100e6, address(spPrime));
    }

    function test_requestRedeem_belowMinRedeemBoundary() external {
        _requestDeposit(user, 1_000e6);

        vm.expectRevert(ISparkPrimeVault.BelowMinRedeem.selector);
        vm.prank(user);
        spPrime.requestRedeem(MINIMUM_REDEEM - 1, user);

        vm.prank(user);
        spPrime.requestRedeem(MINIMUM_REDEEM, user);
    }

    function test_requestRedeem_insufficientBalanceBoundary() external {
        _requestDeposit(user, 1_000e6);

        uint256 spPrimeShares = spPrime.balanceOf(user);

        assertEq(spPrimeShares, 952.380951e6);

        vm.expectRevert("SparkPrimeVault/insufficient-balance");
        vm.prank(user);
        spPrime.requestRedeem(spPrimeShares + 1, user);

        vm.prank(user);
        spPrime.requestRedeem(spPrimeShares, user);
    }

    // Success tests

    function test_requestRedeem() external {
        _requestDeposit(user, 1_000_000e6);  // Deposit Request 0 (Filled instantly)

        vaultState.rho                    = vm.getBlockTimestamp();
        vaultState.chi                    = 1.049999999999999999961070145e27;
        vaultState.totalValue             = 1_000_000e6 - 2;
        vaultState.availableCapacityValue = 104_000_000e6;  // Vault capacity value was 105m because of 5% change in chi prior to the first deposit
        vaultState.availableLiquidValue   = 1_000_000e6 - 1;

        vaultState.depositRequests.processedCount = 1;

        AccountBalances memory userBalances = AccountBalances({
            account           : user,
            assets            : 0,
            shareValue        : 1_000_000e6 - 2,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        AccountBalances memory vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 1_000_000e6 - 1,
            claimableAssetsOf : 0
        });

        _assertVaultState();

        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.RedeemRequest(0, user, user, 500_000e6, 0);

        vm.prank(user);
        uint256 requestId = spPrime.requestRedeem(500_000e6, user);

        assertEq(requestId, 0);

        vaultState.redeemRequests.pendingShareValue = 525_000e6 - 1;  // 500k spPrime == 525k USD because of current exchange rate
        vaultState.redeemRequests.length            = 1;
        vaultState.redeemRequests.processedCount    = 0;

        userBalances.shareValue -= 525_000e6;

        vaultBalances.shareValue += 525_000e6 - 1;

        _assertRedeemRequest(0, user, user, 525_000e6 - 1);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
    }

    function test_requestRedeem_withFee() external {
        _setMaxRedeemFeeRate(0.01e18);  // 1%
        _setRedeemFeeRate(0.005e18);    // 0.5%

        _requestDeposit(user, 1_000_000e6);  // Deposit Request 0 (Filled instantly)

        vaultState.rho                    = vm.getBlockTimestamp();
        vaultState.chi                    = 1.049999999999999999961070145e27;
        vaultState.totalValue             = 1_000_000e6 - 2;
        vaultState.availableCapacityValue = 104_000_000e6;  // Vault capacity value was 105m because of 5% change in chi prior to the first deposit
        vaultState.availableLiquidValue   = 1_000_000e6 - 1;

        vaultState.depositRequests.processedCount = 1;

        AccountBalances memory userBalances = AccountBalances({
            account           : user,
            assets            : 0,
            shareValue        : 1_000_000e6 - 2,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        AccountBalances memory vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 1_000_000e6 - 1,
            claimableAssetsOf : 0
        });

        _assertVaultState();

        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // Assets held (spUSDC value) match assets owed to spPrime holders, within rounding
        assertEq(spPrime.availableLiquidReferenceValue() - spPrime.totalReferenceValue(), 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.RedeemRequest(0, user, user, 500_000e6, 2_500e6);

        vm.prank(user);
        uint256 requestId = spPrime.requestRedeem(500_000e6, user);

        assertEq(requestId, 0);

        // Fee shares are burned, so supply and assets drop and capacity frees up
        vaultState.totalValue             -= 2_625e6;  // 2_500e6 fee shares * 1.05 chi
        vaultState.availableCapacityValue += 2_625e6;

        vaultState.redeemRequests.pendingShareValue = 525_000e6 - 2_625e6 - 1;
        vaultState.redeemRequests.length            = 1;
        vaultState.redeemRequests.processedCount    = 0;

        userBalances.shareValue -= 525_000e6;

        vaultBalances.shareValue += 525_000e6 - 2_625e6 - 1;

        _assertRedeemRequest(0, user, user, 525_000e6 - 2_625e6 - 1);

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // Assets held are unchanged but assets owed dropped by the burned fee, the difference is Spark's profit
        assertEq(spPrime.availableLiquidReferenceValue() - spPrime.totalReferenceValue(), 2_625e6 + 1);
    }

}

contract ProcessPendingDepositsTests is SparkPrimeVaultTests {

    address internal ali = makeAddr("ali");
    address internal bob = makeAddr("bob");
    address internal cam = makeAddr("cam");

    AccountBalances internal aliBalances;
    AccountBalances internal bobBalances;
    AccountBalances internal camBalances;
    AccountBalances internal vaultBalances;

    function setUp() public override {
        super.setUp();

        vm.label(ali, "ali");
        vm.label(bob, "bob");
        vm.label(cam, "cam");

        _setCapacity(0);

        _requestDeposit(ali, 100_000e6);    // Will be cancelled
        _requestDeposit(bob, 200_000e6);    // Will be cancelled
        _requestDeposit(cam, 300_000e6);    // Will be cancelled
        _requestDeposit(ali, 400_000e6);    // Will be filled
        _requestDeposit(bob, 500_000e6);    // Will be filled
        _requestDeposit(cam, 600_000e6);    // Will be cancelled
        _requestDeposit(ali, 700_000e6);    // Will be filled
        _requestDeposit(bob, 800_000e6);    // Will be filled
        _requestDeposit(cam, 900_000e6);    // Will be cancelled
        _requestDeposit(ali, 1_000_000e6);  // Will be partially filled

        _requestDepositCancellation(ali, 0, spUSDC.convertToShares(100_000e6));
        _requestDepositCancellation(bob, 1, spUSDC.convertToShares(200_000e6));
        _requestDepositCancellation(cam, 2, spUSDC.convertToShares(300_000e6));
        _requestDepositCancellation(cam, 5, spUSDC.convertToShares(600_000e6));
        _requestDepositCancellation(cam, 8, spUSDC.convertToShares(900_000e6));

        uint256 depositedAssets = 5_500_000e6;

        uint256 pendingDepositAssets = 400_000e6 + 500_000e6 + 700_000e6 + 800_000e6 + 1_000_000e6;

        uint256 pendingDepositCancellationAssets = 100_000e6 + 200_000e6 + 300_000e6 + 600_000e6 + 900_000e6;

        uint256 targetAssets = 400_000e6 + 500_000e6 + 700_000e6 + 800_000e6 + 200_000e6;  // Only 200k of the last 1MM deposit

        _setCapacity(spPrime.convertReferenceValueToShares(targetAssets));

        vaultState.rho                    = vm.getBlockTimestamp();
        vaultState.chi                    = 1.049999999999999999961070145e27;
        vaultState.totalValue             = 0;
        vaultState.totalClaimable         = 0;
        vaultState.availableCapacityValue = targetAssets - 1;
        vaultState.availableLiquidValue   = depositedAssets - 5;

        vaultState.depositRequests.pendingShareValue = pendingDepositAssets - 3;
        vaultState.depositRequests.length            = 10;
        vaultState.depositRequests.processedCount    = 0;

        vaultState.depositCancellationRequests.pendingShareValue = pendingDepositCancellationAssets - 3;
        vaultState.depositCancellationRequests.length            = 5;
        vaultState.depositCancellationRequests.processedCount    = 0;

        aliBalances = AccountBalances({
            account           : ali,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        bobBalances = AccountBalances({
            account           : bob,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        camBalances = AccountBalances({
            account           : cam,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : depositedAssets - 5,
            claimableAssetsOf : 0
        });

        _assertVaultState();

        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 3; i++) {
            _assertEmptyDepositRequest(i);
        }

        _assertDepositRequest(3, ali, ali, 400_000e6 - 1);
        _assertDepositRequest(4, bob, bob, 500_000e6 - 1);

        _assertEmptyDepositRequest(5);

        _assertDepositRequest(6, ali, ali, 700_000e6 - 1);
        _assertDepositRequest(7, bob, bob, 800_000e6 - 1);

        _assertEmptyDepositRequest(8);

        _assertDepositRequest(9, ali, ali, 1_000_000e6 - 1);
    }

    // Failure tests

    function test_processPendingDeposits_isPaused() external {
        _pause();

        vm.expectRevert(ISparkPrimeVault.IsPaused.selector);
        vm.prank(operator);
        spPrime.processPendingDeposits(type(uint256).max, type(uint256).max);
    }

    // Success tests

    function test_processPendingDeposits_infiniteMaxSavingsShares_infiniteMaxRequests() external {
        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ProcessPendingDeposits(operator, type(uint256).max, type(uint256).max);

        // Deposit Request 3

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), ali, spPrime.convertReferenceValueToShares(400_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(3, ali, ali, spUSDC.convertToShares(400_000e6), 400_000e6 - 1, spPrime.convertReferenceValueToShares(400_000e6) - 1);

        // Deposit Request 4

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), bob, spPrime.convertReferenceValueToShares(500_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(4, bob, bob, spUSDC.convertToShares(500_000e6), 500_000e6 - 1, spPrime.convertReferenceValueToShares(500_000e6) - 1);

        // Deposit Request 6

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), ali, spPrime.convertReferenceValueToShares(700_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(6, ali, ali, spUSDC.convertToShares(700_000e6), 700_000e6 - 1, spPrime.convertReferenceValueToShares(700_000e6) - 1);

        // Deposit Request 7

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), bob, spPrime.convertReferenceValueToShares(800_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(7, bob, bob, spUSDC.convertToShares(800_000e6), 800_000e6 - 1, spPrime.convertReferenceValueToShares(800_000e6) - 1);

        // Deposit Request 9 (Partial)

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), ali, spPrime.convertReferenceValueToShares(200_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(9, ali, ali, spUSDC.convertToShares(200_000e6) + 1, 200_000e6, spPrime.convertReferenceValueToShares(200_000e6));

        vm.prank(operator);
        spPrime.processPendingDeposits(type(uint256).max, type(uint256).max);

        uint256 assetsDeposited = 400_000e6 + 500_000e6 + 700_000e6 + 800_000e6 + 200_000e6;  // Only ~200k of the last 1MM deposit

        vaultState.totalValue             += assetsDeposited - 7;
        vaultState.availableCapacityValue -= assetsDeposited - 7;

        vaultState.depositRequests.pendingShareValue -= assetsDeposited - 1;
        vaultState.depositRequests.length             = 1;
        vaultState.depositRequests.processedCount     = 9;

        aliBalances.shareValue += 400_000e6 + 700_000e6 + 200_000e6 - 4;
        bobBalances.shareValue += 500_000e6 + 800_000e6 - 4;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 9; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingDepositRequest(i);
        }

        _assertDepositRequest(9, ali, ali, 800_000e6 - 2);
    }

    function test_processPendingDeposits_infiniteMaxSavingsShares_limitedMaxRequests() external {
        uint256 maxRequests = 6;

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ProcessPendingDeposits(operator, type(uint256).max, maxRequests);

        // Deposit Request 3

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), ali, spPrime.convertReferenceValueToShares(400_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(3, ali, ali, spUSDC.convertToShares(400_000e6), 400_000e6 - 1, spPrime.convertReferenceValueToShares(400_000e6) - 1);

        // Deposit Request 4

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), bob, spPrime.convertReferenceValueToShares(500_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(4, bob, bob, spUSDC.convertToShares(500_000e6), 500_000e6 - 1, spPrime.convertReferenceValueToShares(500_000e6) - 1);

        // First 3 are cancelled/empty deposits, so this fills 2 deposits, then skips 1 cancelled deposit.
        vm.prank(operator);
        spPrime.processPendingDeposits(type(uint256).max, maxRequests);

        uint256 assetsDeposited = 400_000e6 + 500_000e6;  // Only first 2 uncancelled deposits

        vaultState.totalValue             += assetsDeposited - 4;
        vaultState.availableCapacityValue -= assetsDeposited - 3;

        vaultState.depositRequests.pendingShareValue -= assetsDeposited - 1;
        vaultState.depositRequests.length             = 4;
        vaultState.depositRequests.processedCount     = 6;

        aliBalances.shareValue += 400_000e6 - 2;
        bobBalances.shareValue += 500_000e6 - 2;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 6; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingDepositRequest(i);
        }

        _assertDepositRequest(6, ali, ali, 700_000e6 - 1);
        _assertDepositRequest(7, bob, bob, 800_000e6 - 1);

        _assertEmptyDepositRequest(8);

        _assertDepositRequest(9, ali, ali, 1_000_000e6 - 1);
    }

    function test_processPendingDeposits_limitedMaxSavingsShares_infiniteMaxRequests() external {
        uint256 maxSavingsShares = spUSDC.convertToShares(1_200_000e6);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ProcessPendingDeposits(operator, maxSavingsShares, type(uint256).max);

        // Deposit Request 3

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), ali, spPrime.convertReferenceValueToShares(400_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(3, ali, ali, spUSDC.convertToShares(400_000e6), 400_000e6 - 1, spPrime.convertReferenceValueToShares(400_000e6) - 1);

        // Deposit Request 4

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), bob, spPrime.convertReferenceValueToShares(500_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(4, bob, bob, spUSDC.convertToShares(500_000e6), 500_000e6 - 1, spPrime.convertReferenceValueToShares(500_000e6) - 1);

        // Deposit Request 6 (Partial)

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), ali, spPrime.convertReferenceValueToShares(300_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(6, ali, ali, spUSDC.convertToShares(300_000e6) + 1, 300_000e6, spPrime.convertReferenceValueToShares(300_000e6));

        vm.prank(operator);
        spPrime.processPendingDeposits(maxSavingsShares, type(uint256).max);

        uint256 assetsDeposited = 400_000e6 + 500_000e6 + 300_000e6;  // Only ~300k of the third uncancelled 700k deposit

        vaultState.totalValue             += assetsDeposited - 4;
        vaultState.availableCapacityValue -= assetsDeposited - 3;

        vaultState.depositRequests.pendingShareValue -= assetsDeposited - 1;
        vaultState.depositRequests.length             = 4;
        vaultState.depositRequests.processedCount     = 6;

        aliBalances.shareValue += 400_000e6 + 300_000e6 - 2;
        bobBalances.shareValue += 500_000e6 - 2;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 6; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingDepositRequest(i);
        }

        _assertDepositRequest(6, ali, ali, 400_000e6 - 2);  // Partial fill
        _assertDepositRequest(7, bob, bob, 800_000e6 - 1);

        _assertEmptyDepositRequest(8);

        _assertDepositRequest(9, ali, ali, 1_000_000e6 - 1);
    }

    function _getMaxDepositableAmount(uint256 requestAmount, uint256 maxSavingsShareValue, uint256 assetsDeposited) internal pure returns (uint256) {
        return assetsDeposited + requestAmount > maxSavingsShareValue
            ? maxSavingsShareValue - assetsDeposited
            : requestAmount;
    }

    function testFuzz_processPendingDeposits(uint256 maxSavingsShareValue, uint256 maxRequests) external {
        maxSavingsShareValue = _bound(maxSavingsShareValue, 0, 2 * vaultState.depositRequests.pendingShareValue);
        maxRequests          = _bound(maxRequests,          0, 2 * vaultState.depositRequests.length);

        vm.startPrank(operator);
        spPrime.processPendingDeposits(spUSDC.convertToShares(maxSavingsShareValue), maxRequests);
        vm.stopPrank();

        uint256 assetsDeposited;

        for (uint256 i = 0; i < maxRequests; ++i) {
            if (i == 3) {
                uint256 depositAmount = _getMaxDepositableAmount(400_000e6, maxSavingsShareValue, 0);

                aliBalances.shareValue += depositAmount;
                assetsDeposited        += depositAmount;

                if (depositAmount < 400_000e6) break;
            }

            if (i == 4) {
                uint256 depositAmount = _getMaxDepositableAmount(500_000e6, maxSavingsShareValue, assetsDeposited);

                bobBalances.shareValue += depositAmount;
                assetsDeposited        += depositAmount;

                if (depositAmount < 500_000e6) break;
            }

            if (i == 6) {
                uint256 depositAmount = _getMaxDepositableAmount(700_000e6, maxSavingsShareValue, assetsDeposited);

                aliBalances.shareValue += depositAmount;
                assetsDeposited        += depositAmount;

                if (depositAmount < 700_000e6) break;
            }

            if (i == 7) {
                uint256 depositAmount = _getMaxDepositableAmount(800_000e6, maxSavingsShareValue, assetsDeposited);

                bobBalances.shareValue += depositAmount;
                assetsDeposited        += depositAmount;

                if (depositAmount < 800_000e6) break;
            }

            if (i == 9) {
                uint256 depositAmount = _getMaxDepositableAmount(200_000e6, maxSavingsShareValue, assetsDeposited);

                aliBalances.shareValue += depositAmount;
                assetsDeposited        += depositAmount;

                break;  // Last deposit request can never be entirely fulfilled.
            }

            --vaultState.depositRequests.length;
            ++vaultState.depositRequests.processedCount;

            if (vaultState.depositRequests.length == 0) break;
        }

        vaultState.totalValue  += assetsDeposited;

        if (vaultState.availableCapacityValue < assetsDeposited) {
            vaultState.availableCapacityValue = 0;
        } else {
            vaultState.availableCapacityValue -= assetsDeposited;
        }

        if (vaultState.depositRequests.pendingShareValue < assetsDeposited) {
            vaultState.depositRequests.pendingShareValue = 0;
        } else {
            vaultState.depositRequests.pendingShareValue -= assetsDeposited;
        }

        _assertVaultState(10);
        _assertAccountBalances(aliBalances,   10);
        _assertAccountBalances(bobBalances,   10);
        _assertAccountBalances(camBalances,   10);
        _assertAccountBalances(vaultBalances, 10);
    }

    function test_processPendingDeposits_multipleCalls() external {
        uint256 maxSavingsShares = spUSDC.convertToShares(1_200_000e6);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ProcessPendingDeposits(operator, maxSavingsShares, type(uint256).max);

        // Deposit Request 3

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), ali, spPrime.convertReferenceValueToShares(400_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(3, ali, ali, spUSDC.convertToShares(400_000e6), 400_000e6 - 1, spPrime.convertReferenceValueToShares(400_000e6) - 1);

        // Deposit Request 4

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), bob, spPrime.convertReferenceValueToShares(500_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(4, bob, bob, spUSDC.convertToShares(500_000e6), 500_000e6 - 1, spPrime.convertReferenceValueToShares(500_000e6) - 1);

        // Deposit Request 6 (Partial)

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), ali, spPrime.convertReferenceValueToShares(300_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(6, ali, ali, spUSDC.convertToShares(300_000e6) + 1, 300_000e6, spPrime.convertReferenceValueToShares(300_000e6));

        vm.prank(operator);
        spPrime.processPendingDeposits(maxSavingsShares, type(uint256).max);

        uint256 assetsDeposited = 400_000e6 + 500_000e6 + 300_000e6;  // Only ~300k of the Request 6 700k deposit

        vaultState.totalValue             += assetsDeposited - 4;
        vaultState.availableCapacityValue -= assetsDeposited - 3;

        vaultState.depositRequests.pendingShareValue -= assetsDeposited - 1;
        vaultState.depositRequests.length             = 4;
        vaultState.depositRequests.processedCount     = 6;

        aliBalances.shareValue += 400_000e6 + 300_000e6 - 2;
        bobBalances.shareValue += 500_000e6 - 2;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 6; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingDepositRequest(i);
        }

        _assertDepositRequest(6, ali, ali, 400_000e6 - 2);  // Partial fill
        _assertDepositRequest(7, bob, bob, 800_000e6 - 1);

        _assertEmptyDepositRequest(8);

        _assertDepositRequest(9, ali, ali, 1_000_000e6 - 1);

        // Deposit Request 6 (Remainder)

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), ali, spPrime.convertReferenceValueToShares(400_000e6) - 2);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(6, ali, ali, spUSDC.convertToShares(400_000e6) - 1, 400_000e6 - 2, spPrime.convertReferenceValueToShares(400_000e6) - 2);

        // Deposit Request 7

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), bob, spPrime.convertReferenceValueToShares(800_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(7, bob, bob, spUSDC.convertToShares(800_000e6), 800_000e6 - 1, spPrime.convertReferenceValueToShares(800_000e6) - 1);

        // Deposit Request 9 (Partial)

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(0), ali, spPrime.convertReferenceValueToShares(200_000e6) + 3);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Deposit(9, ali, ali, spUSDC.convertToShares(200_000e6) + 3, 200_000e6 + 3, spPrime.convertReferenceValueToShares(200_000e6) + 3);

        vm.prank(operator);
        spPrime.processPendingDeposits(type(uint256).max, type(uint256).max);

        assetsDeposited = 400_000e6 + 800_000e6 + 200_000e6;  // Remaining ~400k of request 6, then only ~200k of the last 1MM deposit

        vaultState.totalValue             += assetsDeposited - 1;
        vaultState.availableCapacityValue -= assetsDeposited - 2;

        vaultState.depositRequests.pendingShareValue -= assetsDeposited + 2;
        vaultState.depositRequests.length             = 1;
        vaultState.depositRequests.processedCount     = 9;

        aliBalances.shareValue += 400_000e6 + 200_000e6;
        bobBalances.shareValue += 800_000e6 - 2;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 9; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingDepositRequest(i);
        }

        _assertDepositRequest(9, ali, ali, 800_000e6 - 4);
    }

}

contract ProcessPendingDepositsCancellationsTests is SparkPrimeVaultTests {

    address internal ali = makeAddr("ali");
    address internal bob = makeAddr("bob");
    address internal cam = makeAddr("cam");
    address internal dan = makeAddr("dan");

    AccountBalances internal aliBalances;
    AccountBalances internal bobBalances;
    AccountBalances internal camBalances;
    AccountBalances internal danBalances;
    AccountBalances internal vaultBalances;

    function setUp() public override {
        super.setUp();

        vm.label(ali, "ali");
        vm.label(bob, "bob");
        vm.label(cam, "cam");
        vm.label(dan, "dan");

        _setCapacity(0);

        _requestDeposit(ali, 100_000e6);
        _requestDeposit(bob, 200_000e6);
        _requestDeposit(cam, 300_000e6);
        _requestDeposit(ali, 400_000e6);
        _requestDeposit(bob, 500_000e6);
        _requestDeposit(cam, 600_000e6);
        _requestDeposit(ali, 700_000e6);
        _requestDeposit(bob, 800_000e6);
        _requestDeposit(cam, 900_000e6);
        _requestDeposit(ali, 1_000_000e6);

        _requestDepositCancellation(ali, 0, ali, spUSDC.convertToShares(100_000e6));  // Will fail
        _requestDepositCancellation(bob, 1, bob, spUSDC.convertToShares(200_000e6));
        _requestDepositCancellation(cam, 2, cam, spUSDC.convertToShares(300_000e6));
        _requestDepositCancellation(ali, 3, dan, spUSDC.convertToShares(400_000e6));  // Will fail
        _requestDepositCancellation(bob, 4, bob, spUSDC.convertToShares(500_000e6));  // Will fail
        _requestDepositCancellation(cam, 5, cam, spUSDC.convertToShares(600_000e6));
        _requestDepositCancellation(ali, 6, ali, spUSDC.convertToShares(700_000e6));  // Will fail
        _requestDepositCancellation(bob, 7, dan, spUSDC.convertToShares(800_000e6));  // Will fail
        _requestDepositCancellation(cam, 8, cam, spUSDC.convertToShares(900_000e6));
        _requestDepositCancellation(ali, 9, ali, spUSDC.convertToShares(1_000_000e6));

        uint256 depositedAssets = 5_500_000e6;

        vaultState.rho                    = vm.getBlockTimestamp();
        vaultState.chi                    = 1.049999999999999999961070145e27;
        vaultState.totalValue             = 0;
        vaultState.totalClaimable         = 0;
        vaultState.availableCapacityValue = 0;
        vaultState.availableLiquidValue   = depositedAssets - 5;

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 10;
        vaultState.depositRequests.processedCount    = 0;

        vaultState.depositCancellationRequests.pendingShareValue = depositedAssets - 5;
        vaultState.depositCancellationRequests.length            = 10;
        vaultState.depositCancellationRequests.processedCount    = 0;

        aliBalances = AccountBalances({
            account           : ali,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        bobBalances = AccountBalances({
            account           : bob,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        camBalances = AccountBalances({
            account           : cam,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        danBalances = AccountBalances({
            account           : dan,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : depositedAssets - 5,
            claimableAssetsOf : 0
        });

        _assertVaultState();

        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(danBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 10; i++) {
            _assertEmptyDepositRequest(i);
        }

        _assertDepositCancellationRequest(0, ali, ali, 100_000e6 - 1);
        _assertDepositCancellationRequest(1, bob, bob, 200_000e6 - 1);
        _assertDepositCancellationRequest(2, cam, cam, 300_000e6 - 1);
        _assertDepositCancellationRequest(3, ali, dan, 400_000e6 - 1);
        _assertDepositCancellationRequest(4, bob, bob, 500_000e6 - 1);
        _assertDepositCancellationRequest(5, cam, cam, 600_000e6 - 1);
        _assertDepositCancellationRequest(6, ali, ali, 700_000e6 - 1);
        _assertDepositCancellationRequest(7, bob, dan, 800_000e6 - 1);
        _assertDepositCancellationRequest(8, cam, cam, 900_000e6 - 1);
        _assertDepositCancellationRequest(9, ali, ali, 1_000_000e6 - 1);
    }


    function test_processPendingDepositCancellations_whilePaused() external {
        _pause();

        vm.prank(operator);
        spPrime.processPendingDepositCancellations(type(uint256).max, type(uint256).max);
    }

    function _setupMockCallReverts() internal {
        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(IERC20.transfer.selector, ali, spUSDC.convertToShares(100_000e6)),
            ""
        );

        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(IERC20.transfer.selector, dan, spUSDC.convertToShares(400_000e6)),
            ""
        );

        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(IERC20.transfer.selector, bob, spUSDC.convertToShares(500_000e6)),
            ""
        );

        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(IERC20.transfer.selector, ali, spUSDC.convertToShares(700_000e6)),
            ""
        );

        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(IERC20.transfer.selector, dan, spUSDC.convertToShares(800_000e6)),
            ""
        );
    }

    function test_processPendingDepositCancellations_infiniteMaxSavingsShares_infiniteMaxRequests() external {
        _setupMockCallReverts();

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ProcessPendingDepositCancellations(operator, type(uint256).max, type(uint256).max);

        // Deposit Request 0

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(ali, spUSDC.convertToShares(100_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(0, ali, ali, spUSDC.convertToShares(100_000e6));

        // Deposit Request 1

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(1, bob, bob, spUSDC.convertToShares(200_000e6));

        // Deposit Request 2

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(2, cam, cam, spUSDC.convertToShares(300_000e6));

        // Deposit Request 3

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(dan, spUSDC.convertToShares(400_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(3, ali, dan, spUSDC.convertToShares(400_000e6));

        // Deposit Request 4

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(bob, spUSDC.convertToShares(500_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(4, bob, bob, spUSDC.convertToShares(500_000e6));

        // Deposit Request 5

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(5, cam, cam, spUSDC.convertToShares(600_000e6));

        // Deposit Request 6

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(ali, spUSDC.convertToShares(700_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(6, ali, ali, spUSDC.convertToShares(700_000e6));

        // Deposit Request 7

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(dan, spUSDC.convertToShares(800_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(7, bob, dan, spUSDC.convertToShares(800_000e6));

        // Deposit Request 8

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(8, cam, cam, spUSDC.convertToShares(900_000e6));

        // Deposit Request 9

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(9, ali, ali, spUSDC.convertToShares(1_000_000e6));

        vm.prank(operator);
        spPrime.processPendingDepositCancellations(type(uint256).max, type(uint256).max);

        uint256 totalClaimable = 100_000e6 + 400_000e6 + 500_000e6 + 700_000e6 + 800_000e6;

        vaultState.totalClaimable        += totalClaimable - 3;
        vaultState.availableLiquidValue   = 0;

        vaultState.depositCancellationRequests.pendingShareValue = 0;
        vaultState.depositCancellationRequests.length            = 0;
        vaultState.depositCancellationRequests.processedCount    = 10;

        aliBalances.savingsShareValue += 1_000_000e6 - 1;
        aliBalances.claimableAssetsOf += 100_000e6 + 700_000e6 - 2;

        bobBalances.savingsShareValue += 200_000e6 - 1;
        bobBalances.claimableAssetsOf += 500_000e6 - 1;

        camBalances.savingsShareValue += 300_000e6 + 600_000e6 + 900_000e6 - 2;

        danBalances.claimableAssetsOf += 400_000e6 + 800_000e6 - 1;

        vaultBalances.savingsShareValue  = totalClaimable - 3;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(danBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 10; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingDepositCancellationRequest(i);
        }
    }

    function test_processPendingDepositCancellations_infiniteMaxSavingsShares_limitedMaxRequests() external {
        _setupMockCallReverts();

        uint256 maxRequests = 6;

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ProcessPendingDepositCancellations(operator, type(uint256).max, maxRequests);

        // Deposit Request 0

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(ali, spUSDC.convertToShares(100_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(0, ali, ali, spUSDC.convertToShares(100_000e6));

        // Deposit Request 1

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(1, bob, bob, spUSDC.convertToShares(200_000e6));

        // Deposit Request 2

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(2, cam, cam, spUSDC.convertToShares(300_000e6));

        // Deposit Request 3

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(dan, spUSDC.convertToShares(400_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(3, ali, dan, spUSDC.convertToShares(400_000e6));

        // Deposit Request 4

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(bob, spUSDC.convertToShares(500_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(4, bob, bob, spUSDC.convertToShares(500_000e6));

        // Deposit Request 5

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(5, cam, cam, spUSDC.convertToShares(600_000e6));

        vm.prank(operator);
        spPrime.processPendingDepositCancellations(type(uint256).max, maxRequests);

        uint256 assetsWithdrawn = 100_000e6 + 200_000e6 + 300_000e6 + 400_000e6 + 500_000e6 + 600_000e6;
        uint256 totalClaimable  = 100_000e6 + 400_000e6 + 500_000e6;

        vaultState.totalClaimable        += totalClaimable - 2;
        vaultState.availableLiquidValue  -= assetsWithdrawn - 2;

        vaultState.depositCancellationRequests.pendingShareValue -= assetsWithdrawn - 2;
        vaultState.depositCancellationRequests.length            = 4;
        vaultState.depositCancellationRequests.processedCount    = 6;

        aliBalances.claimableAssetsOf += 100_000e6 - 1;

        bobBalances.savingsShareValue += 200_000e6 - 1;
        bobBalances.claimableAssetsOf += 500_000e6 - 1;

        camBalances.savingsShareValue += 300_000e6 + 600_000e6 - 1;

        danBalances.claimableAssetsOf += 400_000e6 - 1;

        vaultBalances.savingsShareValue += totalClaimable - 1;
        vaultBalances.savingsShareValue -= assetsWithdrawn - 2;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(danBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 6; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingDepositCancellationRequest(i);
        }

        _assertDepositCancellationRequest(6, ali, ali, 700_000e6 - 1);
        _assertDepositCancellationRequest(7, bob, dan, 800_000e6 - 1);
        _assertDepositCancellationRequest(8, cam, cam, 900_000e6 - 1);
        _assertDepositCancellationRequest(9, ali, ali, 1_000_000e6 - 1);
    }

    function test_processPendingDepositCancellations_limitedMaxSavingsShares_infiniteMaxRequests() external {
        _setupMockCallReverts();

        uint256 maxSavingsShares = spUSDC.convertToShares(2_000_000e6);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ProcessPendingDepositCancellations(operator, maxSavingsShares, type(uint256).max);

        // Deposit Request 0

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(ali, spUSDC.convertToShares(100_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(0, ali, ali, spUSDC.convertToShares(100_000e6));

        // Deposit Request 1

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(1, bob, bob, spUSDC.convertToShares(200_000e6));

        // Deposit Request 2

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(2, cam, cam, spUSDC.convertToShares(300_000e6));

        // Deposit Request 3

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(dan, spUSDC.convertToShares(400_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(3, ali, dan, spUSDC.convertToShares(400_000e6));

        // Deposit Request 4

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(bob, spUSDC.convertToShares(500_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(4, bob, bob, spUSDC.convertToShares(500_000e6));

        // Deposit Request 5

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(5, cam, cam, spUSDC.convertToShares(500_000e6) + 2);  // Only 500k of the 600k is processed

        vm.prank(operator);
        spPrime.processPendingDepositCancellations(maxSavingsShares, type(uint256).max);

        uint256 assetsWithdrawn = 100_000e6 + 200_000e6 + 300_000e6 + 400_000e6 + 500_000e6 + 500_000e6;  // Only 500k of the last request is processed
        uint256 totalClaimable  = 100_000e6 + 400_000e6 + 500_000e6;

        vaultState.totalClaimable        += totalClaimable - 2;
        vaultState.availableLiquidValue  -= assetsWithdrawn;

        vaultState.depositCancellationRequests.pendingShareValue -= assetsWithdrawn;
        vaultState.depositCancellationRequests.length            = 5;
        vaultState.depositCancellationRequests.processedCount    = 5;

        aliBalances.claimableAssetsOf += 100_000e6 - 1;

        bobBalances.savingsShareValue += 200_000e6 - 1;
        bobBalances.claimableAssetsOf += 500_000e6 - 1;

        camBalances.savingsShareValue += 300_000e6 + 500_000e6;

        danBalances.claimableAssetsOf += 400_000e6 - 1;

        vaultBalances.savingsShareValue += totalClaimable - 1;
        vaultBalances.savingsShareValue -= assetsWithdrawn;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(danBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 5; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingDepositCancellationRequest(i);
        }

        _assertDepositCancellationRequest(5, cam, cam, 100_000e6 - 2);
        _assertDepositCancellationRequest(6, ali, ali, 700_000e6 - 1);
        _assertDepositCancellationRequest(7, bob, dan, 800_000e6 - 1);
        _assertDepositCancellationRequest(8, cam, cam, 900_000e6 - 1);
        _assertDepositCancellationRequest(9, ali, ali, 1_000_000e6 - 1);
    }

    function test_processPendingDepositCancellations_multipleCalls() external {
        _setupMockCallReverts();

        uint256 maxSavingsShares = spUSDC.convertToShares(2_000_000e6);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ProcessPendingDepositCancellations(operator, maxSavingsShares, type(uint256).max);

        // Deposit Request 0

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(ali, spUSDC.convertToShares(100_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(0, ali, ali, spUSDC.convertToShares(100_000e6));

        // Deposit Request 1

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(1, bob, bob, spUSDC.convertToShares(200_000e6));

        // Deposit Request 2

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(2, cam, cam, spUSDC.convertToShares(300_000e6));

        // Deposit Request 3

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(dan, spUSDC.convertToShares(400_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(3, ali, dan, spUSDC.convertToShares(400_000e6));

        // Deposit Request 4

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(bob, spUSDC.convertToShares(500_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(4, bob, bob, spUSDC.convertToShares(500_000e6));

        // Deposit Request 5 (Partial)

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(5, cam, cam, spUSDC.convertToShares(500_000e6) + 2);  // Only 500k of the 600k is processed

        vm.prank(operator);
        spPrime.processPendingDepositCancellations(maxSavingsShares, type(uint256).max);

        uint256 assetsWithdrawn = 100_000e6 + 200_000e6 + 300_000e6 + 400_000e6 + 500_000e6 + 500_000e6;  // Only 500k of the last request is processed
        uint256 totalClaimable  = 100_000e6 + 400_000e6 + 500_000e6;

        vaultState.totalClaimable        += totalClaimable - 2;
        vaultState.availableLiquidValue  -= assetsWithdrawn;

        vaultState.depositCancellationRequests.pendingShareValue -= assetsWithdrawn;
        vaultState.depositCancellationRequests.length             = 5;
        vaultState.depositCancellationRequests.processedCount     = 5;

        aliBalances.claimableAssetsOf += 100_000e6 - 1;

        bobBalances.savingsShareValue += 200_000e6 - 1;
        bobBalances.claimableAssetsOf += 500_000e6 - 1;

        camBalances.savingsShareValue += 300_000e6 + 500_000e6;

        danBalances.claimableAssetsOf += 400_000e6 - 1;

        vaultBalances.savingsShareValue += totalClaimable - 1;
        vaultBalances.savingsShareValue -= assetsWithdrawn;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(danBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 5; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingDepositCancellationRequest(i);
        }

        _assertDepositCancellationRequest(5, cam, cam, 100_000e6 - 2);  // Partial fill
        _assertDepositCancellationRequest(6, ali, ali, 700_000e6 - 1);
        _assertDepositCancellationRequest(7, bob, dan, 800_000e6 - 1);
        _assertDepositCancellationRequest(8, cam, cam, 900_000e6 - 1);
        _assertDepositCancellationRequest(9, ali, ali, 1_000_000e6 - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ProcessPendingDepositCancellations(operator, type(uint256).max, type(uint256).max);

        // Deposit Request 5 (Remainder)

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(5, cam, cam, spUSDC.convertToShares(100_000e6) - 1);

        // Deposit Request 6

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(ali, spUSDC.convertToShares(700_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(6, ali, ali, spUSDC.convertToShares(700_000e6));

        // Deposit Request 7

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(dan, spUSDC.convertToShares(800_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(7, bob, dan, spUSDC.convertToShares(800_000e6));

        // Deposit Request 8

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(8, cam, cam, spUSDC.convertToShares(900_000e6));

        // Deposit Request 9

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.DepositCancellation(9, ali, ali, spUSDC.convertToShares(1_000_000e6));

        vm.prank(operator);
        spPrime.processPendingDepositCancellations(type(uint256).max, type(uint256).max);

        totalClaimable = 700_000e6 + 800_000e6;

        vaultState.totalClaimable        += totalClaimable - 1;
        vaultState.availableLiquidValue   = 0;

        vaultState.depositCancellationRequests.pendingShareValue = 0;
        vaultState.depositCancellationRequests.length            = 0;
        vaultState.depositCancellationRequests.processedCount    = 10;

        aliBalances.savingsShareValue += 1_000_000e6 - 1;
        aliBalances.claimableAssetsOf += 700_000e6 - 1;

        camBalances.savingsShareValue += 100_000e6 + 900_000e6 - 2;

        danBalances.claimableAssetsOf += 800_000e6;

        vaultBalances.savingsShareValue  = vaultState.totalClaimable;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(danBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 10; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingDepositCancellationRequest(i);
        }
    }

    function _getMaxCancellableAmount(uint256 requestAmount, uint256 maxSavingsShares, uint256 savingsSharesWithdrawn)
        internal view returns (uint256 savingsShares, uint256 assets, bool isPartial)
    {
        uint256 requestShares = spUSDC.convertToShares(requestAmount);

        savingsShares = savingsSharesWithdrawn + requestShares > maxSavingsShares
            ? maxSavingsShares - savingsSharesWithdrawn
            : requestShares;

        assets    = spUSDC.convertToAssets(savingsShares);
        isPartial = savingsShares < requestShares;
    }

    function _mockTransferRevert(uint256 savingsShares, address recipient) internal {
        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(IERC20.transfer.selector, recipient, savingsShares),
            ""
        );
    }

    function testFuzz_processPendingDepositCancellations(uint256 maxSavingsShareValue, uint256 maxRequests) external {
        maxSavingsShareValue = _bound(maxSavingsShareValue, 0, 2 * vaultState.depositCancellationRequests.pendingShareValue);
        maxRequests          = _bound(maxRequests,          0, 2 * vaultState.depositCancellationRequests.length);

        uint256 maxSavingsShares = spUSDC.convertToShares(maxSavingsShareValue);

        uint256 savingsSharesWithdrawn;
        uint256 totalClaimable;

        for (uint256 i = 0; i < maxRequests; ++i) {
            if (i == 0) {
                ( uint256 savingsShares, uint256 assets, bool isPartial ) = _getMaxCancellableAmount(100_000e6, maxSavingsShares, savingsSharesWithdrawn);

                _mockTransferRevert(savingsShares, ali);

                aliBalances.claimableAssetsOf += assets;
                totalClaimable                += assets;
                savingsSharesWithdrawn        += savingsShares;

                if (isPartial) break;
            }

            if (i == 1) {
                ( uint256 savingsShares, uint256 assets, bool isPartial ) = _getMaxCancellableAmount(200_000e6, maxSavingsShares, savingsSharesWithdrawn);

                bobBalances.savingsShareValue += assets;
                savingsSharesWithdrawn += savingsShares;

                if (isPartial) break;
            }

            if (i == 2) {
                ( uint256 savingsShares, uint256 assets, bool isPartial ) = _getMaxCancellableAmount(300_000e6, maxSavingsShares, savingsSharesWithdrawn);

                camBalances.savingsShareValue += assets;
                savingsSharesWithdrawn += savingsShares;

                if (isPartial) break;
            }

            if (i == 3) {
                ( uint256 savingsShares, uint256 assets, bool isPartial ) = _getMaxCancellableAmount(400_000e6, maxSavingsShares, savingsSharesWithdrawn);

                _mockTransferRevert(savingsShares, dan);

                danBalances.claimableAssetsOf += assets;
                totalClaimable                += assets;
                savingsSharesWithdrawn        += savingsShares;

                if (isPartial) break;
            }

            if (i == 4) {
                ( uint256 savingsShares, uint256 assets, bool isPartial ) = _getMaxCancellableAmount(500_000e6, maxSavingsShares, savingsSharesWithdrawn);

                _mockTransferRevert(savingsShares, bob);

                bobBalances.claimableAssetsOf += assets;
                totalClaimable                += assets;
                savingsSharesWithdrawn        += savingsShares;

                if (isPartial) break;
            }

            if (i == 5) {
                ( uint256 savingsShares, uint256 assets, bool isPartial ) = _getMaxCancellableAmount(600_000e6, maxSavingsShares, savingsSharesWithdrawn);

                camBalances.savingsShareValue += assets;
                savingsSharesWithdrawn += savingsShares;

                if (isPartial) break;
            }

            if (i == 6) {
                ( uint256 savingsShares, uint256 assets, bool isPartial ) = _getMaxCancellableAmount(700_000e6, maxSavingsShares, savingsSharesWithdrawn);

                _mockTransferRevert(savingsShares, ali);

                aliBalances.claimableAssetsOf += assets;
                totalClaimable                += assets;
                savingsSharesWithdrawn        += savingsShares;

                if (isPartial) break;
            }

            if (i == 7) {
                ( uint256 savingsShares, uint256 assets, bool isPartial ) = _getMaxCancellableAmount(800_000e6, maxSavingsShares, savingsSharesWithdrawn);

                _mockTransferRevert(savingsShares, dan);

                danBalances.claimableAssetsOf += assets;
                totalClaimable                += assets;
                savingsSharesWithdrawn        += savingsShares;

                if (isPartial) break;
            }

            if (i == 8) {
                ( uint256 savingsShares, uint256 assets, bool isPartial ) = _getMaxCancellableAmount(900_000e6, maxSavingsShares, savingsSharesWithdrawn);

                camBalances.savingsShareValue += assets;
                savingsSharesWithdrawn += savingsShares;

                if (isPartial) break;
            }

            if (i == 9) {
                ( uint256 savingsShares, uint256 assets, bool isPartial ) = _getMaxCancellableAmount(1_000_000e6, maxSavingsShares, savingsSharesWithdrawn);

                aliBalances.savingsShareValue += assets;
                savingsSharesWithdrawn += savingsShares;

                if (isPartial) break;
            }
            --vaultState.depositCancellationRequests.length;
            ++vaultState.depositCancellationRequests.processedCount;

            if (vaultState.depositCancellationRequests.length == 0) break;
        }

        uint256 assetsWithdrawn = spUSDC.convertToAssets(savingsSharesWithdrawn);

        vaultState.totalClaimable                                += totalClaimable;
        vaultState.availableLiquidValue                          -= assetsWithdrawn;
        vaultState.depositCancellationRequests.pendingShareValue -= assetsWithdrawn;

        vaultBalances.savingsShareValue += totalClaimable;
        vaultBalances.savingsShareValue -= assetsWithdrawn;

        vm.prank(operator);
        spPrime.processPendingDepositCancellations(maxSavingsShares, maxRequests);

        _assertVaultState(10);
        _assertAccountBalances(aliBalances,   10);
        _assertAccountBalances(bobBalances,   10);
        _assertAccountBalances(camBalances,   10);
        _assertAccountBalances(danBalances,   10);
        _assertAccountBalances(vaultBalances, 10);
    }

}

contract ProcessPendingRedeemsTests is SparkPrimeVaultTests {

    address internal ali = makeAddr("ali");
    address internal bob = makeAddr("bob");
    address internal cam = makeAddr("cam");
    address internal dan = makeAddr("dan");

    AccountBalances internal aliBalances;
    AccountBalances internal bobBalances;
    AccountBalances internal camBalances;
    AccountBalances internal danBalances;
    AccountBalances internal vaultBalances;

    function setUp() public override {
        super.setUp();

        vm.label(ali, "ali");
        vm.label(bob, "bob");
        vm.label(cam, "cam");
        vm.label(dan, "dan");

        // All deposits will be filled instantly

        _requestDeposit(ali, 100_000e6 + 400_000e6 + 700_000e6 + 1_000_000e6);
        _requestDeposit(bob, 200_000e6 + 500_000e6 + 800_000e6);
        _requestDeposit(cam, 300_000e6 + 600_000e6 + 900_000e6);

        _requestRedeem(ali, ali, spPrime.convertReferenceValueToShares(100_000e6));  // Will fail
        _requestRedeem(bob, bob, spPrime.convertReferenceValueToShares(200_000e6));
        _requestRedeem(cam, cam, spPrime.convertReferenceValueToShares(300_000e6));
        _requestRedeem(ali, dan, spPrime.convertReferenceValueToShares(400_000e6));  // Will fail
        _requestRedeem(bob, bob, spPrime.convertReferenceValueToShares(500_000e6));  // Will fail
        _requestRedeem(cam, cam, spPrime.convertReferenceValueToShares(600_000e6));
        _requestRedeem(ali, ali, spPrime.convertReferenceValueToShares(700_000e6));  // Will fail
        _requestRedeem(bob, dan, spPrime.convertReferenceValueToShares(800_000e6));  // Will fail
        _requestRedeem(cam, cam, spPrime.convertReferenceValueToShares(900_000e6));
        _requestRedeem(ali, ali, spPrime.convertReferenceValueToShares(1_000_000e6));

        uint256 depositedAssets = 5_500_000e6;

        _take(spUSDC.convertToShares(800_000e6));  // 800k so the last redeem cannot be fully fulfilled

        vaultState.rho                     = vm.getBlockTimestamp();
        vaultState.chi                     = 1.049999999999999999961070145e27;
        vaultState.totalValue              = depositedAssets - 5;
        vaultState.availableCapacityValue -= depositedAssets - 5;
        vaultState.availableLiquidValue    = depositedAssets - 800_000e6 - 2;

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 0;
        vaultState.depositRequests.processedCount    = 3;

        vaultState.redeemRequests.pendingShareValue = depositedAssets - 6;
        vaultState.redeemRequests.length            = 10;
        vaultState.redeemRequests.processedCount    = 0;

        aliBalances = AccountBalances({
            account           : ali,
            assets            : 0,
            shareValue        : 1,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        bobBalances = AccountBalances({
            account           : bob,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        camBalances = AccountBalances({
            account           : cam,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        danBalances = AccountBalances({
            account           : dan,
            assets            : 0,
            shareValue        : 0,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : depositedAssets - 6,
            savingsShareValue : depositedAssets - 800_000e6 - 2,
            claimableAssetsOf : 0
        });

        _assertVaultState();

        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(danBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 3; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingDepositRequest(i);
        }

        _assertRedeemRequest(0, ali, ali, 100_000e6 - 1);
        _assertRedeemRequest(1, bob, bob, 200_000e6 - 1);
        _assertRedeemRequest(2, cam, cam, 300_000e6 - 1);
        _assertRedeemRequest(3, ali, dan, 400_000e6 - 1);
        _assertRedeemRequest(4, bob, bob, 500_000e6 - 1);
        _assertRedeemRequest(5, cam, cam, 600_000e6 - 1);
        _assertRedeemRequest(6, ali, ali, 700_000e6 - 1);
        _assertRedeemRequest(7, bob, dan, 800_000e6 - 1);
        _assertRedeemRequest(8, cam, cam, 900_000e6 - 1);
        _assertRedeemRequest(9, ali, ali, 1_000_000e6 - 2);
    }


    function _setupMockCallReverts() internal {
        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(IERC20.transfer.selector, ali, spUSDC.convertToShares(100_000e6) - 1),
            ""
        );

        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(IERC20.transfer.selector, dan, spUSDC.convertToShares(400_000e6) - 1),
            ""
        );

        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(IERC20.transfer.selector, bob, spUSDC.convertToShares(500_000e6) - 1),
            ""
        );

        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(IERC20.transfer.selector, ali, spUSDC.convertToShares(700_000e6) - 1),
            ""
        );

        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(IERC20.transfer.selector, dan, spUSDC.convertToShares(800_000e6) - 1),
            ""
        );
    }

    function test_processPendingRedeems_infiniteMaxShares_infiniteMaxRequests() external {
        _setupMockCallReverts();

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ProcessPendingRedeems(operator, type(uint256).max, type(uint256).max);

        // Redeem Request 0

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(100_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(ali, spUSDC.convertToShares(100_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(0, ali, ali, spPrime.convertReferenceValueToShares(100_000e6), spUSDC.convertToShares(100_000e6) - 1);

        // Redeem Request 1

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(200_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(1, bob, bob, spPrime.convertReferenceValueToShares(200_000e6), spUSDC.convertToShares(200_000e6) - 1);

        // Redeem Request 2

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(300_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(2, cam, cam, spPrime.convertReferenceValueToShares(300_000e6), spUSDC.convertToShares(300_000e6) - 1);

        // Redeem Request 3

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(400_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(dan, spUSDC.convertToShares(400_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(3, ali, dan, spPrime.convertReferenceValueToShares(400_000e6), spUSDC.convertToShares(400_000e6) - 1);

        // Redeem Request 4

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(500_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(bob, spUSDC.convertToShares(500_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(4, bob, bob, spPrime.convertReferenceValueToShares(500_000e6), spUSDC.convertToShares(500_000e6) - 1);

        // Redeem Request 5

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(600_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(5, cam, cam, spPrime.convertReferenceValueToShares(600_000e6), spUSDC.convertToShares(600_000e6) - 1);

        // Redeem Request 6

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(700_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(ali, spUSDC.convertToShares(700_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(6, ali, ali, spPrime.convertReferenceValueToShares(700_000e6), spUSDC.convertToShares(700_000e6) - 1);

        // Redeem Request 7

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(800_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(dan, spUSDC.convertToShares(800_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(7, bob, dan, spPrime.convertReferenceValueToShares(800_000e6), spUSDC.convertToShares(800_000e6) - 1);

        // Redeem Request 8

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(900_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(8, cam, cam, spPrime.convertReferenceValueToShares(900_000e6), spUSDC.convertToShares(900_000e6) - 1);

        // Redeem Request 9

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(200_000e6) + 11);  // Only ~200k of the last 1MM deposit

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(9, ali, ali, spPrime.convertReferenceValueToShares(200_000e6) + 11, spUSDC.convertToShares(200_000e6) + 10);

        vm.prank(operator);
        spPrime.processPendingRedeems(type(uint256).max, type(uint256).max);

        uint256 assetsRedeemed = 5_500_000e6 - 800_000e6;
        uint256 totalClaimable = 100_000e6 + 400_000e6 + 500_000e6 + 700_000e6 + 800_000e6;

        vaultState.totalValue              = 800_000e6 - 12;
        vaultState.totalClaimable         += totalClaimable - 9;
        vaultState.availableCapacityValue += assetsRedeemed + 7;
        vaultState.availableLiquidValue    = 2;

        vaultState.redeemRequests.pendingShareValue -= assetsRedeemed + 7;
        vaultState.redeemRequests.length             = 1;
        vaultState.redeemRequests.processedCount     = 9;

        aliBalances.savingsShareValue += 200_000e6 + 10;
        aliBalances.claimableAssetsOf += 100_000e6 + 700_000e6 - 4;

        bobBalances.savingsShareValue += 200_000e6 - 2;
        bobBalances.claimableAssetsOf += 500_000e6 - 2;

        camBalances.savingsShareValue += 300_000e6 + 600_000e6 + 900_000e6 - 6;

        danBalances.claimableAssetsOf += 400_000e6 + 800_000e6 - 3;

        vaultBalances.shareValue        -= assetsRedeemed + 7;
        vaultBalances.savingsShareValue  = vaultState.totalClaimable + 3;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(danBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 9; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingRedeemRequest(i);
        }

        _assertRedeemRequest(9, ali, ali, 800_000e6 - 13);  // Partial fill
    }

    function test_processPendingRedeems_infiniteMaxShares_limitedMaxRequests() external {
        _setupMockCallReverts();

        uint256 maxRequests = 6;

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ProcessPendingRedeems(operator, type(uint256).max, maxRequests);

        // Redeem Request 0

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(100_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(ali, spUSDC.convertToShares(100_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(0, ali, ali, spPrime.convertReferenceValueToShares(100_000e6), spUSDC.convertToShares(100_000e6) - 1);

        // Redeem Request 1

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(200_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(1, bob, bob, spPrime.convertReferenceValueToShares(200_000e6), spUSDC.convertToShares(200_000e6) - 1);

        // Redeem Request 2

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(300_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(2, cam, cam, spPrime.convertReferenceValueToShares(300_000e6), spUSDC.convertToShares(300_000e6) - 1);

        // Redeem Request 3

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(400_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(dan, spUSDC.convertToShares(400_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(3, ali, dan, spPrime.convertReferenceValueToShares(400_000e6), spUSDC.convertToShares(400_000e6) - 1);

        // Redeem Request 4

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(500_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(bob, spUSDC.convertToShares(500_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(4, bob, bob, spPrime.convertReferenceValueToShares(500_000e6), spUSDC.convertToShares(500_000e6) - 1);

        // Redeem Request 5

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(600_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(5, cam, cam, spPrime.convertReferenceValueToShares(600_000e6), spUSDC.convertToShares(600_000e6) - 1);

        vm.prank(operator);
        spPrime.processPendingRedeems(type(uint256).max, maxRequests);

        uint256 assetsRedeemed = 100_000e6 + 200_000e6 + 300_000e6 + 400_000e6 + 500_000e6 + 600_000e6;
        uint256 totalClaimable = 100_000e6 + 400_000e6 + 500_000e6;

        vaultState.totalValue             -= assetsRedeemed - 2;
        vaultState.totalClaimable         += totalClaimable - 5;
        vaultState.availableCapacityValue += assetsRedeemed - 2;
        vaultState.availableLiquidValue   -= assetsRedeemed - 9;

        vaultState.redeemRequests.pendingShareValue -= assetsRedeemed - 2;
        vaultState.redeemRequests.length             = 4;
        vaultState.redeemRequests.processedCount     = 6;

        aliBalances.claimableAssetsOf += 100_000e6 - 2;

        bobBalances.savingsShareValue += 200_000e6 - 2;
        bobBalances.claimableAssetsOf += 500_000e6 - 2;

        camBalances.savingsShareValue += 300_000e6 + 600_000e6 - 4;

        danBalances.claimableAssetsOf += 400_000e6 - 2;

        vaultBalances.shareValue        -= assetsRedeemed - 2;
        vaultBalances.savingsShareValue += totalClaimable - 5;
        vaultBalances.savingsShareValue -= assetsRedeemed - 9;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(danBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 6; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingRedeemRequest(i);
        }

        _assertRedeemRequest(6, ali, ali, 700_000e6 - 1);
        _assertRedeemRequest(7, bob, dan, 800_000e6 - 1);
        _assertRedeemRequest(8, cam, cam, 900_000e6 - 1);
        _assertRedeemRequest(9, ali, ali, 1_000_000e6 - 2);
    }

    function test_processPendingRedeems_limitedMaxShares_infiniteMaxRequests() external {
        _setupMockCallReverts();

        uint256 maxShares = spPrime.convertReferenceValueToShares(2_000_000e6);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ProcessPendingRedeems(operator, maxShares, type(uint256).max);

        // Redeem Request 0

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(100_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(ali, spUSDC.convertToShares(100_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(0, ali, ali, spPrime.convertReferenceValueToShares(100_000e6), spUSDC.convertToShares(100_000e6) - 1);

        // Redeem Request 1

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(200_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(1, bob, bob, spPrime.convertReferenceValueToShares(200_000e6), spUSDC.convertToShares(200_000e6) - 1);

        // Redeem Request 2

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(300_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(2, cam, cam, spPrime.convertReferenceValueToShares(300_000e6), spUSDC.convertToShares(300_000e6) - 1);

        // Redeem Request 3

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(400_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(dan, spUSDC.convertToShares(400_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(3, ali, dan, spPrime.convertReferenceValueToShares(400_000e6), spUSDC.convertToShares(400_000e6) - 1);

        // Redeem Request 4

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(500_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(bob, spUSDC.convertToShares(500_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(4, bob, bob, spPrime.convertReferenceValueToShares(500_000e6), spUSDC.convertToShares(500_000e6) - 1);

        // Redeem Request 5

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(500_000e6) + 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(5, cam, cam, spPrime.convertReferenceValueToShares(500_000e6) + 1, spUSDC.convertToShares(500_000e6));

        vm.prank(operator);
        spPrime.processPendingRedeems(maxShares, type(uint256).max);

        uint256 assetsRedeemed = 2_000_000e6;
        uint256 totalClaimable = 100_000e6 + 400_000e6 + 500_000e6;

        vaultState.totalValue             -= assetsRedeemed - 1;
        vaultState.totalClaimable         += totalClaimable - 5;
        vaultState.availableCapacityValue += assetsRedeemed - 1;
        vaultState.availableLiquidValue   -= assetsRedeemed - 8;

        vaultState.redeemRequests.pendingShareValue -= assetsRedeemed - 1;
        vaultState.redeemRequests.length             = 5;
        vaultState.redeemRequests.processedCount     = 5;

        aliBalances.claimableAssetsOf += 100_000e6 - 2;

        bobBalances.savingsShareValue += 200_000e6 - 2;
        bobBalances.claimableAssetsOf += 500_000e6 - 2;

        camBalances.savingsShareValue += 300_000e6 + 500_000e6 - 3;

        danBalances.claimableAssetsOf += 400_000e6 - 2;

        vaultBalances.shareValue        -= assetsRedeemed - 1;
        vaultBalances.savingsShareValue += totalClaimable - 4;
        vaultBalances.savingsShareValue -= assetsRedeemed - 8;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(danBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 5; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingRedeemRequest(i);
        }

        _assertRedeemRequest(5, cam, cam, 100_000e6 - 2);  // 500k out of 600k redeemed
        _assertRedeemRequest(6, ali, ali, 700_000e6 - 1);
        _assertRedeemRequest(7, bob, dan, 800_000e6 - 1);
        _assertRedeemRequest(8, cam, cam, 900_000e6 - 1);
        _assertRedeemRequest(9, ali, ali, 1_000_000e6 - 2);
    }

    function test_processPendingRedeems_multipleCalls() external {
        _setupMockCallReverts();

        uint256 maxShares = spPrime.convertReferenceValueToShares(2_000_000e6);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ProcessPendingRedeems(operator, maxShares, type(uint256).max);

        // Redeem Request 0

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(100_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(ali, spUSDC.convertToShares(100_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(0, ali, ali, spPrime.convertReferenceValueToShares(100_000e6), spUSDC.convertToShares(100_000e6) - 1);

        // Redeem Request 1

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(200_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(1, bob, bob, spPrime.convertReferenceValueToShares(200_000e6), spUSDC.convertToShares(200_000e6) - 1);

        // Redeem Request 2

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(300_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(2, cam, cam, spPrime.convertReferenceValueToShares(300_000e6), spUSDC.convertToShares(300_000e6) - 1);

        // Redeem Request 3

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(400_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(dan, spUSDC.convertToShares(400_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(3, ali, dan, spPrime.convertReferenceValueToShares(400_000e6), spUSDC.convertToShares(400_000e6) - 1);

        // Redeem Request 4

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(500_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(bob, spUSDC.convertToShares(500_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(4, bob, bob, spPrime.convertReferenceValueToShares(500_000e6), spUSDC.convertToShares(500_000e6) - 1);

        // Redeem Request 5 (Partial)

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(500_000e6) + 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(5, cam, cam, spPrime.convertReferenceValueToShares(500_000e6) + 1, spUSDC.convertToShares(500_000e6));  // Only 500k of the 600k is processed

        vm.prank(operator);
        spPrime.processPendingRedeems(maxShares, type(uint256).max);

        uint256 assetsRedeemed = 100_000e6 + 200_000e6 + 300_000e6 + 400_000e6 + 500_000e6 + 500_000e6;  // Only 500k of the last request is processed
        uint256 totalClaimable = 100_000e6 + 400_000e6 + 500_000e6;

        vaultState.totalValue             -= assetsRedeemed - 1;
        vaultState.totalClaimable         += totalClaimable - 5;
        vaultState.availableCapacityValue += assetsRedeemed - 1;
        vaultState.availableLiquidValue   -= assetsRedeemed - 8;

        vaultState.redeemRequests.pendingShareValue -= assetsRedeemed - 1;
        vaultState.redeemRequests.length             = 5;
        vaultState.redeemRequests.processedCount     = 5;

        aliBalances.claimableAssetsOf += 100_000e6 - 2;

        bobBalances.savingsShareValue += 200_000e6 - 2;
        bobBalances.claimableAssetsOf += 500_000e6 - 2;

        camBalances.savingsShareValue += 300_000e6 + 500_000e6 - 3;

        danBalances.claimableAssetsOf += 400_000e6 - 2;

        vaultBalances.shareValue        -= assetsRedeemed - 1;
        vaultBalances.savingsShareValue += totalClaimable - 4;
        vaultBalances.savingsShareValue -= assetsRedeemed - 8;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(danBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 5; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingRedeemRequest(i);
        }

        _assertRedeemRequest(5, cam, cam, 100_000e6 - 2);  // Partial fill
        _assertRedeemRequest(6, ali, ali, 700_000e6 - 1);
        _assertRedeemRequest(7, bob, dan, 800_000e6 - 1);
        _assertRedeemRequest(8, cam, cam, 900_000e6 - 1);
        _assertRedeemRequest(9, ali, ali, 1_000_000e6 - 2);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ProcessPendingRedeems(operator, type(uint256).max, type(uint256).max);

        // Redeem Request 5 (Remainder)

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(100_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(5, cam, cam, spPrime.convertReferenceValueToShares(100_000e6) - 1, spUSDC.convertToShares(100_000e6) - 2);

        // Redeem Request 6

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(700_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(ali, spUSDC.convertToShares(700_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(6, ali, ali, spPrime.convertReferenceValueToShares(700_000e6), spUSDC.convertToShares(700_000e6) - 1);

        // Redeem Request 7

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(800_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(dan, spUSDC.convertToShares(800_000e6) - 1);

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(7, bob, dan, spPrime.convertReferenceValueToShares(800_000e6), spUSDC.convertToShares(800_000e6) - 1);

        // Redeem Request 8

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(900_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(8, cam, cam, spPrime.convertReferenceValueToShares(900_000e6), spUSDC.convertToShares(900_000e6) - 1);

        // Redeem Request 9 (Partial)

        vm.expectEmit(address(spPrime));
        emit IERC20.Transfer(address(spPrime), address(0), spPrime.convertReferenceValueToShares(200_000e6) + 13);  // Only ~200k of the last 1MM deposit

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Redeem(9, ali, ali, spPrime.convertReferenceValueToShares(200_000e6) + 13, spUSDC.convertToShares(200_000e6) + 12);

        vm.prank(operator);
        spPrime.processPendingRedeems(type(uint256).max, type(uint256).max);

        assetsRedeemed = 100_000e6 + 700_000e6 + 800_000e6 + 900_000e6 + 200_000e6;  // Remaining ~100k of request 5, then only ~200k of the last 1MM deposit
        totalClaimable = 700_000e6 + 800_000e6;

        vaultState.totalValue              = 800_000e6 - 14;
        vaultState.totalClaimable         += totalClaimable - 4;
        vaultState.availableCapacityValue += assetsRedeemed + 10;
        vaultState.availableLiquidValue    = 2;

        vaultState.redeemRequests.pendingShareValue -= assetsRedeemed + 10;
        vaultState.redeemRequests.length             = 1;
        vaultState.redeemRequests.processedCount     = 9;

        aliBalances.savingsShareValue += 200_000e6 + 12;
        aliBalances.claimableAssetsOf += 700_000e6 - 2;

        camBalances.savingsShareValue += 100_000e6 + 900_000e6 - 5;

        danBalances.claimableAssetsOf += 800_000e6 - 1;

        vaultBalances.shareValue        -= assetsRedeemed + 10;
        vaultBalances.savingsShareValue  = vaultState.totalClaimable + 3;

        _assertVaultState();
        _assertAccountBalances(aliBalances);
        _assertAccountBalances(bobBalances);
        _assertAccountBalances(camBalances);
        _assertAccountBalances(danBalances);
        _assertAccountBalances(vaultBalances);

        for (uint256 i = 0; i < 9; i++) {
            vm.expectRevert(ISparkPrimeVault.InvalidRequestId.selector);
            spPrime.getPendingRedeemRequest(i);
        }

        _assertRedeemRequest(9, ali, ali, 800_000e6 - 15);  // Partial fill
    }

    function _getMaxRedeemableAmount(uint256 requestAmount, uint256 maxShares, uint256 sharesRedeemed)
        internal view returns (uint256 shares, uint256 assets, bool isPartial)
    {
        uint256 requestShares = spPrime.convertReferenceValueToShares(requestAmount);

        shares    = sharesRedeemed + requestShares > maxShares ? maxShares - sharesRedeemed : requestShares;
        isPartial = shares < requestShares;

        // USDC received by the recipient: savings shares are rounded down in the vault's favour.
        assets = spUSDC.convertToAssets(spUSDC.convertToShares(spPrime.convertSharesToReferenceValue(shares)));
    }

    function _mockTransferRevert(uint256 shares, address recipient) internal {
        uint256 savingsShares = spUSDC.convertToShares(spPrime.convertSharesToReferenceValue(shares));

        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(IERC20.transfer.selector, recipient, savingsShares),
            ""
        );
    }

    function testFuzz_processPendingRedeems(uint256 maxShareValue, uint256 maxRequests) external {
        maxShareValue = _bound(maxShareValue, 0, 2 * vaultState.redeemRequests.pendingShareValue);
        maxRequests   = _bound(maxRequests,   0, 2 * vaultState.redeemRequests.length);

        uint256 maxShares = spPrime.convertReferenceValueToShares(maxShareValue);

        uint256 sharesRedeemed;  // spPrime shares burned
        uint256 assetsRedeemed;  // USDC received by recipients (directly or as claimable)
        uint256 totalClaimable;

        for (uint256 i = 0; i < maxRequests; ++i) {
            if (i == 0) {
                ( uint256 shares, uint256 assets, bool isPartial ) = _getMaxRedeemableAmount(100_000e6, maxShares, sharesRedeemed);

                _mockTransferRevert(shares, ali);

                aliBalances.claimableAssetsOf += assets;
                totalClaimable                += assets;
                sharesRedeemed                += shares;
                assetsRedeemed                += assets;

                if (isPartial) break;
            }

            if (i == 1) {
                ( uint256 shares, uint256 assets, bool isPartial ) = _getMaxRedeemableAmount(200_000e6, maxShares, sharesRedeemed);

                bobBalances.savingsShareValue += assets;
                sharesRedeemed     += shares;
                assetsRedeemed     += assets;

                if (isPartial) break;
            }

            if (i == 2) {
                ( uint256 shares, uint256 assets, bool isPartial ) = _getMaxRedeemableAmount(300_000e6, maxShares, sharesRedeemed);

                camBalances.savingsShareValue += assets;
                sharesRedeemed     += shares;
                assetsRedeemed     += assets;

                if (isPartial) break;
            }

            if (i == 3) {
                ( uint256 shares, uint256 assets, bool isPartial ) = _getMaxRedeemableAmount(400_000e6, maxShares, sharesRedeemed);

                _mockTransferRevert(shares, dan);

                danBalances.claimableAssetsOf += assets;
                totalClaimable                += assets;
                sharesRedeemed                += shares;
                assetsRedeemed                += assets;

                if (isPartial) break;
            }

            if (i == 4) {
                ( uint256 shares, uint256 assets, bool isPartial ) = _getMaxRedeemableAmount(500_000e6, maxShares, sharesRedeemed);

                _mockTransferRevert(shares, bob);

                bobBalances.claimableAssetsOf += assets;
                totalClaimable                += assets;
                sharesRedeemed                += shares;
                assetsRedeemed                += assets;

                if (isPartial) break;
            }

            if (i == 5) {
                ( uint256 shares, uint256 assets, bool isPartial ) = _getMaxRedeemableAmount(600_000e6, maxShares, sharesRedeemed);

                camBalances.savingsShareValue += assets;
                sharesRedeemed     += shares;
                assetsRedeemed     += assets;

                if (isPartial) break;
            }

            if (i == 6) {
                ( uint256 shares, uint256 assets, bool isPartial ) = _getMaxRedeemableAmount(700_000e6, maxShares, sharesRedeemed);

                _mockTransferRevert(shares, ali);

                aliBalances.claimableAssetsOf += assets;
                totalClaimable                += assets;
                sharesRedeemed                += shares;
                assetsRedeemed                += assets;

                if (isPartial) break;
            }

            if (i == 7) {
                ( uint256 shares, uint256 assets, bool isPartial ) = _getMaxRedeemableAmount(800_000e6, maxShares, sharesRedeemed);

                _mockTransferRevert(shares, dan);

                danBalances.claimableAssetsOf += assets;
                totalClaimable                += assets;
                sharesRedeemed                += shares;
                assetsRedeemed                += assets;

                if (isPartial) break;
            }

            if (i == 8) {
                ( uint256 shares, uint256 assets, bool isPartial ) = _getMaxRedeemableAmount(900_000e6, maxShares, sharesRedeemed);

                camBalances.savingsShareValue += assets;
                sharesRedeemed     += shares;
                assetsRedeemed     += assets;

                if (isPartial) break;
            }
            if (i == 9) {
                // Only the last request can run into the vault's liquid assets (800k was taken in
                // `setUp`), so it can never be entirely fulfilled.
                uint256 liquidShares = sharesRedeemed + spPrime.convertReferenceValueToShares(vaultState.availableLiquidValue  - assetsRedeemed);
                uint256 fillable     = maxShares < liquidShares ? maxShares : liquidShares;

                ( uint256 shares, uint256 assets, ) = _getMaxRedeemableAmount(1_000_000e6, fillable, sharesRedeemed);

                aliBalances.savingsShareValue += assets;
                sharesRedeemed     += shares;
                assetsRedeemed     += assets;

                break;
            }

            --vaultState.redeemRequests.length;
            ++vaultState.redeemRequests.processedCount;

            if (vaultState.redeemRequests.length == 0) break;
        }

        uint256 shareValueRedeemed = spPrime.convertSharesToReferenceValue(sharesRedeemed);

        vaultState.totalValue                       -= shareValueRedeemed;
        vaultState.totalClaimable                   += totalClaimable;
        vaultState.availableCapacityValue           += shareValueRedeemed;
        vaultState.availableLiquidValue             -= assetsRedeemed;
        vaultState.redeemRequests.pendingShareValue -= shareValueRedeemed;

        vaultBalances.shareValue        -= shareValueRedeemed;
        vaultBalances.savingsShareValue += totalClaimable;
        vaultBalances.savingsShareValue -= assetsRedeemed;

        vm.prank(operator);
        spPrime.processPendingRedeems(maxShares, maxRequests);

        _assertVaultState(10);
        _assertAccountBalances(aliBalances,   10);
        _assertAccountBalances(bobBalances,   10);
        _assertAccountBalances(camBalances,   10);
        _assertAccountBalances(danBalances,   10);
        _assertAccountBalances(vaultBalances, 10);
    }


    function test_processPendingRedeems_zeroPayoutTransferFails() external {
        // One vault share is worth less than one asset unit, so it pays out zero.
        assertEq(spPrime.convertToAssets(1), 0);

        // A token that rejects zero transfers does not block the queue.
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

}
