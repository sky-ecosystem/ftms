// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

// A reference oracle with a settable price, shaped like an ERC-4626 vault whose shares are the
// asset (e.g. spUSDC): both conversions use the same price and round down.
contract MockReferenceOracle {

    uint256 public constant RAY = 1e27;

    uint256 public price = RAY;  // Reference value of one asset unit [ray]

    function setPrice(uint256 price_) external {
        require(price_ != 0, "MockReferenceOracle/zero-price");
        price = price_;
    }

    // Assets to reference value.
    function convertToAssets(uint256 shares_) external view returns (uint256) {
        return shares_ * price / RAY;
    }

    // Reference value to assets.
    function convertToShares(uint256 assets_) external view returns (uint256) {
        return assets_ * RAY / price;
    }

}
