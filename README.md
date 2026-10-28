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

All four are verified on BscScan. Only trust addresses published on launch.suan.bid and the official X account
[@SUANdotBID](https://x.com/SUANdotBID).

## Layout

| Path | Contents |
|---|---|
| `src/AgentCurveHook.sol` | PancakeSwap Infinity hook: fees, .ai window, hold cap, buybacks, payouts |
| `src/AgentLaunchFactory.sol` | Launches: token, pool, locked liquidity, launch fee |
| `src/AgentToken.sol` | Token with the .ai-window and 1% hold-cap rules |
| `src/HolderRewards.sol`, `src/AgentRouter.sol` | Holder rewards, buy/sell router |
| `src/SuanBuyBurn.sol` | Receives platform fees and buys and burns $SUAN through the Flap Portal |
| `script/Deploy.s.sol` | Deployment |

## Build and test

```bash
git clone --recurse-submodules https://github.com/suan-launchpad/contracts
cd contracts
forge build
forge test   # forks BSC mainnet; set BSC_RPC_URL to use your own node
```

The contracts have not been audited. Use at your own risk.
