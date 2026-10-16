# Vendored dependencies

Dependencies are copied as ordinary source files, without submodules or install steps. Upstream files are unmodified. `DEPENDENCIES.sha256` records their SHA-256 hashes; run `sha256sum --check DEPENDENCIES.sha256` to verify the copies.

| Dependency | Version | Pinned commit | Included files | License |
| --- | --- | --- | --- | --- |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/dbb6104ce834628e473d2173bbc9d47f81a9eec3) | v5.0.2 | `dbb6104ce834628e473d2173bbc9d47f81a9eec3` | `ERC20.sol`, `IERC20.sol`, `IERC20Metadata.sol`, `Context.sol`, `draft-IERC6093.sol` and `LICENSE` | MIT |
| [forge-std](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505) | v1.9.7 | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | Complete `src/` directory and both license files; used by tests only | MIT or Apache-2.0 |

Production imports resolve entirely to the OpenZeppelin subset. The remappings are explicit in `remappings.txt`. Vendored test utilities expose general Foundry features, but this project's tests use no environment access, filesystem access, FFI, fork, or broadcast operations.
