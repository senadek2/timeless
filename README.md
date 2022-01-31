# Timeless

Timeless is a yield tokenization protocol that offers _Perpetual Yield Tokens_, which are [perpetuities](https://www.investopedia.com/terms/p/perpetuity.asp) that give their holders a perpetual right to claim the yield generated by the underlying principal.

## Overview

1. Deposit `x` underlying asset (e.g. DAI), receive `x` principal tokens (PT) and `x` perpetual yield tokens (PYT).
2. The DAI is deposited into yield protocols such as Yearn.
3. A holder of `x` PYTs can claim the yield earned by `x` DAI since the last claim at any time.
4. In order to redeem `x` DAI from the protocol, one must burn `x` PT and `x` PYT together.

## Architecture

-   [`Gate.sol`](src/Gate.sol): Abstract contract that mints/burns PTs and PYTs of vaults of a specific protocol. Allows PYT holders to claim the yield earned by PYTs. Deploys PT and PYT contracts. Owns all vault shares.
-   [`PrincipalToken.sol`](src/PrincipalToken.sol): ERC20 token for representing PTs.
-   [`PerpetualYieldToken.sol`](src/PerpetualYieldToken.sol): ERC20 token for representing PYTs.
-   [`external/`](src/external/): Interfaces for external contracts Timeless interacts with.
    -   [`YearnVault.sol`](src/external/YearnVault.sol): Interface for Yearn v2 vaults.
-   [`gates/`](src/gates/): Implementations of `Gate` integrated with different yield protocols.
    -   [`YearnGate.sol`](src/gates/YearnGate.sol): Implementation of `Gate` that uses Yearn v2 vaults.
-   [`lib/`](src/lib/): Libraries used by other contracts.
    -   [`BaseERC20.sol`](src/lib/BaseERC20.sol): The base ERC20 contract used by `PrincipalToken` and `PerpetualYieldToken`.
    -   [`FullMath.sol`](src/lib/FullMath.sol): Math library preventing phantom overflows during mulDiv operations.

## Installation

To install with [DappTools](https://github.com/dapphub/dapptools):

```
dapp install ZeframLou/timeless
```

To install with [Foundry](https://github.com/gakonst/foundry):

```
forge install ZeframLou/timeless
```

## Local development

This project uses [Foundry](https://github.com/gakonst/foundry) as the development framework.

### Dependencies

```
make update
```

### Compilation

```
make build
```

### Testing

```
make test
```
