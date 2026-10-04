// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {DeployGotchiSepolia} from "../script/DeployGotchiSepolia.s.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {GotchiFeeHook} from "../src/GotchiFeeHook.sol";
import {GotchiStackDeployer} from "../src/GotchiStackDeployer.sol";
import {ForeverLiquidity} from "../src/ForeverLiquidity.sol";

/// @notice Runs the deploy script's `deploy(Config)` against a local PoolManager, without env vars or
/// broadcasting, and checks the wiring it produces.
contract DeployScriptTest is Test {
    using StateLibrary for IPoolManager;

    PoolManager manager;
    DeployGotchiSepolia script;
    address operator = makeAddr("operator");
    address minter = makeAddr("minter");

    function setUp() public {
        manager = new PoolManager(address(this));
        script = new DeployGotchiSepolia();
        vm.deal(address(script), 10 ether);
    }

    function _config() internal view returns (DeployGotchiSepolia.Config memory) {
        return DeployGotchiSepolia.Config({
            poolManager: address(manager),
            operator: operator,
            minter: minter,
            initialLiquidityEth: script.DEFAULT_INITIAL_ETH(),
            initialLiquidityTokens: script.DEFAULT_INITIAL_TOKENS()
        });
    }

    function test_deployWiresEverything() public {
        DeployGotchiSepolia.Deployment memory d = script.deploy(_config());

        // Hook: only the PoolManager in its constructor, address carries 0xCC, sink bound, created by the
        // stack deployer (CREATE2 from its address) in the same call as the sink.
        assertEq(address(d.hook.POOL_MANAGER()), address(manager));
        assertTrue(d.hook.addressHasValidFlags());
        assertEq(HookFlags.flagsOf(address(d.hook)), 0xCC);
        assertEq(d.hook.feeSink(), address(d.sink));
        assertEq(d.stackDeployer.DEPLOYER(), address(script));
        assertEq(d.stackDeployer.POOL_MANAGER(), address(manager));
        bytes memory creationCode = abi.encodePacked(type(GotchiFeeHook).creationCode, abi.encode(address(manager)));
        assertEq(
            address(d.hook), HookMiner.computeAddress(address(d.stackDeployer), d.hookSalt, keccak256(creationCode))
        );

        // Siblings.
        assertEq(d.nft.MINTER(), minter);
        assertEq(address(d.baazaar.NFT()), address(d.nft));
        assertEq(address(d.picker.TOKEN()), address(d.token));
        assertEq(d.picker.EXCLUDED_POOL_MANAGER(), address(manager));
        assertEq(address(d.escrow.NFT()), address(d.nft));
        assertEq(d.escrow.BAAZAAR(), address(d.baazaar));
        assertEq(address(d.escrow.PICKER()), address(d.picker));
        assertEq(d.escrow.OPERATOR(), operator);
        assertEq(address(d.sink.BAAZAAR()), address(d.baazaar));
        assertEq(address(d.sink.ESCROW()), address(d.escrow));
        assertEq(address(d.forever.HOOK()), address(d.hook));
        assertEq(Currency.unwrap(d.key.currency1), address(d.token));
        assertEq(address(d.key.hooks), address(d.hook));

        // Pool initialized at the configured price with the configured liquidity, locked forever.
        IPoolManager pm = IPoolManager(address(manager));
        (uint160 sqrtPriceX96,,,) = pm.getSlot0(d.forever.poolId());
        assertEq(sqrtPriceX96, d.sqrtPriceX96);
        assertEq(sqrtPriceX96, d.forever.sqrtPriceX96ForAmounts(0.1 ether, 100_000_000e18));
        assertEq(pm.getLiquidity(d.forever.poolId()), d.liquidity);
        assertGt(d.liquidity, 0);
        (uint128 positionLiquidity,,) =
            pm.getPositionInfo(d.forever.poolId(), address(d.forever), -887_220, 887_220, bytes32(0));
        assertEq(positionLiquidity, d.liquidity);

        // Token: whole supply minted to the deployer (the script), minus what went into the pool.
        assertEq(d.token.totalSupply(), 1e27);
        assertEq(d.token.balanceOf(address(d.forever)), 0);
        uint256 inPool = d.token.balanceOf(address(manager));
        assertLe(inPool, 100_000_000e18);
        assertEq(d.token.balanceOf(address(script)), 1e27 - inPool);
        assertLe(address(script).balance, 10 ether);
        assertGe(address(script).balance, 10 ether - 0.1 ether);
    }

    function test_deployTwiceMinesADifferentHookAddress() public {
        DeployGotchiSepolia.Deployment memory first = script.deploy(_config());
        vm.deal(address(script), 10 ether);
        DeployGotchiSepolia.Deployment memory second = script.deploy(_config());
        assertTrue(address(first.hook) != address(second.hook));
        assertTrue(address(first.stackDeployer) != address(second.stackDeployer));
        assertTrue(second.hook.addressHasValidFlags());
        assertEq(second.hook.feeSink(), address(second.sink));
    }

    function test_deployRejectsBadConfig() public {
        DeployGotchiSepolia.Config memory cfg = _config();
        cfg.poolManager = address(0);
        vm.expectRevert(bytes("pool manager"));
        script.deploy(cfg);
        cfg = _config();
        cfg.operator = address(0);
        vm.expectRevert(bytes("roles"));
        script.deploy(cfg);
    }

    /// @dev The three front-running windows the stack deployer closes: binding the sink to a fresh hook,
    /// initializing the pool key before the script does, and moving the empty pool's price before the
    /// initial liquidity lands. All of it happens inside one call.
    function test_stackDeployerIsAtomicAndOnlyForItsDeployer() public {
        DeployGotchiSepolia.Deployment memory d = script.deploy(_config());
        assertGt(IPoolManager(address(manager)).getLiquidity(d.forever.poolId()), 0, "never an empty pool");

        // A stranger cannot use the helper (and so cannot consume a mined salt).
        bytes memory creationCode = abi.encodePacked(type(GotchiFeeHook).creationCode, abi.encode(address(manager)));
        (, bytes32 salt) = HookMiner.find(address(d.stackDeployer), 0xCC, creationCode, uint256(d.hookSalt) + 1);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(GotchiStackDeployer.NotDeployer.selector);
        d.stackDeployer.deploy(salt, address(d.token), address(d.baazaar), address(d.escrow), d.sqrtPriceX96, 0);

        // The deployer itself can run it again with a fresh salt and no liquidity: new hook, bound sink,
        // initialized (empty) pool.
        vm.prank(address(script));
        (GotchiFeeHook hook2,, ForeverLiquidity forever2, uint128 liquidity2) =
            d.stackDeployer.deploy(salt, address(d.token), address(d.baazaar), address(d.escrow), d.sqrtPriceX96, 0);
        assertTrue(hook2.addressHasValidFlags());
        assertTrue(hook2.feeSink() != address(0));
        assertEq(liquidity2, 0);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(forever2.poolId());
        assertEq(price, d.sqrtPriceX96, "pool initialized in the same call");

        // A salt whose address lacks the flags is refused before anything is bound.
        vm.prank(address(script));
        vm.expectRevert();
        d.stackDeployer
            .deploy(bytes32(uint256(salt) + 1), address(d.token), address(d.baazaar), address(d.escrow), 1, 0);
    }

    uint256 constant SECOND_ETH = 0.05 ether;
    uint256 constant SECOND_TOKENS = 70_000_000e18;

    /// @dev Runs the helper a second time, as the deployer, with liquidity amounts that do not match the
    /// price exactly (so the helper must return the unused side).
    function _deploySecondStack(DeployGotchiSepolia.Deployment memory d)
        internal
        returns (GotchiFeeHook hook2, ForeverLiquidity forever2, uint128 liquidity2)
    {
        bytes memory creationCode = abi.encodePacked(type(GotchiFeeHook).creationCode, abi.encode(address(manager)));
        (, bytes32 salt) = HookMiner.find(address(d.stackDeployer), 0xCC, creationCode, uint256(d.hookSalt) + 1);
        vm.startPrank(address(script));
        d.token.approve(address(d.stackDeployer), SECOND_TOKENS);
        (hook2,, forever2, liquidity2) = d.stackDeployer.deploy{value: SECOND_ETH}(
            salt, address(d.token), address(d.baazaar), address(d.escrow), d.sqrtPriceX96, SECOND_TOKENS
        );
        vm.stopPrank();
    }

    function test_stackDeployerLocksTheInitialLiquidityInTheSameCallAndRefundsDust() public {
        DeployGotchiSepolia.Deployment memory d = script.deploy(_config());
        uint256 scriptEth = address(script).balance;
        uint256 scriptTokens = d.token.balanceOf(address(script));
        (GotchiFeeHook hook2, ForeverLiquidity forever2, uint128 liquidity2) = _deploySecondStack(d);

        IPoolManager pm = IPoolManager(address(manager));
        assertGt(liquidity2, 0);
        assertEq(pm.getLiquidity(forever2.poolId()), liquidity2, "liquidity locked in the deploying call");
        (uint128 positionLiquidity,,) =
            pm.getPositionInfo(forever2.poolId(), address(forever2), -887_220, 887_220, bytes32(0));
        assertEq(positionLiquidity, liquidity2);
        assertTrue(hook2.feeSink() != address(0));
        (uint256 usedEth, uint256 usedTokens) = forever2.amountsForLiquidity(liquidity2);
        assertLe(usedEth, SECOND_ETH);
        assertLe(usedTokens, SECOND_TOKENS);
        assertEq(address(script).balance, scriptEth - usedEth, "unused ETH came back");
        assertEq(d.token.balanceOf(address(script)), scriptTokens - usedTokens, "unused tokens came back");
        assertEq(address(d.stackDeployer).balance, 0, "the helper keeps nothing");
        assertEq(d.token.balanceOf(address(d.stackDeployer)), 0);
        assertEq(d.token.balanceOf(address(forever2)), 0);
        assertEq(address(forever2).balance, 0);
    }

    function test_stackDeployerRejectsAmountsThatFundNoLiquidityAndStrayEth() public {
        DeployGotchiSepolia.Deployment memory d = script.deploy(_config());
        bytes memory creationCode = abi.encodePacked(type(GotchiFeeHook).creationCode, abi.encode(address(manager)));
        (, bytes32 salt) = HookMiner.find(address(d.stackDeployer), 0xCC, creationCode, uint256(d.hookSalt) + 1);

        // ETH only, no tokens, at a two-sided price: nothing can be locked, so nothing is deployed.
        vm.prank(address(script));
        vm.expectRevert(GotchiStackDeployer.ZeroInitialLiquidity.selector);
        d.stackDeployer.deploy{value: 1 ether}(
            salt, address(d.token), address(d.baazaar), address(d.escrow), d.sqrtPriceX96, 0
        );

        // The helper only accepts ETH from the ForeverLiquidity it is funding, inside `deploy`.
        vm.expectRevert(GotchiStackDeployer.UnexpectedEth.selector);
        (bool ok,) = address(d.stackDeployer).call{value: 1 wei}("");
        ok;
    }
}
