# FTMS: First-To-Market System for halo vaults

A generic FIFO deposit/redeem mechanism any prime can use for a yieldcoin.

The FTMS vault implementation is identical to spPRIME's and lives outside this repo: it is imported unchanged from Spark's [`spark-prime-vault`](https://github.com/sparkdotfi/spark-prime-vault). This repo only adds `PassthroughVault` and tests.

## Sleeve requirements

Because of the spPRIME implementation, the vault immediately deposits users' tokens into an ERC-4626 vault (the sleeve) and holds its shares. The token users deposit and redeem is the sleeve's `asset()`, so it is chosen by choosing the sleeve. That implementation requires the sleeve to:

1. Be strictly ERC-4626 compliant, in particular:
   - `maxRedeem`/`maxWithdraw` never overstate what `redeem` pays.
   - `redeem` pays out in the same call (no cooldown or async claim).
2. Accept deposits from the vault (no allowlist). A sleeve deposit cap is fine, but new deposits revert while it is full.
3. Charge no deposit or withdrawal fee.
4. Not revert on `redeem(0)`. Queue remainders worth less than one sleeve share produce zero redeems, and a revert there blocks the redeem queue until an upgrade.

A falling sleeve share price doesn't break the vault, but it isn't passed through either: the Loss Manager has to pause and `impair`.

`take` hands sleeve shares to the taker. To return capital, the taker deposits the token into the sleeve with the vault as receiver (`sleeve.deposit(assets, vault)`): only sleeve shares count as liquidity, so the user token sent straight to the vault is stranded.

## Sky tokens

| User token | Sleeve | Queued funds earn | Works |
| --- | --- | --- | --- |
| USDC | `PassthroughVault(USDC)` | nothing | yes |
| USDS | `PassthroughVault(USDS)` | nothing | yes |
| USDS | sUSDS | SSR | yes |
| USDC | spUSDC | spUSDC rate | yes (spPRIME's sleeve) |
| USDS | stUSDS | stUSDS rate | **no**: `redeem(0)` reverts (`StUsds/assets-zero`) |

## PassthroughVault

A 1:1 ERC-4626 wrapper so the vault can run on a plain token. No fees, admin or upgradeability; zero amounts succeed; donations don't move the price.

## Tests

`test/Ftms-integration.t.sol` runs the full scenarios on the passthrough and sUSDS sleeves, and only checks the `redeem(0)` revert on stUSDS. spUSDC is covered by Spark's own tests.

```sh
git submodule update --init --recursive
ETH_RPC_URL=<mainnet rpc> forge test
```
