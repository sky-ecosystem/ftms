// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Initializable } from "../lib/oz/contracts/proxy/utils/Initializable.sol";

import { ERC1967Proxy, TestBase, FTMS } from "./TestBase.t.sol";

import { IFTMS } from "../src/IFTMS.sol";

import { FTMS } from "../src/FTMS.sol";

contract InitializeTests is TestBase {

    address internal deployer = makeAddr("deployer");

    FTMS internal implementation;

    function setUp() public override virtual {
        super.setUp();

        vm.prank(deployer);
        implementation = new FTMS();
    }

    function _deploy(uint256 minDeposit, uint256 minDepositCancellation, uint256 minRedeem)
        internal
        returns (IFTMS)
    {
        vm.prank(deployer);

        return FTMS(
            address(new ERC1967Proxy(
                address(implementation),
                abi.encodeCall(
                    IFTMS.initialize,
                    (
                        address(spUSDC),
                        address(spUSDC),
                        true,
                        "FTMS USDC",
                        "ftmsUSDC",
                        admin,
                        minDeposit,
                        minDepositCancellation,
                        minRedeem
                    )
                )
            ))
        );
    }

    /**********************************************************************************************/
    /*** initialize                                                                             ***/
    /**********************************************************************************************/

    function test_initialize_zeroMinDeposit() external {
        vm.expectRevert(IFTMS.ZeroMinDeposit.selector);
        _deploy(0, 0, 0);
    }

    function test_initialize_zeroMinDepositCancellation() external {
        vm.expectRevert(IFTMS.ZeroMinDepositCancellation.selector);
        _deploy(1, 0, 0);
    }

    function test_initialize_zeroMinRedeem() external {
        vm.expectRevert(IFTMS.ZeroMinRedeem.selector);
        _deploy(1, 1, 0);
    }

    function test_initialize_alreadyInitialized() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        spPrime.initialize(address(spUSDC), address(spUSDC), true, "FTMS USDC", "ftmsUSDC", admin, 1, 1, 1);
    }

    function test_initialize_implementationDisabled() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(spUSDC), address(spUSDC), true, "FTMS USDC", "ftmsUSDC", admin, 1, 1, 1);
    }

    function test_initialize() external {
        address expectedProxy = vm.computeCreateAddress(deployer, vm.getNonce(deployer));

        vm.expectEmit(expectedProxy);
        emit IFTMS.Drip(uint192(RAY), 0);

        vm.expectEmit(expectedProxy);
        emit IFTMS.VSRSet(expectedProxy, RAY);

        vm.expectEmit(expectedProxy);
        emit IFTMS.VSRBoundsSet(expectedProxy, RAY, RAY);

        vm.expectEmit(expectedProxy);
        emit IFTMS.MinDepositSet(deployer, MINIMUM_DEPOSIT);

        vm.expectEmit(expectedProxy);
        emit IFTMS.MinDepositCancellationSet(deployer, MINIMUM_DEPOSIT_CANCELLATION);

        vm.expectEmit(expectedProxy);
        emit IFTMS.MinRedeemSet(deployer, MINIMUM_REDEEM);

        IFTMS vault = _deploy(MINIMUM_DEPOSIT, MINIMUM_DEPOSIT_CANCELLATION, MINIMUM_REDEEM);

        assertEq(address(vault), expectedProxy);

        assertEq(vault.asset(),           address(spUSDC));
        assertEq(vault.referenceOracle(), address(spUSDC));
        assertEq(vault.instantFill(),     true);
        assertEq(vault.name(),            "FTMS USDC");
        assertEq(vault.symbol(),          "ftmsUSDC");
        assertEq(vault.decimals(),        6);

        assertTrue(vault.hasRole(DEFAULT_ADMIN_ROLE, admin));

        assertEq(vault.chi(),    RAY);
        assertEq(vault.rho(),    vm.getBlockTimestamp());
        assertEq(vault.vsr(),    RAY);
        assertEq(vault.minVSR(), RAY);
        assertEq(vault.maxVSR(), RAY);

        assertEq(vault.minDeposit(),             MINIMUM_DEPOSIT);
        assertEq(vault.minDepositCancellation(), MINIMUM_DEPOSIT_CANCELLATION);
        assertEq(vault.minRedeem(),              MINIMUM_REDEEM);
    }

}
