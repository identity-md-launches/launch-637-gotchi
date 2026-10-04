// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {LaunchToken} from "../../src/LaunchToken.sol";
import {GotchiFeeHook} from "../../src/GotchiFeeHook.sol";
import {HookMiner} from "../../src/HookMiner.sol";
import {FeeSink} from "../../src/FeeSink.sol";
import {MockAavegotchi} from "../../src/MockAavegotchi.sol";
import {MockBaazaar} from "../../src/MockBaazaar.sol";
import {FlipEscrow} from "../../src/FlipEscrow.sol";
import {HolderWeightedPicker} from "../../src/HolderWeightedPicker.sol";
import {ForeverLiquidity} from "../../src/ForeverLiquidity.sol";

/// @notice Deploys the whole $GOTCHI stack against a local v4 PoolManager, with the hooked ETH/GOTCHI
/// pool and an identical un-hooked reference pool, both seeded with the same full-range liquidity.
abstract contract GotchiFixture is Test {
    using CurrencyLibrary for Currency;

    uint256 internal constant INITIAL_ETH = 10 ether;
    uint256 internal constant INITIAL_TOKENS = 100_000_000e18;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    PoolManager internal manager;
    LaunchToken internal token;
    GotchiFeeHook internal hook;
    MockAavegotchi internal nft;
    MockBaazaar internal baazaar;
    HolderWeightedPicker internal picker;
    FlipEscrow internal escrow;
    FeeSink internal sink;
    ForeverLiquidity internal forever;

    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;

    PoolKey internal key;
    PoolKey internal plainKey;
    uint128 internal seededLiquidity;
    bytes32 internal lastHookSalt;

    address internal operator = makeAddr("operator");
    address internal minter = makeAddr("minter");
    address internal seller = makeAddr("seller");

    receive() external payable {}

    function setUp() public virtual {
        vm.deal(address(this), 10_000 ether);

        manager = new PoolManager(address(this));
        token = new LaunchToken();
        hook = deployHook(address(manager), 0);
        nft = new MockAavegotchi(minter);
        baazaar = new MockBaazaar(address(nft));
        picker = new HolderWeightedPicker(address(token), address(manager));
        escrow = new FlipEscrow(address(nft), address(baazaar), address(picker), operator);
        sink = new FeeSink(address(hook), address(baazaar), address(escrow));
        forever = new ForeverLiquidity(address(token), address(manager), address(hook));

        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(lpRouter), type(uint256).max);

        // Hooked pool, seeded through ForeverLiquidity.
        key = forever.poolKey();
        uint160 sqrtPrice = forever.sqrtPriceX96ForAmounts(INITIAL_ETH, INITIAL_TOKENS);
        forever.initializePool(sqrtPrice);
        seededLiquidity = forever.liquidityForAmounts(INITIAL_ETH, INITIAL_TOKENS);
        token.approve(address(forever), INITIAL_TOKENS);
        forever.addLiquidity{value: INITIAL_ETH}(seededLiquidity, INITIAL_TOKENS);

        // Reference pool: same currencies, price and liquidity, no hook.
        plainKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: forever.LP_FEE(),
            tickSpacing: forever.TICK_SPACING(),
            hooks: IHooks(address(0))
        });
        manager.initialize(plainKey, sqrtPrice);
        lpRouter.modifyLiquidity{value: INITIAL_ETH}(
            plainKey,
            ModifyLiquidityParams({
                tickLower: forever.TICK_LOWER(),
                tickUpper: forever.TICK_UPPER(),
                liquidityDelta: int256(uint256(seededLiquidity)),
                salt: bytes32(0)
            }),
            ""
        );
    }

    /// @dev Deploys a GotchiFeeHook at a CREATE2 address carrying exactly its permission bits. Pass the
    /// previous hook's salt plus one as `saltStart` to deploy a second one for the same manager.
    function deployHook(address poolManager, uint256 saltStart) internal returns (GotchiFeeHook deployed) {
        bytes memory creationCode = abi.encodePacked(type(GotchiFeeHook).creationCode, abi.encode(poolManager));
        (address predicted, bytes32 salt) = HookMiner.find(address(this), _hookFlags(), creationCode, saltStart);
        lastHookSalt = salt;
        deployed = new GotchiFeeHook{salt: salt}(poolManager);
        assertEq(address(deployed), predicted, "hook landed somewhere else");
        assertTrue(deployed.addressHasValidFlags(), "hook address lacks its flags");
    }

    function _hookFlags() internal pure returns (uint160) {
        return 0xCC;
    }

    /// @dev Swaps on `k` through the v4 test router; exact input when `amountSpecified < 0`.
    function swap(PoolKey memory k, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        uint256 value = 0;
        if (zeroForOne) {
            // ETH in: send the exact input, or plenty for an exact output (the router refunds the rest).
            value = amountSpecified < 0 ? uint256(-amountSpecified) : 100 ether;
        }
        return swapRouter.swap{value: value}(
            k,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Mints a gotchi to `to`, approves the Baazaar and lists it at `price`.
    function mintAndList(address to, uint256 price) internal returns (uint256 listingId, uint256 tokenId) {
        vm.prank(minter);
        tokenId = nft.mint(to);
        vm.startPrank(to);
        nft.approve(address(baazaar), tokenId);
        listingId = baazaar.list(tokenId, price);
        vm.stopPrank();
    }

    /// @dev Gives `holder` `amount` GOTCHI and deposits all of it into the picker as their weight.
    function fundAndDeposit(address holder, uint256 amount) internal {
        token.transfer(holder, amount);
        vm.startPrank(holder);
        token.approve(address(picker), amount);
        picker.deposit(amount);
        vm.stopPrank();
    }

    /// @dev Finds a secret whose roll for the given request burns (or not), and returns it with its hash.
    function findSecret(uint256 acquisitionId, uint256 tokenId, uint256 commitmentIndex, bool wantBurn)
        internal
        view
        returns (bytes32 secret, bytes32 hash)
    {
        for (uint256 i = 1; i < 10_000; i++) {
            secret = keccak256(abi.encode("gotchi-secret", i, acquisitionId, tokenId, commitmentIndex));
            hash = keccak256(abi.encodePacked(secret));
            bytes32 requestId = escrow.computeRequestId(acquisitionId, tokenId, commitmentIndex, hash);
            if (escrow.isBurnRoll(escrow.rollFor(secret, requestId)) == wantBurn) return (secret, hash);
        }
        revert("no secret found");
    }
}
