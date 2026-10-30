# SUAN Agent Launchpad — contracts

Smart contracts of the [SUAN Agent Launchpad](https://launch.suan.bid), the token launchpad for AI agents on BNB Chain.
Every token trades from its first block in one locked PancakeSwap Infinity pool. Wallets with a **.ai Agent ID** buy
first and pay a lower tax. Every fee is paid in BNB.

## Fees

| Fee | Rate | Goes to |
|---|---|---|
| Trading fee | 1% of every trade | 0.5% buys back and burns $SUAN, 0.5% to the creator |
| Launch fee | 0.005 BNB per launch | 100% buys back and burns $SUAN |
| Token tax | set by the creator; .ai wallets pay the lower .ai rate | split by the creator's weights: creator, holders, burn of the token, platform treasury |
| Extra 3% for wallets without .ai (tax period only) | 3% | buys back and burns the token itself |

Platform fees: 100% buy back and burn $SUAN, through `SuanBuyBurn`, which has no withdrawal function.

## BSC mainnet

| Contract | Address |
|---|---|
| AgentLaunchFactory | [`0x888A32aCE40DFBc99A00c1Dcbaf3515291845aeE`](https://bscscan.com/address/0x888A32aCE40DFBc99A00c1Dcbaf3515291845aeE#code) |
| AgentCurveHook | [`0xa8E32E5Bc1d3Ce8aFe6bf3ef2069F1Fc7171c061`](https://bscscan.com/address/0xa8E32E5Bc1d3Ce8aFe6bf3ef2069F1Fc7171c061#code) |
| AgentRouter | [`0x119dCa55DCbB37998E9bA0845196acc0FFf2FAc2`](https://bscscan.com/address/0x119dCa55DCbB37998E9bA0845196acc0FFf2FAc2#code) |
| SuanBuyBurn | [`0xF611041e441CD2037d415cB368d8cB45F31E134A`](https://bscscan.com/address/0xF611041e441CD2037d415cB368d8cB45F31E134A#code) |

### Stock memes (launches paired with a bStock)

| Contract | Address |
|---|---|
| StockLaunchFactory | [`0x55e1c1914D5e11a37Cd10deDF327E56F04ba979C`](https://bscscan.com/address/0x55e1c1914D5e11a37Cd10deDF327E56F04ba979C#code) |
| StockCurveHook | [`0x6ddE8C213f0fA67cDB9546bB0de5ef595185c196`](https://bscscan.com/address/0x6ddE8C213f0fA67cDB9546bB0de5ef595185c196#code) |
| StockRouter | [`0xCFA7D82BfB4Ed21aDaCFC36287b7031264ec9314`](https://bscscan.com/address/0xCFA7D82BfB4Ed21aDaCFC36287b7031264ec9314#code) |
| StockFeeSink | [`0xE9529df8577b37b6Fb6532A61343cAe2925Cb5f2`](https://bscscan.com/address/0xE9529df8577b37b6Fb6532A61343cAe2925Cb5f2#code) |
| StockTokenDeployer | [`0x1247FdBC154309e34B6d2edf45B7bC79511d2cA9`](https://bscscan.com/address/0x1247FdBC154309e34B6d2edf45B7bC79511d2cA9#code) |

A stock meme trades against a bStock (a tokenized US share on BSC) instead of BNB, with the same .ai rules. Every fee
is taken in the bStock: the creator's 0.5% and holder rewards are paid in the bStock; the platform's 0.5% goes to
`StockFeeSink`, which converts it to BNB on PancakeSwap V3 and sends it to `SuanBuyBurn` (fixed router, no
withdrawal). First allowed bases: NVDAB, SPCXB, BNCB, TSLAB, QQQB, SKHYB, AAPLB, CRCLB.

All contracts above are verified on BscScan. Only trust addresses published on launch.suan.bid and the official X account
[@SUANdotBID](https://x.com/SUANdotBID).

### Fair Mint (.ai Agent ID only)

Anyone creates a mint that only `.ai` Agent ID holders can join. Funds stay in the sale contract: if the target is met
the sale opens a PancakeSwap V2 pool at the last share's price and sends the LP to the dead address; if not, everyone
takes back exactly what they paid. Rules are fixed at creation; sales have no owner and no withdrawal.

| Contract | Address |
|---|---|
| FairMintFactory | [`0xb9b7d9384F22512C7A5E657fF9FF804D89Cf3b64`](https://bscscan.com/address/0xb9b7d9384F22512C7A5E657fF9FF804D89Cf3b64#code) |
| FairMintSale (implementation; each sale is a clone) | [`0xC13c13f0510E127927936f3E9FDa71B3B406a898`](https://bscscan.com/address/0xC13c13f0510E127927936f3E9FDa71B3B406a898#code) |
| SuanV2Router | [`0x9FD3887A0e0910f905Ad6F2E637cB514d5f9Eb7f`](https://bscscan.com/address/0x9FD3887A0e0910f905Ad6F2E637cB514d5f9Eb7f#code) |
| FairMintTaxSink | [`0xD2DAf18d6868e612344986Fc65F10be5915606E2`](https://bscscan.com/address/0xD2DAf18d6868e612344986Fc65F10be5915606E2#code) |

| Fee | Rate | Goes to |
|---|---|---|
| Creation fee | 0.01 BNB | buys back $SUAN |
| Creator bond | 0.05 BNB | returned on launch; buys back $SUAN if the target is missed |
| Launch fee | 2% of the BNB raised (none on a failed sale) | buys back $SUAN |
| Router fee | 1% of trades through SuanV2Router | buys back $SUAN |
| Token tax (optional) | 0–5% buy / sell, lower .ai rates allowed, fixed at creation | 10% buys back $SUAN; the rest is burned or paid to the creator as set |

## Layout

| Path | Contents |
|---|---|
| `src/AgentCurveHook.sol` | PancakeSwap Infinity hook: fees, .ai window, hold cap, buybacks, payouts |
| `src/AgentLaunchFactory.sol` | Launches: token, pool, locked liquidity, launch fee |
| `src/AgentToken.sol` | Token with the .ai-window and 1% hold-cap rules |
| `src/HolderRewards.sol`, `src/AgentRouter.sol` | Holder rewards, buy/sell router |
| `src/SuanBuyBurn.sol` | Receives platform fees and buys and burns $SUAN through the Flap Portal |
| `script/Deploy.s.sol` | Deployment |
| `src/Stock*.sol`, `script/DeployStock.s.sol`, `script/StockBase.s.sol` | Stock memes: hook, factory, router, fee sink, token; deployment; allowlist a bStock |
| `src/fairmint/`, `script/fairmint/DeployFairMint.s.sol`, `test/fairmint/` | Fair Mint: factory, sale, token, router, tax sink; deployment; fork tests |

## Build and test

```bash
git clone --recurse-submodules https://github.com/suan-launchpad/contracts
cd contracts
forge build
forge test   # forks BSC mainnet; set BSC_RPC_URL to use your own node
```

The contracts have not been audited. Use at your own risk.
