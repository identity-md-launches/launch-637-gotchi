// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {LaunchToken} from "../src/LaunchToken.sol";
import {GotchiFeeHook} from "../src/GotchiFeeHook.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {FeeSink} from "../src/FeeSink.sol";
import {MockAavegotchi} from "../src/MockAavegotchi.sol";
import {MockBaazaar} from "../src/MockBaazaar.sol";
import {FlipEscrow} from "../src/FlipEscrow.sol";
import {HolderWeightedPicker} from "../src/HolderWeightedPicker.sol";
import {ForeverLiquidity} from "../src/ForeverLiquidity.sol";
import {GotchiStackDeployer} from "../src/GotchiStackDeployer.sol";
import {PriceMath} from "../src/PriceMath.sol";

/// @title DeployGotchiSepolia
/// @notice Optional Sepolia deployment of the whole $GOTCHI stack: token, mock NFT, mock Baazaar, picker,
/// escrow, then (in one transaction through `GotchiStackDeployer`) the hook at a mined CREATE2 address,
/// the FeeSink bound to it, ForeverLiquidity, the pool initialization and the initial forever liquidity
/// behind an exact-price guard. Only the token approval to the helper is a separate, harmless transaction.
///
/// Usage (simulate first, then broadcast from a reviewed signer, one transaction at a time):
///
///   forge script script/DeployGotchiSepolia.s.sol --rpc-url $SEPOLIA_RPC
///   forge script script/DeployGotchiSepolia.s.sol --rpc-url $SEPOLIA_RPC --broadcast --slow --verify
///
/// `--slow` waits for each receipt before sending the next transaction; a failed receipt stops the run
/// instead of letting later transactions build on a broken step.
///
/// Environment (all optional):
///   GOTCHI_OPERATOR        commit-reveal operator (default: the broadcaster)
///   GOTCHI_MINTER          mock NFT minter (default: the broadcaster)
///   GOTCHI_INITIAL_ETH     initial liquidity in wei (default: 0.1 ether)
///   GOTCHI_INITIAL_TOKENS  initial liquidity in GOTCHI minor units (default: 100,000,000 GOTCHI)
///
/// The broadcaster must hold GOTCHI_INITIAL_ETH plus gas. It receives the whole token supply, so it
/// also pays the token side. This script authorizes nothing by itself; the broadcasting wallet and its
/// funding are the operator's responsibility.
contract DeployGotchiSepolia is Script {
    struct Config {
        address poolManager;
        address operator;
        address minter;
        uint256 initialLiquidityEth;
        uint256 initialLiquidityTokens;
    }

    struct Deployment {
        LaunchToken token;
        GotchiStackDeployer stackDeployer;
        GotchiFeeHook hook;
        bytes32 hookSalt;
        MockAavegotchi nft;
        MockBaazaar baazaar;
        HolderWeightedPicker picker;
        FlipEscrow escrow;
        FeeSink sink;
        ForeverLiquidity forever;
        PoolKey key;
        uint160 sqrtPriceX96;
        uint128 liquidity;
    }

    /// @dev Uniswap v4 PoolManager on Sepolia (chainId 11155111).
    address public constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;

    /// @notice Default initial liquidity: 0.1 ETH against 10% of the supply (100,000,000 GOTCHI),
    /// i.e. 1,000,000,000 GOTCHI per ETH and an implied market cap of 1 ETH. Configurable.
    uint256 public constant DEFAULT_INITIAL_ETH = 0.1 ether;
    uint256 public constant DEFAULT_INITIAL_TOKENS = 100_000_000e18;

    /// @dev `GotchiStackDeployer.deploy` refunds rounding dust to its caller; when the tests call `deploy`
    /// directly that caller is this contract.
    receive() external payable {}

    function run() external returns (Deployment memory deployment) {
        require(block.chainid == SEPOLIA_CHAIN_ID, "Sepolia only");
        require(SEPOLIA_POOL_MANAGER.code.length != 0, "PoolManager has no code");

        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        Config memory cfg = Config({
            poolManager: SEPOLIA_POOL_MANAGER,
            operator: vm.envOr("GOTCHI_OPERATOR", broadcaster),
            minter: vm.envOr("GOTCHI_MINTER", broadcaster),
            initialLiquidityEth: vm.envOr("GOTCHI_INITIAL_ETH", DEFAULT_INITIAL_ETH),
            initialLiquidityTokens: vm.envOr("GOTCHI_INITIAL_TOKENS", DEFAULT_INITIAL_TOKENS)
        });
        deployment = deploy(cfg);
        vm.stopBroadcast();

        _log(deployment);
    }

    /// @notice Deploys and wires everything for `cfg`. Tests call this directly against a local
    /// PoolManager.
    function deploy(Config memory cfg) public returns (Deployment memory d) {
        require(cfg.poolManager != address(0), "pool manager");
        require(cfg.operator != address(0) && cfg.minter != address(0), "roles");

        d.token = new LaunchToken();
        d.nft = new MockAavegotchi(cfg.minter);
        d.baazaar = new MockBaazaar(address(d.nft));
        d.picker = new HolderWeightedPicker(address(d.token), cfg.poolManager);
        d.escrow = new FlipEscrow(address(d.nft), address(d.baazaar), address(d.picker), cfg.operator);

        // Hook + FeeSink + ForeverLiquidity + pool initialization + initial liquidity, atomically. The hook's
        // CREATE2 address depends on the fresh helper's address, so a salt mined against it is unused by
        // construction. The pool never exists without liquidity, so nobody can move its price before the
        // exact-band deposit lands.
        d.stackDeployer = new GotchiStackDeployer(cfg.poolManager);
        bytes memory creationCode = abi.encodePacked(type(GotchiFeeHook).creationCode, abi.encode(cfg.poolManager));
        (address predicted, bytes32 salt) =
            HookMiner.find(address(d.stackDeployer), GotchiFeeHookFlags.FLAGS, creationCode, 0);
        d.hookSalt = salt;
        d.sqrtPriceX96 = _sqrtPriceFor(cfg);
        d.token.approve(address(d.stackDeployer), cfg.initialLiquidityTokens);
        (d.hook, d.sink, d.forever, d.liquidity) = d.stackDeployer.deploy{value: cfg.initialLiquidityEth}(
            salt, address(d.token), address(d.baazaar), address(d.escrow), d.sqrtPriceX96, cfg.initialLiquidityTokens
        );
        require(address(d.hook) == predicted, "hook address differs from the mined one");
        require(d.hook.addressHasValidFlags(), "hook address lacks its flags");
        require(d.hook.feeSink() == address(d.sink), "sink is not bound to the hook");
        require(d.liquidity > 0, "no initial liquidity");
        d.key = d.forever.poolKey();
    }

    /// @dev The opening price implied by the configured amounts, computed with the same library
    /// `ForeverLiquidity.sqrtPriceX96ForAmounts` uses (that contract does not exist yet at this point).
    function _sqrtPriceFor(Config memory cfg) private pure returns (uint160) {
        return PriceMath.sqrtPriceX96ForAmounts(cfg.initialLiquidityEth, cfg.initialLiquidityTokens);
    }

    function _log(Deployment memory d) private pure {
        console2.log("LaunchToken (GOTCHI) :", address(d.token));
        console2.log("GotchiStackDeployer  :", address(d.stackDeployer));
        console2.log("GotchiFeeHook        :", address(d.hook));
        console2.log("  hook CREATE2 salt  :", uint256(d.hookSalt));
        console2.log("MockAavegotchi       :", address(d.nft));
        console2.log("MockBaazaar          :", address(d.baazaar));
        console2.log("HolderWeightedPicker :", address(d.picker));
        console2.log("FlipEscrow           :", address(d.escrow));
        console2.log("FeeSink              :", address(d.sink));
        console2.log("ForeverLiquidity     :", address(d.forever));
        console2.log("pool sqrtPriceX96    :", uint256(d.sqrtPriceX96));
        console2.log("pool liquidity       :", uint256(d.liquidity));
    }
}

/// @dev The permission bits the hook address must carry, duplicated here so the miner does not need an
/// instance of the hook.
library GotchiFeeHookFlags {
    uint160 internal constant FLAGS = 0xCC;
}
