// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { IERC20 } from "../lib/oz/contracts/token/ERC20/IERC20.sol";

import { TestBase } from "./TestBase.t.sol";

import { ISparkPrimeVault } from "../src/ISparkPrimeVault.sol";

contract ClaimTests is TestBase {

    address internal user = makeAddr("user");

    function setUp() public override virtual {
        super.setUp();

        vm.label(user, "user");
    }

    function test_claim_nothingToClaim() external {
        vm.expectRevert(ISparkPrimeVault.NothingToClaim.selector);
        spPrime.claim(user);
    }

    function test_claim_transferAmountExceedsBalanceBoundary() external {
        _setCapacity(0);
        _requestDeposit(user, 1_000_000e6);
        _requestDepositCancellation(user, 0, spUSDC.convertToShares(1_000_000e6));

        // Transferring to the recipient fails, so savings shares are kept in the vault as claimable
        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(IERC20.transfer.selector, user, spUSDC.convertToShares(1_000_000e6)),
            ""
        );

        _processPendingDepositCancellations(1);

        vm.clearMockedCalls();

        // spPrime has 1 less than claimable amount
        deal(address(spUSDC), address(spPrime), spUSDC.convertToShares(1_000_000e6) - 1);

        vm.expectRevert("SparkVault/insufficient-balance");
        spPrime.claim(user);

        // spPrime has the full claimable amount
        deal(address(spUSDC), address(spPrime), spUSDC.convertToShares(1_000_000e6));

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Claim(user, spUSDC.convertToShares(1_000_000e6));

        spPrime.claim(user);
    }

    function test_claim_transferFails() external {
        _setCapacity(0);
        _requestDeposit(user, 1_000_000e6);
        _requestDepositCancellation(user, 0, spUSDC.convertToShares(1_000_000e6));

        // Transferring to the recipient fails, so savings shares are kept in the vault as claimable
        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(IERC20.transfer.selector, user, spUSDC.convertToShares(1_000_000e6)),
            ""
        );

        _processPendingDepositCancellations(1);

        // Recipient is still unable to receive the savings shares (the mock is still active)

        vm.expectRevert(bytes(""));
        spPrime.claim(user);
    }

    function test_claim_fromDepositCancellation() external {
        _setCapacity(0);
        _requestDeposit(user, 1_000_000e6);
        _requestDepositCancellation(user, 0, spUSDC.convertToShares(1_000_000e6));

        vaultState.availableCapacityValue  = 0;
        vaultState.availableLiquidValue   += 1_000_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 1;
        vaultState.depositRequests.processedCount    = 0;

        vaultState.depositCancellationRequests.pendingShareValue = 1_000_000e6 - 1;
        vaultState.depositCancellationRequests.length            = 1;
        vaultState.depositCancellationRequests.processedCount    = 0;

        AccountBalances memory userBalances = AccountBalances({
            account           : user,
            assets            : 0,
            shareValue        : 0,
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

        // Transferring to the recipient fails, so savings shares are kept in the vault as claimable
        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(IERC20.transfer.selector, user, spUSDC.convertToShares(1_000_000e6)),
            ""
        );

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(user, spUSDC.convertToShares(1_000_000e6));

        _processPendingDepositCancellations(1);

        vaultState.totalClaimable        += 1_000_000e6 - 1;
        vaultState.availableLiquidValue  -= 1_000_000e6 - 1;

        vaultState.depositCancellationRequests.pendingShareValue = 0;
        vaultState.depositCancellationRequests.length            = 0;
        vaultState.depositCancellationRequests.processedCount    = 1;

        userBalances.claimableAssetsOf = 1_000_000e6 - 1;

        vaultBalances.savingsShareValue = 1_000_000e6 - 1;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // User claims their assets

        vm.clearMockedCalls();

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Claim(user, spUSDC.convertToShares(1_000_000e6));

        spPrime.claim(user);

        vaultState.totalClaimable = 0;

        userBalances.savingsShareValue = 1_000_000e6 - 1;
        userBalances.claimableAssetsOf = 0;

        vaultBalances.savingsShareValue = 0;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
    }

    function test_claim_fromRedeem() external {
        _requestDeposit(user, 1_000_000e6);
        _requestRedeem(user,  spPrime.convertReferenceValueToShares(500_000e6));

        vaultState.availableCapacityValue -= 1_000_000e6 - 1;
        vaultState.availableLiquidValue   += 1_000_000e6 - 1;
        vaultState.totalValue             += 1_000_000e6 - 1;

        vaultState.depositRequests.pendingShareValue = 0;
        vaultState.depositRequests.length            = 0;
        vaultState.depositRequests.processedCount    = 1;

        vaultState.redeemRequests.pendingShareValue = 500_000e6;
        vaultState.redeemRequests.length            = 1;
        vaultState.redeemRequests.processedCount    = 0;

        AccountBalances memory userBalances = AccountBalances({
            account           : user,
            assets            : 0,
            shareValue        : 500_000e6 - 1,
            savingsShareValue : 0,
            claimableAssetsOf : 0
        });

        AccountBalances memory vaultBalances = AccountBalances({
            account           : address(spPrime),
            assets            : 0,
            shareValue        : 500_000e6,
            savingsShareValue : 1_000_000e6 - 1,
            claimableAssetsOf : 0
        });

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);

        // Transferring to the recipient fails, so savings shares are kept in the vault as claimable
        vm.mockCallRevert(
            address(spUSDC),
            abi.encodeWithSelector(IERC20.transfer.selector, user, spUSDC.convertToShares(500_000e6)),
            ""
        );

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.ClaimableAssetsIncreased(user, spUSDC.convertToShares(500_000e6));

        _processPendingRedeems(1);

        vaultState.availableCapacityValue += 500_000e6;
        vaultState.availableLiquidValue   -= 500_000e6;
        vaultState.totalValue             -= 500_000e6;
        vaultState.totalClaimable         += 500_000e6 - 1;

        vaultState.redeemRequests.pendingShareValue = 0;
        vaultState.redeemRequests.length            = 0;
        vaultState.redeemRequests.processedCount    = 1;

        userBalances.claimableAssetsOf = 500_000e6 - 1;

        vaultBalances.shareValue        = 0;
        vaultBalances.savingsShareValue = 1_000_000e6 - 1;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
        // User claims their assets

        vm.clearMockedCalls();

        vm.expectEmit(address(spPrime));
        emit ISparkPrimeVault.Claim(user, spUSDC.convertToShares(500_000e6));

        spPrime.claim(user);

        vaultState.totalClaimable = 0;

        userBalances.savingsShareValue = 500_000e6 - 1;
        userBalances.claimableAssetsOf = 0;

        vaultBalances.savingsShareValue = 500_000e6 - 1;

        _assertVaultState();
        _assertAccountBalances(userBalances);
        _assertAccountBalances(vaultBalances);
    }

}
