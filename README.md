# Hamster Hour (HAMSTER)

An immutable ERC-20 that mints its entire supply once, to the immediate deployer in its constructor.

| Parameter | Value |
| --- | --- |
| Solidity contract | `HamsterHour` in `src/HamsterHour.sol` |
| Token name | `Hamster Hour` |
| Symbol | `HAMSTER` |
| Decimals | `18` |
| Whole-token supply | `1,000,000,000` |
| Supply in smallest units | `1000000000000000000000000000` (`10^27`) |
| Named supply constant | `INITIAL_SUPPLY` |
| Constructor arguments | None (`[]`) |
| Deployment ETH value | `0` |
| Intended launch chain | Ethereum, chain ID `1` |
| Compiler / EVM target | Solidity `0.8.26` / Cancun |
| Optimizer | Enabled, 200 runs |
| Metadata bytecode hash | `none` |

## Behavior and assumptions

The token uses the unmodified OpenZeppelin Contracts v5.0.2 ERC-20 implementation, with a single `_mint(msg.sender, INITIAL_SUPPLY)` in the constructor. It exposes standard metadata, balances, transfers and allowances. Successful transfers return `true` and deliver exactly the specified amount. Invalid calls revert with ERC-6093 custom errors. Transfers and explicit approvals emit the standard events; minting emits a `Transfer` from the zero address.

There are no fees, taxes, burns, rebases, transfer restrictions, owners, privileged roles, pause switches, external mint functions, upgrades, or external calls. Supply cannot increase or decrease after deployment. No router, oracle, recipient, signer, RPC, or other external address is needed by the contract. The only supply recipient at construction is its immediate creator, including when that creator is a contract.

Zero-value transfers between nonzero addresses are allowed and emit `Transfer`; self-transfers preserve balances. Transfers to the zero address and approvals to the zero spender revert. Finite allowances decrease on `transferFrom`; `type(uint256).max` is treated as an unlimited allowance and stays unchanged. `transferFrom` does not emit an additional `Approval` event in this implementation, so integrations should query `allowance` for current values. Approving a spender replaces its previous allowance and does not transfer tokens. Calling `transferFrom` requires an allowance even when the caller is the token holder.

## Build and check

Run from the repository root with Foundry and Solidity 0.8.26 installed:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x0f38adb730fa06a3176893c985c819f0501020d6012dc22ab5549741397747ef forge test
forge fmt --check
```

All Solidity dependencies and their licenses are ordinary files under `lib/`. The build needs no downloads once the pinned compiler is available. No environment variables, forks, RPC access, FFI, or filesystem cheatcodes are required by the tests. The seed above controls Foundry's test runner; tests themselves do not read or modify the environment. Dependency origins and checksums are in `DEPENDENCIES.md` and `DEPENDENCIES.sha256`.

The tests cover metadata, the mint event, full allocation to a CREATE2 factory, exact transfers, full-balance/zero/self transfers, approval replacement/revocation, finite and unlimited allowances, invalid and unauthorized operations, rollback on failure, and rejection of mint/burn/admin calls. Four fuzz tests run 1,024 cases each. A stateful invariant runs 256 sequences of up to 128 transfers, approvals and delegated transfers, checking supply conservation and balance/allowance accounting. The distribution test checks the 10% distributor / 80% pool custody / 10% remainder token movements, claims, and transfers into and out of pool custody. It does not implement AMM swaps or liquidity pricing.

## Deployment and launch responsibilities

Deploy the creation bytecode for `src/HamsterHour.sol:HamsterHour` with no appended constructor arguments and no ETH. The constructor requires no initialization calls or existing contracts. It has no linked libraries. A direct deployment allocates the entire supply to the deploying wallet; a factory deployment allocates it entirely to that factory. A wrapper that creates the token would itself receive the supply, so the launch must deploy the token directly from its designated factory.

The launch system is responsible for the manifest, factory deployment, distribution, liquidity initialization, transactions, and explorer verification. This project contains the token only. It does not allocate supply to an application contract or perform launch transactions.

The supplied launch policy distributes 10% to the launch's Merkle distributor, allocates 80% for the pool, and sends the remaining 10% to `0xce34a5ae98f51b499b92063a7a83d49b26ee5b14`. These are subsequent factory operations, not constructor allocations. The provided pool pair is IMD at `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` on Ethereum; its policy fee is `12500` (1.25%), tick spacing is `60`, and the initial market cap is `3500000000000000000000` IMD minor units (3,500 IMD). The manifest's supplied `initialPrice` is `79228162514264337593543950336`; the launch system derives the actual opening price from the economics and token address. These values are supplied launch context, not on-chain dependencies of this token and not independently verified here.

After deployment, the launch operator should confirm the name, symbol, decimals, exact total supply, initial mint recipient, and deployed bytecode against the pinned build. The launch system must run its protected factory/pool integration and ownership checks before release. The provided protected-test inputs refer to separate launch infrastructure and environment configuration that are not part of this token repository; the local suite tests the token and its transfer behavior without claiming to execute that infrastructure. Source verification and independent security review belong to the release process; local tests are not an independent audit.

## After launch

There are no owner settings, administrative keys, keepers, or ongoing contract configuration. The factory, distributor and pool must handle their own responsibilities. Holders control their balances and allowances; the deployer has no special authority over another holder's tokens.

Wallets should display 18 decimals, validate recipients, and approve only amounts and spenders they trust. Standard ERC-20 allowance replacement has transaction-ordering risk: revoke an existing allowance and confirm the revocation before granting a replacement when appropriate. Holders can revoke allowances with `approve(spender, 0)`. Unlimited approvals remain valid until changed by the holder.

The contract has no asset-recovery function. Tokens transferred to the token contract itself, or to any other address without a way to send them back, can be permanently inaccessible. Sending ordinary ETH transactions to the token reverts. No operator can reverse transfers, recover lost keys, freeze accounts, or rescue accidentally sent assets.
