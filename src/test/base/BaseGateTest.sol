// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

import {BaseTest, console} from "../base/BaseTest.sol";

import {Gate} from "../../Gate.sol";
import {Factory} from "../../Factory.sol";
import {FullMath} from "../../lib/FullMath.sol";
import {TestERC20} from "../mocks/TestERC20.sol";
import {TestERC4626} from "../mocks/TestERC4626.sol";
import {NegativeYieldToken} from "../../NegativeYieldToken.sol";
import {PerpetualYieldToken} from "../../PerpetualYieldToken.sol";

abstract contract BaseGateTest is BaseTest {
    /// -----------------------------------------------------------------------
    /// Global state
    /// -----------------------------------------------------------------------

    Factory internal factory;
    Gate internal gate;
    address internal constant tester = address(0x69);
    address internal constant tester1 = address(0xabcd);
    address internal constant recipient = address(0xbeef);
    address internal constant nytRecipient = address(0x01);
    address internal constant pytRecipient = address(0x02);
    address internal constant initialDepositor = address(0x420);
    address internal constant protocolFeeRecipient = address(0x6969);
    uint256 internal constant PROTOCOL_FEE = 100; // 10%
    ERC4626 internal constant XPYT_NULL = ERC4626(address(0));

    /// -----------------------------------------------------------------------
    /// Setup
    /// -----------------------------------------------------------------------

    function setUp() public {
        factory = new Factory(
            address(this),
            Factory.ProtocolFeeInfo({
                fee: uint8(PROTOCOL_FEE),
                recipient: protocolFeeRecipient
            })
        );
        gate = _deployGate();
    }

    /// -----------------------------------------------------------------------
    /// User action tests
    /// -----------------------------------------------------------------------

    function test_enterWithUnderlying(
        uint8 underlyingDecimals,
        uint128 initialUnderlyingAmount,
        uint128 initialYieldAmount,
        uint128 underlyingAmount,
        bool useXPYT
    ) public {
        vm.startPrank(tester);

        // bound between 0 and 18
        underlyingDecimals %= 19;

        (TestERC20 underlying, address vault) = _setUpVault(
            underlyingDecimals,
            initialUnderlyingAmount,
            initialYieldAmount
        );
        ERC4626 xPYT = useXPYT
            ? new TestERC4626(
                ERC20(address(gate.getPerpetualYieldTokenForVault(vault)))
            )
            : XPYT_NULL;

        // mint underlying
        underlying.mint(tester, underlyingAmount);

        // enter
        uint256 beforeVaultUnderlyingBalance = underlying.balanceOf(vault);
        uint256 mintAmount = gate.enterWithUnderlying(
            nytRecipient,
            pytRecipient,
            vault,
            xPYT,
            underlyingAmount
        );

        // check balances
        // underlying transferred from tester to vault
        assertEqDecimal(underlying.balanceOf(tester), 0, underlyingDecimals);
        assertEqDecimal(
            underlying.balanceOf(vault) - beforeVaultUnderlyingBalance,
            underlyingAmount,
            underlyingDecimals
        );
        // recipient received NYT and PYT
        NegativeYieldToken nyt = gate.getNegativeYieldTokenForVault(vault);
        PerpetualYieldToken pyt = gate.getPerpetualYieldTokenForVault(vault);
        assertEqDecimal(
            nyt.balanceOf(nytRecipient),
            underlyingAmount,
            underlyingDecimals
        );
        assertEqDecimal(
            useXPYT
                ? xPYT.balanceOf(pytRecipient)
                : pyt.balanceOf(pytRecipient),
            underlyingAmount,
            underlyingDecimals
        );
        assertEqDecimal(mintAmount, underlyingAmount, underlyingDecimals);
    }

    function test_enterWithVaultShares(
        uint8 underlyingDecimals,
        uint128 initialUnderlyingAmount,
        uint128 initialYieldAmount,
        uint128 underlyingAmount,
        bool useXPYT
    ) public {
        if (!gate.vaultSharesIsERC20()) return;

        vm.startPrank(tester);

        // bound between 0 and 18
        underlyingDecimals %= 19;

        if (initialUnderlyingAmount == 0 && initialYieldAmount != 0) {
            // don't give tester free yield
            initialUnderlyingAmount = initialYieldAmount;
        }

        (TestERC20 underlying, address vault) = _setUpVault(
            underlyingDecimals,
            initialUnderlyingAmount,
            initialYieldAmount
        );
        ERC4626 xPYT = useXPYT
            ? new TestERC4626(
                ERC20(address(gate.getPerpetualYieldTokenForVault(vault)))
            )
            : XPYT_NULL;

        // mint underlying and enter vault
        underlying.mint(tester, underlyingAmount);
        uint256 vaultSharesAmount = _depositInVault(vault, underlyingAmount);
        // due to the precision limitations of the vault, we might've lost some underlying
        underlyingAmount = uint128(
            FullMath.mulDiv(
                vaultSharesAmount,
                gate.getPricePerVaultShare(vault),
                10**underlyingDecimals
            )
        );

        // enter
        ERC20(vault).approve(address(gate), type(uint256).max);
        uint256 mintAmount = gate.enterWithVaultShares(
            nytRecipient,
            pytRecipient,
            vault,
            xPYT,
            vaultSharesAmount
        );

        // check balances
        // vault shares transferred from tester to gate
        assertEqDecimal(ERC20(vault).balanceOf(tester), 0, underlyingDecimals);
        assertEqDecimal(
            ERC20(vault).balanceOf(address(gate)),
            vaultSharesAmount,
            underlyingDecimals
        );
        // recipient received NYT and PYT
        NegativeYieldToken nyt = gate.getNegativeYieldTokenForVault(vault);
        PerpetualYieldToken pyt = gate.getPerpetualYieldTokenForVault(vault);
        uint256 epsilonInv = 10**underlyingDecimals;
        assertEqDecimalEpsilonBelow(
            nyt.balanceOf(nytRecipient),
            underlyingAmount,
            underlyingDecimals,
            epsilonInv
        );
        assertEqDecimalEpsilonBelow(
            useXPYT
                ? xPYT.balanceOf(pytRecipient)
                : pyt.balanceOf(pytRecipient),
            underlyingAmount,
            underlyingDecimals,
            epsilonInv
        );
        assertEqDecimalEpsilonBelow(
            mintAmount,
            underlyingAmount,
            underlyingDecimals,
            epsilonInv
        );
    }

    function test_exitToUnderlying(
        uint8 underlyingDecimals,
        uint128 initialUnderlyingAmount,
        uint128 initialYieldAmount,
        uint128 additionalYieldAmount,
        uint128 underlyingAmount,
        bool useXPYT
    ) public {
        vm.startPrank(tester);

        // bound between 0 and 18
        underlyingDecimals %= 19;

        if (initialUnderlyingAmount == 0 && initialYieldAmount != 0) {
            // don't give tester free yield
            initialUnderlyingAmount = initialYieldAmount;
        }

        // bound the initial yield below 100x the initial underlying
        if (initialUnderlyingAmount != 0) {
            initialYieldAmount = uint128(
                initialYieldAmount % (uint256(initialUnderlyingAmount) * 100)
            );
        } else {
            initialYieldAmount = 0;
        }

        // ensure underlying amount is large enough
        if (underlyingAmount == 0) {
            underlyingAmount = 1;
        }

        (TestERC20 underlying, address vault) = _setUpVault(
            underlyingDecimals,
            initialUnderlyingAmount,
            initialYieldAmount
        );
        ERC4626 xPYT = useXPYT
            ? new TestERC4626(
                ERC20(address(gate.getPerpetualYieldTokenForVault(vault)))
            )
            : XPYT_NULL;

        // mint underlying
        underlying.mint(tester, underlyingAmount);

        // enter
        gate.enterWithUnderlying(tester, tester, vault, xPYT, underlyingAmount);

        // mint additional yield to the vault
        // the minimum amount of yield the vault can distribute is limited by the precision
        // of its pricePerShare. namely, the yield should be at least the current amount of underlying
        // times (1 / pricePerShare).
        {
            uint256 totalUnderlyingAmount = uint256(underlyingAmount) +
                uint256(initialUnderlyingAmount) +
                uint256(initialYieldAmount);
            additionalYieldAmount = uint128(
                additionalYieldAmount % (totalUnderlyingAmount * 10)
            );
            uint128 minYieldAmount = uint128(
                totalUnderlyingAmount / gate.getPricePerVaultShare(vault)
            );
            if (additionalYieldAmount < minYieldAmount) {
                additionalYieldAmount = minYieldAmount;
            }
        }
        underlying.mint(vault, additionalYieldAmount);

        // exit
        if (useXPYT) {
            xPYT.approve(address(gate), type(uint256).max);
        }
        uint256 burnAmount = gate.exitToUnderlying(
            recipient,
            vault,
            xPYT,
            underlyingAmount
        );

        // check balances
        uint256 epsilonInv = 10**underlyingDecimals;
        // underlying transferred to tester
        assertEqDecimalEpsilonBelow(
            underlying.balanceOf(recipient),
            underlyingAmount,
            underlyingDecimals,
            epsilonInv
        );
        // recipient burnt NYT and PYT
        NegativeYieldToken nyt = gate.getNegativeYieldTokenForVault(vault);
        PerpetualYieldToken pyt = gate.getPerpetualYieldTokenForVault(vault);
        assertEqDecimalEpsilonBelow(
            nyt.balanceOf(recipient),
            0,
            underlyingDecimals,
            epsilonInv
        );
        assertEqDecimalEpsilonBelow(
            useXPYT ? xPYT.balanceOf(recipient) : pyt.balanceOf(recipient),
            0,
            underlyingDecimals,
            epsilonInv
        );
        assertEqDecimalEpsilonBelow(
            burnAmount,
            underlyingAmount,
            underlyingDecimals,
            epsilonInv
        );
    }

    function test_exitToVaultShares(
        uint8 underlyingDecimals,
        uint128 initialUnderlyingAmount,
        uint128 initialYieldAmount,
        uint128 additionalYieldAmount,
        uint128 underlyingAmount,
        bool useXPYT
    ) public {
        if (!gate.vaultSharesIsERC20()) return;

        vm.startPrank(tester);

        // bound between 6 and 18
        underlyingDecimals %= 13;
        underlyingDecimals += 6;

        if (initialUnderlyingAmount == 0 && initialYieldAmount != 0) {
            // don't give tester free yield
            initialUnderlyingAmount = initialYieldAmount;
        }

        // bound the initial yield below 100x the initial underlying
        if (initialUnderlyingAmount != 0) {
            initialYieldAmount = uint128(
                initialYieldAmount % (uint256(initialUnderlyingAmount) * 100)
            );
        } else {
            initialYieldAmount = 0;
        }

        // ensure underlying amount is large enough
        if (underlyingAmount == 0) {
            underlyingAmount = 1;
        }

        (TestERC20 underlying, address vault) = _setUpVault(
            underlyingDecimals,
            initialUnderlyingAmount,
            initialYieldAmount
        );
        ERC4626 xPYT = useXPYT
            ? new TestERC4626(
                ERC20(address(gate.getPerpetualYieldTokenForVault(vault)))
            )
            : XPYT_NULL;

        // mint underlying
        underlying.mint(tester, underlyingAmount);

        // enter
        gate.enterWithUnderlying(tester, tester, vault, xPYT, underlyingAmount);

        // mint additional yield to the vault
        // the minimum amount of yield the vault can distribute is limited by the precision
        // of its pricePerShare. namely, the yield should be at least the current amount of underlying
        // times (1 / pricePerShare).
        {
            uint256 totalUnderlyingAmount = uint256(underlyingAmount) +
                uint256(initialUnderlyingAmount) +
                uint256(initialYieldAmount);
            additionalYieldAmount = uint128(
                additionalYieldAmount % (totalUnderlyingAmount * 10)
            );
            uint128 minYieldAmount = uint128(
                totalUnderlyingAmount / gate.getPricePerVaultShare(vault)
            );
            if (additionalYieldAmount < minYieldAmount) {
                additionalYieldAmount = minYieldAmount;
            }
        }
        underlying.mint(vault, additionalYieldAmount);

        // exit
        if (useXPYT) {
            xPYT.approve(address(gate), type(uint256).max);
        }
        uint256 vaultSharesAmount = FullMath.mulDiv(
            underlyingAmount,
            10**underlyingDecimals,
            gate.getPricePerVaultShare(vault)
        );
        uint256 burnAmount = gate.exitToVaultShares(
            recipient,
            vault,
            xPYT,
            vaultSharesAmount
        );

        // check balances
        uint256 epsilonInv = min(10**(underlyingDecimals - 2), 10**6);
        // vault shares transferred to tester
        assertEqDecimalEpsilonBelow(
            ERC20(vault).balanceOf(recipient),
            vaultSharesAmount,
            underlyingDecimals,
            epsilonInv
        );
        // recipient burnt NYT and PYT
        NegativeYieldToken nyt = gate.getNegativeYieldTokenForVault(vault);
        assertEqDecimalEpsilonBelow(
            nyt.balanceOf(recipient),
            0,
            underlyingDecimals,
            epsilonInv
        );
        assertEqDecimalEpsilonBelow(
            useXPYT
                ? xPYT.balanceOf(recipient)
                : gate.getPerpetualYieldTokenForVault(vault).balanceOf(
                    recipient
                ),
            0,
            underlyingDecimals,
            epsilonInv
        );
        assertEqDecimalEpsilonBelow(
            burnAmount,
            underlyingAmount,
            underlyingDecimals,
            epsilonInv
        );
    }

    function testFactory_deployYieldTokenPair(uint8 underlyingDecimals) public {
        // bound between 0 and 18
        underlyingDecimals %= 19;

        TestERC20 underlying = new TestERC20(underlyingDecimals);
        address vault = _deployVault(underlying);
        (NegativeYieldToken nyt, PerpetualYieldToken pyt) = factory
            .deployYieldTokenPair(gate, vault);

        assertEq(
            address(gate.getNegativeYieldTokenForVault(vault)),
            address(nyt)
        );
        assertEq(
            address(gate.getPerpetualYieldTokenForVault(vault)),
            address(pyt)
        );
        assertEq(nyt.name(), _getExpectedNYTName());
        assertEq(pyt.name(), _getExpectedPYTName());
        assertEq(nyt.symbol(), _getExpectedNYTSymbol());
        assertEq(pyt.symbol(), _getExpectedPYTSymbol());
        assertEq(nyt.decimals(), underlyingDecimals);
        assertEq(pyt.decimals(), underlyingDecimals);
        assertEq(nyt.totalSupply(), 0);
        assertEq(pyt.totalSupply(), 0);
    }

    function test_claimYieldInUnderlying(
        uint8 underlyingDecimals,
        uint128 initialUnderlyingAmount,
        uint128 initialYieldAmount,
        uint128 additionalYieldAmount,
        uint128 underlyingAmount
    ) public {
        vm.startPrank(tester);

        // bound between 6 and 18
        underlyingDecimals %= 13;
        underlyingDecimals += 6;

        // bound the initial yield below 100x the initial underlying
        if (initialUnderlyingAmount != 0) {
            initialYieldAmount = uint128(
                initialYieldAmount % (uint256(initialUnderlyingAmount) * 100)
            );
        } else {
            initialYieldAmount = 0;
        }

        // ensure underlying amount is large enough
        if (underlyingAmount < 10**underlyingDecimals) {
            underlyingAmount = uint128(10**underlyingDecimals);
        }

        (TestERC20 underlying, address vault) = _setUpVault(
            underlyingDecimals,
            initialUnderlyingAmount,
            initialYieldAmount
        );

        // mint underlying
        underlying.mint(tester, underlyingAmount);

        // enter
        gate.enterWithUnderlying(
            tester,
            tester,
            vault,
            XPYT_NULL,
            underlyingAmount
        );

        // mint additional yield to the vault
        // the minimum amount of yield the vault can distribute is limited by the precision
        // of its pricePerShare. namely, the yield should be at least the current amount of underlying
        // times (1 / pricePerShare).
        {
            uint256 totalUnderlyingAmount = uint256(underlyingAmount) +
                uint256(initialUnderlyingAmount) +
                uint256(initialYieldAmount);
            additionalYieldAmount = uint128(
                additionalYieldAmount % (totalUnderlyingAmount * 10)
            );
            uint128 minYieldAmount = uint128(
                totalUnderlyingAmount / gate.getPricePerVaultShare(vault)
            );
            if (additionalYieldAmount < minYieldAmount) {
                additionalYieldAmount = minYieldAmount;
            }
        }
        uint256 beforePricePerVaultShare = gate.getPricePerVaultShare(vault);
        underlying.mint(vault, additionalYieldAmount);
        uint256 afterPricePerVaultShare = gate.getPricePerVaultShare(vault);
        uint256 expectedYield = (FullMath.mulDiv(
            underlyingAmount,
            afterPricePerVaultShare - beforePricePerVaultShare,
            beforePricePerVaultShare
        ) * (1000 - PROTOCOL_FEE)) / 1000;
        uint256 expectedFee = (expectedYield * PROTOCOL_FEE) /
            (1000 - PROTOCOL_FEE);
        if (gate.vaultSharesIsERC20()) {
            // fee paid in vault shares
            expectedFee = _underlyingAmountToVaultSharesAmount(
                vault,
                expectedFee,
                underlyingDecimals
            );
        }

        // claim yield
        uint256 claimedYield = gate.claimYieldInUnderlying(recipient, vault);

        // check received yield
        uint256 epsilonInv = min(10**(underlyingDecimals - 3), 10**6);
        assertEqDecimalEpsilonAround(
            claimedYield,
            expectedYield,
            underlyingDecimals,
            epsilonInv
        );
        assertEqDecimalEpsilonAround(
            underlying.balanceOf(recipient),
            claimedYield,
            underlyingDecimals,
            epsilonInv
        );

        // check protocol fee
        if (gate.vaultSharesIsERC20()) {
            // check vault balance
            assertEqDecimalEpsilonAround(
                ERC20(vault).balanceOf(protocolFeeRecipient),
                expectedFee,
                underlyingDecimals,
                epsilonInv
            );
        } else {
            // check underlying balance
            assertEqDecimalEpsilonAround(
                underlying.balanceOf(protocolFeeRecipient),
                expectedFee,
                underlyingDecimals,
                epsilonInv
            );
        }
    }

    function test_claimYieldInVaultShares(
        uint8 underlyingDecimals,
        uint128 initialUnderlyingAmount,
        uint128 initialYieldAmount,
        uint128 additionalYieldAmount,
        uint128 underlyingAmount
    ) public {
        if (!gate.vaultSharesIsERC20()) return;

        vm.startPrank(tester);

        // bound between 6 and 18
        underlyingDecimals %= 13;
        underlyingDecimals += 6;

        // bound the initial yield below 100x the initial underlying
        if (initialUnderlyingAmount != 0) {
            initialYieldAmount = uint128(
                initialYieldAmount % (uint256(initialUnderlyingAmount) * 100)
            );
        } else {
            initialYieldAmount = 0;
        }

        // ensure underlying amount is large enough
        if (underlyingAmount < 10**underlyingDecimals) {
            underlyingAmount = uint128(10**underlyingDecimals);
        }

        (TestERC20 underlying, address vault) = _setUpVault(
            underlyingDecimals,
            initialUnderlyingAmount,
            initialYieldAmount
        );

        // mint underlying
        underlying.mint(tester, underlyingAmount);

        // enter
        gate.enterWithUnderlying(
            tester,
            tester,
            vault,
            XPYT_NULL,
            underlyingAmount
        );

        // mint additional yield to the vault
        // the minimum amount of yield the vault can distribute is limited by the precision
        // of its pricePerShare. namely, the yield should be at least the current amount of underlying
        // times (1 / pricePerShare).
        {
            uint256 totalUnderlyingAmount = uint256(underlyingAmount) +
                uint256(initialUnderlyingAmount) +
                uint256(initialYieldAmount);
            additionalYieldAmount = uint128(
                additionalYieldAmount % (totalUnderlyingAmount * 10)
            );
            uint128 minYieldAmount = uint128(
                totalUnderlyingAmount / gate.getPricePerVaultShare(vault)
            );
            if (additionalYieldAmount < minYieldAmount) {
                additionalYieldAmount = minYieldAmount;
            }
        }

        uint256 beforePricePerVaultShare = gate.getPricePerVaultShare(vault);
        underlying.mint(vault, additionalYieldAmount);
        uint256 afterPricePerVaultShare = gate.getPricePerVaultShare(vault);

        uint256 expectedYield = FullMath.mulDiv(
            underlyingAmount,
            afterPricePerVaultShare - beforePricePerVaultShare,
            beforePricePerVaultShare
        );
        expectedYield =
            (_underlyingAmountToVaultSharesAmount(
                vault,
                expectedYield,
                underlyingDecimals
            ) * (1000 - PROTOCOL_FEE)) /
            1000;

        // claim yield
        uint256 claimedYield = gate.claimYieldInVaultShares(recipient, vault);

        // check received yield
        uint256 epsilonInv = min(10**underlyingDecimals, 10**6);
        assertEqDecimalEpsilonAround(
            claimedYield,
            expectedYield,
            underlyingDecimals,
            epsilonInv
        );
        assertEqDecimalEpsilonAround(
            ERC20(vault).balanceOf(recipient),
            claimedYield,
            underlyingDecimals,
            epsilonInv
        );

        // check protocol fee
        uint256 expectedFee = (expectedYield * PROTOCOL_FEE) /
            (1000 - PROTOCOL_FEE);
        assertEqDecimalEpsilonAround(
            ERC20(vault).balanceOf(protocolFeeRecipient),
            expectedFee,
            underlyingDecimals,
            epsilonInv
        );
    }

    function test_claimYieldAndEnter(
        uint8 underlyingDecimals,
        uint128 initialUnderlyingAmount,
        uint128 initialYieldAmount,
        uint128 additionalYieldAmount,
        uint128 underlyingAmount,
        bool useXPYT
    ) public {
        vm.startPrank(tester);

        // bound between 6 and 18
        underlyingDecimals %= 13;
        underlyingDecimals += 6;

        // bound the initial yield below 100x the initial underlying
        if (initialUnderlyingAmount != 0) {
            initialYieldAmount = uint128(
                initialYieldAmount % (uint256(initialUnderlyingAmount) * 100)
            );
        } else {
            initialYieldAmount = 0;
        }

        // ensure underlying amount is large enough
        if (underlyingAmount < 10**underlyingDecimals) {
            underlyingAmount = uint128(10**underlyingDecimals);
        }

        (TestERC20 underlying, address vault) = _setUpVault(
            underlyingDecimals,
            initialUnderlyingAmount,
            initialYieldAmount
        );
        ERC4626 xPYT = useXPYT
            ? new TestERC4626(
                ERC20(address(gate.getPerpetualYieldTokenForVault(vault)))
            )
            : XPYT_NULL;

        // mint underlying
        underlying.mint(tester, underlyingAmount);

        // enter
        // receive raw PYT
        gate.enterWithUnderlying(
            tester,
            tester,
            vault,
            XPYT_NULL,
            underlyingAmount
        );

        // mint additional yield to the vault
        // the minimum amount of yield the vault can distribute is limited by the precision
        // of its pricePerShare. namely, the yield should be at least the current amount of underlying
        // times (1 / pricePerShare).
        {
            uint256 totalUnderlyingAmount = uint256(underlyingAmount) +
                uint256(initialUnderlyingAmount) +
                uint256(initialYieldAmount);
            additionalYieldAmount = uint128(
                additionalYieldAmount % (totalUnderlyingAmount * 10)
            );
            uint128 minYieldAmount = uint128(
                totalUnderlyingAmount / gate.getPricePerVaultShare(vault)
            );
            if (additionalYieldAmount < minYieldAmount) {
                additionalYieldAmount = minYieldAmount;
            }
        }
        uint256 expectedYield;
        uint256 expectedFee;
        {
            uint256 beforePricePerVaultShare = gate.getPricePerVaultShare(
                vault
            );
            underlying.mint(vault, additionalYieldAmount);
            uint256 afterPricePerVaultShare = gate.getPricePerVaultShare(vault);
            expectedYield =
                (FullMath.mulDiv(
                    underlyingAmount,
                    afterPricePerVaultShare - beforePricePerVaultShare,
                    beforePricePerVaultShare
                ) * (1000 - PROTOCOL_FEE)) /
                1000;
            expectedFee =
                (expectedYield * PROTOCOL_FEE) /
                (1000 - PROTOCOL_FEE);
            if (gate.vaultSharesIsERC20()) {
                // fee paid in vault shares
                expectedFee = _underlyingAmountToVaultSharesAmount(
                    vault,
                    expectedFee,
                    underlyingDecimals
                );
            }
        }

        // claim yield
        uint256 claimedYield = gate.claimYieldAndEnter(
            nytRecipient,
            pytRecipient,
            vault,
            xPYT
        );

        // check received yield
        uint256 epsilonInv = min(10**(underlyingDecimals - 3), 10**6);
        assertEqDecimalEpsilonAround(
            claimedYield,
            expectedYield,
            underlyingDecimals,
            epsilonInv
        );
        assertEqDecimalEpsilonAround(
            gate.getNegativeYieldTokenForVault(vault).balanceOf(nytRecipient),
            claimedYield,
            underlyingDecimals,
            epsilonInv
        );
        assertEqDecimalEpsilonAround(
            useXPYT
                ? xPYT.balanceOf(pytRecipient)
                : gate.getPerpetualYieldTokenForVault(vault).balanceOf(
                    pytRecipient
                ),
            claimedYield,
            underlyingDecimals,
            epsilonInv
        );

        // check protocol fee
        if (gate.vaultSharesIsERC20()) {
            // check vault balance
            assertEqDecimalEpsilonAround(
                ERC20(vault).balanceOf(protocolFeeRecipient),
                expectedFee,
                underlyingDecimals,
                epsilonInv
            );
        } else {
            // check underlying balance
            assertEqDecimalEpsilonAround(
                underlying.balanceOf(protocolFeeRecipient),
                expectedFee,
                underlyingDecimals,
                epsilonInv
            );
        }
    }

    function test_transferPYT_toUninitializedAccount(
        uint8 underlyingDecimals,
        uint128 initialUnderlyingAmount,
        uint128 initialYieldAmount,
        uint128 additionalYieldAmount,
        uint128 underlyingAmount,
        uint8 pytTransferPercent
    ) public {
        vm.startPrank(tester);

        // bound between 6 and 18
        underlyingDecimals %= 13;
        underlyingDecimals += 6;

        // bound the initial yield below 100x the initial underlying
        if (initialUnderlyingAmount != 0) {
            initialYieldAmount = uint128(
                initialYieldAmount % (uint256(initialUnderlyingAmount) * 100)
            );
        } else {
            initialYieldAmount = 0;
        }

        // bound between 1 and 99
        pytTransferPercent %= 99;
        pytTransferPercent += 1;

        // ensure underlying amount is large enough
        if (underlyingAmount < 10**underlyingDecimals) {
            underlyingAmount = uint128(10**underlyingDecimals);
        }

        (TestERC20 underlying, address vault) = _setUpVault(
            underlyingDecimals,
            initialUnderlyingAmount,
            initialYieldAmount
        );

        // mint underlying
        underlying.mint(tester, underlyingAmount);

        // enter
        gate.enterWithUnderlying(
            tester,
            tester,
            vault,
            XPYT_NULL,
            underlyingAmount
        );

        // mint additional yield to the vault
        // the minimum amount of yield the vault can distribute is limited by the precision
        // of its pricePerShare. namely, the yield should be at least the current amount of underlying
        // times (1 / pricePerShare).
        {
            uint256 totalUnderlyingAmount = uint256(underlyingAmount) +
                uint256(initialUnderlyingAmount) +
                uint256(initialYieldAmount);
            additionalYieldAmount = uint128(
                additionalYieldAmount % (totalUnderlyingAmount * 10)
            );
            uint128 minYieldAmount = uint128(
                totalUnderlyingAmount / gate.getPricePerVaultShare(vault)
            );
            if (additionalYieldAmount < minYieldAmount) {
                additionalYieldAmount = minYieldAmount;
            }
        }

        uint256 expectedYield;
        {
            uint256 beforePricePerVaultShare = gate.getPricePerVaultShare(
                vault
            );
            underlying.mint(vault, additionalYieldAmount);
            expectedYield =
                (FullMath.mulDiv(
                    underlyingAmount,
                    gate.getPricePerVaultShare(vault) -
                        beforePricePerVaultShare,
                    beforePricePerVaultShare
                ) * (1000 - PROTOCOL_FEE)) /
                1000;
        }

        // transfer PYT to tester1
        gate.getPerpetualYieldTokenForVault(vault).transfer(
            tester1,
            FullMath.mulDiv(underlyingAmount, pytTransferPercent, 100)
        );

        // claim yield as tester
        uint256 testerClaimedYield = gate.claimYieldInUnderlying(
            recipient,
            vault
        );

        // tester should've received all the yield
        uint256 epsilonInv = min(10**(underlyingDecimals - 3), 10**6);
        console.log(testerClaimedYield, expectedYield);
        assertEqDecimalEpsilonAround(
            testerClaimedYield,
            expectedYield,
            underlyingDecimals,
            epsilonInv
        );

        // claim yield as tester1
        // should have received 0
        epsilonInv = 10**(underlyingDecimals - 2);
        vm.stopPrank();
        vm.startPrank(tester1);
        assertLeDecimal(
            gate.claimYieldInUnderlying(tester1, vault),
            testerClaimedYield / epsilonInv,
            underlyingDecimals
        );
    }

    function test_transferPYT_toInitializedAccount(
        uint8 underlyingDecimals,
        uint128 initialUnderlyingAmount,
        uint128 initialYieldAmount,
        uint128 additionalYieldAmount,
        uint128 underlyingAmount,
        uint8 pytTransferPercent
    ) public {
        vm.startPrank(tester);

        // bound between 6 and 18
        underlyingDecimals %= 13;
        underlyingDecimals += 6;

        // bound the initial yield below 10x the initial underlying
        if (initialUnderlyingAmount != 0) {
            initialYieldAmount = uint128(
                initialYieldAmount % (uint256(initialUnderlyingAmount) * 10)
            );
        } else {
            initialYieldAmount = 0;
        }

        // bound between 1 and 99
        pytTransferPercent %= 99;
        pytTransferPercent += 1;

        // ensure underlying amount is large enough
        if (underlyingAmount < 10**underlyingDecimals) {
            underlyingAmount = uint128(10**underlyingDecimals);
        }

        (TestERC20 underlying, address vault) = _setUpVault(
            underlyingDecimals,
            initialUnderlyingAmount,
            initialYieldAmount
        );

        // enter
        underlying.mint(tester, underlyingAmount);
        gate.enterWithUnderlying(
            tester,
            tester,
            vault,
            XPYT_NULL,
            underlyingAmount
        );

        // switch to tester1
        vm.stopPrank();
        vm.startPrank(tester1);

        // enter
        underlying.mint(tester1, underlyingAmount);
        underlying.approve(address(gate), type(uint256).max);
        gate.enterWithUnderlying(
            tester1,
            tester1,
            vault,
            XPYT_NULL,
            underlyingAmount
        );

        // switch to tester
        vm.stopPrank();
        vm.startPrank(tester);

        // mint additional yield to the vault
        // the minimum amount of yield the vault can distribute is limited by the precision
        // of its pricePerShare. namely, the yield should be at least the current amount of underlying
        // times (1 / pricePerShare).
        {
            uint256 totalUnderlyingAmount = uint256(underlyingAmount) +
                uint256(initialUnderlyingAmount) +
                uint256(initialYieldAmount);
            additionalYieldAmount = uint128(
                additionalYieldAmount % (totalUnderlyingAmount * 10)
            );
            uint128 minYieldAmount = uint128(
                totalUnderlyingAmount / gate.getPricePerVaultShare(vault)
            );
            if (additionalYieldAmount < minYieldAmount) {
                additionalYieldAmount = minYieldAmount;
            }
        }

        uint256 expectedYield;
        {
            uint256 beforePricePerVaultShare = gate.getPricePerVaultShare(
                vault
            );
            underlying.mint(vault, additionalYieldAmount);
            expectedYield =
                (FullMath.mulDiv(
                    underlyingAmount,
                    gate.getPricePerVaultShare(vault) -
                        beforePricePerVaultShare,
                    beforePricePerVaultShare
                ) * (1000 - PROTOCOL_FEE)) /
                1000;
        }

        // transfer PYT to tester1
        gate.getPerpetualYieldTokenForVault(vault).transfer(
            tester1,
            FullMath.mulDiv(underlyingAmount, pytTransferPercent, 100)
        );

        // claim yield as tester
        uint256 testerClaimedYield = gate.claimYieldInUnderlying(
            recipient,
            vault
        );

        // tester should've received the correct amount of yield
        uint256 epsilonInv = min(10**(underlyingDecimals - 3), 10**5);
        assertEqDecimalEpsilonAround(
            testerClaimedYield,
            expectedYield,
            underlyingDecimals,
            epsilonInv
        );

        // claim yield as tester1
        // should've received the correct amount of yield
        vm.stopPrank();
        vm.startPrank(tester1);
        assertEqDecimalEpsilonAround(
            gate.claimYieldInUnderlying(tester1, vault),
            expectedYield,
            underlyingDecimals,
            epsilonInv
        );
    }

    function test_transferFromPYT_toUninitializedAccount(
        uint8 underlyingDecimals,
        uint128 initialUnderlyingAmount,
        uint128 initialYieldAmount,
        uint128 additionalYieldAmount,
        uint128 underlyingAmount,
        uint8 pytTransferPercent
    ) public {
        vm.startPrank(tester);

        // bound between 6 and 18
        underlyingDecimals %= 13;
        underlyingDecimals += 6;

        // bound the initial yield below 100x the initial underlying
        if (initialUnderlyingAmount != 0) {
            initialYieldAmount = uint128(
                initialYieldAmount % (uint256(initialUnderlyingAmount) * 100)
            );
        } else {
            initialYieldAmount = 0;
        }

        // bound between 1 and 99
        pytTransferPercent %= 99;
        pytTransferPercent += 1;

        // ensure underlying amount is large enough
        if (underlyingAmount < 10**underlyingDecimals) {
            underlyingAmount = uint128(10**underlyingDecimals);
        }

        (TestERC20 underlying, address vault) = _setUpVault(
            underlyingDecimals,
            initialUnderlyingAmount,
            initialYieldAmount
        );

        // mint underlying
        underlying.mint(tester, underlyingAmount);

        // enter
        gate.enterWithUnderlying(
            tester,
            tester,
            vault,
            XPYT_NULL,
            underlyingAmount
        );

        // mint additional yield to the vault
        // the minimum amount of yield the vault can distribute is limited by the precision
        // of its pricePerShare. namely, the yield should be at least the current amount of underlying
        // times (1 / pricePerShare).
        {
            uint256 totalUnderlyingAmount = uint256(underlyingAmount) +
                uint256(initialUnderlyingAmount) +
                uint256(initialYieldAmount);
            additionalYieldAmount = uint128(
                additionalYieldAmount % (totalUnderlyingAmount * 10)
            );
            uint128 minYieldAmount = uint128(
                totalUnderlyingAmount / gate.getPricePerVaultShare(vault)
            );
            if (additionalYieldAmount < minYieldAmount) {
                additionalYieldAmount = minYieldAmount;
            }
        }

        uint256 expectedYield;
        {
            uint256 beforePricePerVaultShare = gate.getPricePerVaultShare(
                vault
            );
            underlying.mint(vault, additionalYieldAmount);
            expectedYield =
                (FullMath.mulDiv(
                    underlyingAmount,
                    gate.getPricePerVaultShare(vault) -
                        beforePricePerVaultShare,
                    beforePricePerVaultShare
                ) * (1000 - PROTOCOL_FEE)) /
                1000;
        }

        // give tester1 PYT approval
        PerpetualYieldToken pyt = gate.getPerpetualYieldTokenForVault(vault);
        pyt.approve(tester1, type(uint256).max);

        // transfer PYT from tester to tester1, as tester1
        vm.prank(tester1);
        pyt.transferFrom(
            tester,
            tester1,
            FullMath.mulDiv(underlyingAmount, pytTransferPercent, 100)
        );

        // claim yield as tester
        uint256 testerClaimedYield = gate.claimYieldInUnderlying(
            recipient,
            vault
        );

        // tester should've received all the yield
        uint256 epsilonInv = min(10**(underlyingDecimals - 3), 10**6);
        assertEqDecimalEpsilonAround(
            testerClaimedYield,
            expectedYield,
            underlyingDecimals,
            epsilonInv
        );

        // claim yield as tester1
        // should have received 0
        epsilonInv = 10**(underlyingDecimals - 2);
        vm.stopPrank();
        vm.startPrank(tester1);
        assertLeDecimal(
            gate.claimYieldInUnderlying(tester1, vault),
            testerClaimedYield / epsilonInv,
            underlyingDecimals
        );
    }

    function test_transferFromPYT_toInitializedAccount(
        uint8 underlyingDecimals,
        uint128 initialUnderlyingAmount,
        uint128 initialYieldAmount,
        uint128 additionalYieldAmount,
        uint128 underlyingAmount,
        uint8 pytTransferPercent
    ) public {
        vm.startPrank(tester);

        // bound between 6 and 18
        underlyingDecimals %= 13;
        underlyingDecimals += 6;

        // bound the initial yield below 10x the initial underlying
        if (initialUnderlyingAmount != 0) {
            initialYieldAmount = uint128(
                initialYieldAmount % (uint256(initialUnderlyingAmount) * 10)
            );
        } else {
            initialYieldAmount = 0;
        }

        // bound between 1 and 99
        pytTransferPercent %= 99;
        pytTransferPercent += 1;

        // ensure underlying amount is large enough
        if (underlyingAmount < 10**underlyingDecimals) {
            underlyingAmount = uint128(10**underlyingDecimals);
        }

        (TestERC20 underlying, address vault) = _setUpVault(
            underlyingDecimals,
            initialUnderlyingAmount,
            initialYieldAmount
        );

        // enter
        underlying.mint(tester, underlyingAmount);
        gate.enterWithUnderlying(
            tester,
            tester,
            vault,
            XPYT_NULL,
            underlyingAmount
        );

        // switch to tester1
        vm.stopPrank();
        vm.startPrank(tester1);

        // enter
        underlying.mint(tester1, underlyingAmount);
        underlying.approve(address(gate), type(uint256).max);
        gate.enterWithUnderlying(
            tester1,
            tester1,
            vault,
            XPYT_NULL,
            underlyingAmount
        );

        // switch to tester
        vm.stopPrank();
        vm.startPrank(tester);

        // mint additional yield to the vault
        // the minimum amount of yield the vault can distribute is limited by the precision
        // of its pricePerShare. namely, the yield should be at least the current amount of underlying
        // times (1 / pricePerShare).
        {
            uint256 totalUnderlyingAmount = uint256(underlyingAmount) +
                uint256(initialUnderlyingAmount) +
                uint256(initialYieldAmount);
            additionalYieldAmount = uint128(
                additionalYieldAmount % (totalUnderlyingAmount * 10)
            );
            uint128 minYieldAmount = uint128(
                totalUnderlyingAmount / gate.getPricePerVaultShare(vault)
            );
            if (additionalYieldAmount < minYieldAmount) {
                additionalYieldAmount = minYieldAmount;
            }
        }

        uint256 expectedYield;
        {
            uint256 beforePricePerVaultShare = gate.getPricePerVaultShare(
                vault
            );
            underlying.mint(vault, additionalYieldAmount);
            expectedYield =
                (FullMath.mulDiv(
                    underlyingAmount,
                    gate.getPricePerVaultShare(vault) -
                        beforePricePerVaultShare,
                    beforePricePerVaultShare
                ) * (1000 - PROTOCOL_FEE)) /
                1000;
        }

        // give tester1 PYT approval
        PerpetualYieldToken pyt = gate.getPerpetualYieldTokenForVault(vault);
        pyt.approve(tester1, type(uint256).max);

        // transfer PYT from tester to tester1, as tester1
        vm.prank(tester1);
        pyt.transferFrom(
            tester,
            tester1,
            FullMath.mulDiv(underlyingAmount, pytTransferPercent, 100)
        );

        // claim yield as tester
        uint256 testerClaimedYield = gate.claimYieldInUnderlying(
            recipient,
            vault
        );

        // tester should've received the correct amount of yield
        uint256 epsilonInv = min(10**(underlyingDecimals - 2), 10**6);
        assertEqDecimalEpsilonAround(
            testerClaimedYield,
            expectedYield,
            underlyingDecimals,
            epsilonInv
        );

        // claim yield as tester1
        // should've received the correct amount of yield
        vm.stopPrank();
        vm.startPrank(tester1);
        assertEqDecimalEpsilonAround(
            gate.claimYieldInUnderlying(tester1, vault),
            expectedYield,
            underlyingDecimals,
            epsilonInv
        );
    }

    /// -----------------------------------------------------------------------
    /// Failure tests
    /// -----------------------------------------------------------------------

    function testFail_cannotCallPYTTransferHook(
        address from,
        address to,
        uint256 amount,
        uint256 fromAmount,
        uint256 toAmount
    ) public {
        if (amount == 0) amount = 1;
        gate.beforePerpetualYieldTokenTransfer(
            from,
            to,
            amount,
            fromAmount,
            toAmount
        );
    }

    function testFail_cannotDeployTokensTwice(uint8 underlyingDecimals) public {
        TestERC20 underlying = new TestERC20(underlyingDecimals);
        address vault = _deployVault(underlying);
        factory.deployYieldTokenPair(gate, vault);
        factory.deployYieldTokenPair(gate, vault);
    }

    function testFail_cannotSetProtocolFeeAsRando(
        Factory.ProtocolFeeInfo memory protocolFeeInfo_
    ) public {
        vm.startPrank(tester);
        factory.ownerSetProtocolFee(protocolFeeInfo_);
    }

    /// -----------------------------------------------------------------------
    /// Owner action tests
    /// -----------------------------------------------------------------------

    function testFactory_ownerSetProtocolFee(
        Factory.ProtocolFeeInfo memory protocolFeeInfo_
    ) public {
        if (
            protocolFeeInfo_.fee != 0 &&
            protocolFeeInfo_.recipient == address(0)
        ) {
            vm.expectRevert(
                abi.encodeWithSignature("Error_ProtocolFeeRecipientIsZero()")
            );
            factory.ownerSetProtocolFee(protocolFeeInfo_);
        } else {
            factory.ownerSetProtocolFee(protocolFeeInfo_);

            (uint8 fee, address recipient_) = factory.protocolFeeInfo();
            assertEq(fee, protocolFeeInfo_.fee);
            assertEq(recipient_, protocolFeeInfo_.recipient);
        }
    }

    /// -----------------------------------------------------------------------
    /// Internal utilities
    /// -----------------------------------------------------------------------

    function _setUpVault(
        uint8 underlyingDecimals,
        uint256 initialUnderlyingAmount,
        uint256 initialYieldAmount
    ) internal returns (TestERC20 underlying, address vault) {
        // setup contracts
        underlying = new TestERC20(underlyingDecimals);
        vault = _deployVault(underlying);
        underlying.approve(address(gate), type(uint256).max);
        underlying.approve(vault, type(uint256).max);
        factory.deployYieldTokenPair(gate, vault);

        // initialize deposits & yield
        underlying.mint(initialDepositor, initialUnderlyingAmount);
        vm.prank(initialDepositor);
        underlying.approve(vault, type(uint256).max);
        vm.prank(initialDepositor);
        _depositInVault(vault, initialUnderlyingAmount);
        underlying.mint(vault, initialYieldAmount);
    }

    function _vaultSharesAmountToUnderlyingAmount(
        address vault,
        uint256 vaultSharesAmount,
        uint8 underlyingDecimals
    ) internal view virtual returns (uint256) {
        return
            FullMath.mulDiv(
                vaultSharesAmount,
                gate.getPricePerVaultShare(vault),
                10**underlyingDecimals
            );
    }

    function _underlyingAmountToVaultSharesAmount(
        address vault,
        uint256 underlyingAmount,
        uint8 underlyingDecimals
    ) internal view virtual returns (uint256) {
        return
            FullMath.mulDiv(
                underlyingAmount,
                10**underlyingDecimals,
                gate.getPricePerVaultShare(vault)
            );
    }

    /// -----------------------------------------------------------------------
    /// Mixins
    /// -----------------------------------------------------------------------

    function _deployGate() internal virtual returns (Gate gate_);

    function _deployVault(ERC20 underlying)
        internal
        virtual
        returns (address vault);

    function _depositInVault(address vault, uint256 underlyingAmount)
        internal
        virtual
        returns (uint256);

    function _getExpectedNYTName() internal virtual returns (string memory);

    function _getExpectedNYTSymbol() internal virtual returns (string memory);

    function _getExpectedPYTName() internal virtual returns (string memory);

    function _getExpectedPYTSymbol() internal virtual returns (string memory);
}
