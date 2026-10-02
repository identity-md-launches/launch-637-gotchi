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

/// @title DeployGotchiSepolia
/// @notice Optional Sepolia deployment of the whole $GOTCHI stack: token, hook (CREATE2, address mined
/// to carry its permission bits), mock NFT, mock Baazaar, picker, escrow, FeeSink and ForeverLiquidity,
/// then pool initialization and the initial forever liquidity.
///
/// Usage (simulate first, then broadcast from a reviewed signer):
///
///   forge script script/DeployGotchiSepolia.s.sol --rpc-url $SEPOLIA_RPC
///   forge script script/DeployGotchiSepolia.s.sol --rpc-url $SEPOLIA_RPC --broadcast --verify
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
        address create2Deployer;
        address operator;
        address minter;
        uint256 initialLiquidityEth;
        uint256 initialLiquidityTokens;
    }

    struct Deployment {
        LaunchToken token;
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
    /// @dev Deterministic deployment proxy (Arachnid), present on Sepolia and used by forge for `new{salt:}`.
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Default initial liquidity: 0.1 ETH against 10% of the supply (100,000,000 GOTCHI),
    /// i.e. 1,000,000,000 GOTCHI per ETH and an implied market cap of 1 ETH. Configurable.
    uint256 public constant DEFAULT_INITIAL_ETH = 0.1 ether;
    uint256 public constant DEFAULT_INITIAL_TOKENS = 100_000_000e18;

    /// @dev `ForeverLiquidity.addLiquidity` refunds rounding dust to its caller; when the tests call
    /// `deploy` directly that caller is this contract.
    receive() external payable {}

    function run() external returns (Deployment memory deployment) {
        require(block.chainid == SEPOLIA_CHAIN_ID, "Sepolia only");
        require(SEPOLIA_POOL_MANAGER.code.length != 0, "PoolManager has no code");
        require(CREATE2_DEPLOYER.code.length != 0, "CREATE2 deployer missing");

        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        Config memory cfg = Config({
            poolManager: SEPOLIA_POOL_MANAGER,
            create2Deployer: CREATE2_DEPLOYER,
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
    /// PoolManager with `cfg.create2Deployer == address(this script)`.
    function deploy(Config memory cfg) public returns (Deployment memory d) {
        require(cfg.poolManager != address(0), "pool manager");
        require(cfg.operator != address(0) && cfg.minter != address(0), "roles");

        d.token = new LaunchToken();

        // Hook: CREATE2 at an address carrying exactly 0xCC.
        bytes memory creationCode = abi.encodePacked(type(GotchiFeeHook).creationCode, abi.encode(cfg.poolManager));
        (address predicted, bytes32 salt) = HookMiner.find(
            cfg.create2Deployer, GotchiFeeHookFlags.FLAGS, creationCode, _firstFreeSalt(cfg, creationCode)
        );
        d.hookSalt = salt;
        d.hook = new GotchiFeeHook{salt: salt}(cfg.poolManager);
        require(address(d.hook) == predicted, "hook address differs from the mined one");
        require(d.hook.addressHasValidFlags(), "hook address lacks its flags");

        d.nft = new MockAavegotchi(cfg.minter);
        d.baazaar = new MockBaazaar(address(d.nft));
        d.picker = new HolderWeightedPicker(address(d.token), cfg.poolManager);
        d.escrow = new FlipEscrow(address(d.nft), address(d.baazaar), address(d.picker), cfg.operator);
        d.sink = new FeeSink(address(d.hook), address(d.baazaar), address(d.escrow));
        require(d.hook.feeSink() == address(d.sink), "sink binding was front-run; redeploy");
        d.forever = new ForeverLiquidity(address(d.token), cfg.poolManager, address(d.hook));
        d.key = d.forever.poolKey();

        // Pool: price from the configured amounts, then the initial forever liquidity.
        d.sqrtPriceX96 = d.forever.sqrtPriceX96ForAmounts(cfg.initialLiquidityEth, cfg.initialLiquidityTokens);
        d.forever.initializePool(d.sqrtPriceX96);
        d.liquidity = d.forever.liquidityForAmounts(cfg.initialLiquidityEth, cfg.initialLiquidityTokens);
        d.token.approve(address(d.forever), cfg.initialLiquidityTokens);
        d.forever.addLiquidity{value: cfg.initialLiquidityEth}(d.liquidity, cfg.initialLiquidityTokens);
    }

    /// @dev Skips salts whose predicted address already has code (a previous run of this script).
    function _firstFreeSalt(Config memory cfg, bytes memory creationCode) private view returns (uint256 start) {
        while (true) {
            (address predicted, bytes32 salt) =
                HookMiner.find(cfg.create2Deployer, GotchiFeeHookFlags.FLAGS, creationCode, start);
            if (predicted.code.length == 0) return start;
            start = uint256(salt) + 1;
        }
    }

    function _log(Deployment memory d) private pure {
        console2.log("LaunchToken (GOTCHI) :", address(d.token));
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
