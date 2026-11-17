# FTMS: First-To-Market System for halo vaults

Based on Spark's [Spark Prime Vault (`spPRIME`)](https://github.com/sparkdotfi/spark-prime-vault) at commit `a1b60c3`.

A vault that issues an ERC-20 share token whose value grows at a rate set by an operator. Deposits and redemptions go through first-in, first-out queues, so they can wait when the vault is at capacity or doesn't hold enough of the deposited token. The vault contract is upgradeable (UUPS).

Users deposit a token, the vault's `asset`, and get vault shares in return. An account with `TAKER_ROLE` can take the deposited tokens out of the vault to deploy them elsewhere, and return them later. Redemptions are paid in the same token, from what the vault holds.

Each share's value grows at the Vault Savings Rate (VSR), a per-second compounding rate that `OPERATOR_ROLE` sets within bounds fixed by the admin. The VSR accrues in a *reference unit*, which may differ from the asset. A `referenceOracle` converts asset amounts to and from that unit:

- **Reference oracle set.** For example, the asset is `spUSDC` and the oracle is `spUSDC` itself. `spUSDC` is an ERC-4626 savings vault whose shares grow in value against USDC. The reference unit is then USDC. Each share is worth a USDC amount that grows at the VSR, and a redemption pays that amount in spUSDC at spUSDC's current price. spUSDC's own yield is therefore part of the VSR, not added on top of it.
- **No reference oracle** (`address(0)`). The reference unit is the asset itself, so each share is worth an amount of the asset that grows at the VSR. If the asset earns yield on its own (e.g. `spUSDC`), holders get that yield plus the VSR. With plain USDC as the asset, the VSR is simply a USDC rate.

Shares grow at the VSR whether or not the deployed capital earns it.

`spPRIME` takes USDC and deposits it into a savings vault (`spUSDC`) itself. This vault never deposits into another vault. Setting `asset = spUSDC` and `referenceOracle = spUSDC` gives a setup similar to `spPRIME`, except that users deposit and receive `spUSDC` rather than USDC. Behaviour not described below is the same as in `spPRIME`.

## Differences from `spPRIME`

- **One token in and out.** Users deposit and receive `asset`. The vault never deposits into, or redeems from, another vault.
- **Reference oracle.** Share value and the VSR accrue in the reference unit. `referenceOracle`, set once at initialization, converts between asset amounts and reference values.
- **Units.**
  - Amounts users pass in or receive, and the minimum deposit and cancellation amounts, are in asset units. So are the ERC-4626-style views such as `convertToAssets` and `totalAssets`.
  - Each of those views has a reference-value counterpart, e.g. `totalReferenceValue`.
  - `impair` takes a reference value.
  - Events report asset amounts. Where `spPRIME`'s events reported both a USDC and an spUSDC amount, these report only the asset amount. The exception is `Deposit`, which also reports the reference value used to price the new shares.
- **Names.** Names that referred to the savings vault (e.g. `pendingDepositSavingsShares`) are renamed to refer to the asset (e.g. `pendingDepositAssets`).

## Mechanics

Queues, capacity, the redeem fee, pausing, roles and configuration work as in `spPRIME`. In outline:

- **Share value.** A share's reference value grows at the VSR. Its asset value is that reference value converted through the oracle at the current rate.
- **Deposits.** Users queue an amount of the asset. When the request is filled, the amount is converted to shares at its reference value at that time. A request is filled immediately if nothing is queued ahead of it and there is capacity. Until then, the depositor can cancel and get the same number of tokens back.
- **Redemptions.** Users queue shares, and a redeem fee is burned from them upfront. When the request is filled, they receive the shares' asset value, rounded down.
- **Capital.** The taker can take any of the asset the vault holds, including tokens backing pending deposits and cancellations, but not what the vault owes to claimants. It returns capital by transferring the asset back. Redemptions and cancellation payouts wait until there is enough.
- **Failed payouts.** A payout that can't be delivered is credited to its recipient as claimable, and paid out later with `claim`.
- **Losses.** While the vault is paused, the loss manager can lower the total reference value of all shares by a given amount with `impair`.

## Asset and oracle requirements

**Asset**

- Any standard ERC-20 token, including ones whose `transfer` returns no value (like USDT). Fee-on-transfer and rebasing tokens are not supported.

**Reference oracle** (if set)

- **Its price must not be manipulable,** since deposits and redemptions are priced with it.
- **Both conversions use the same price and round down,** as the ERC-4626 standard requires. Otherwise a payout could exceed what the vault holds and break its accounting.
- **Its shares and assets have the same decimals** (like spUSDC and USDC, both 6).
- **It must not revert.** If it does, deposits and redemptions can't be processed. Deposit cancellations still work.

If the asset loses value against the reference unit, share values don't change, so redemptions pay out more of the asset than was deposited, unless the loss is passed to holders with `impair`.

## TODO

- Rename `SparkPrimeVault` and `ISparkPrimeVault`, kept for now to keep the diff against `spPRIME` small.
