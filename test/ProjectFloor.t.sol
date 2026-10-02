// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {GotchiFeeHook} from "../src/GotchiFeeHook.sol";
import {FeeSink} from "../src/FeeSink.sol";
import {MockAavegotchi} from "../src/MockAavegotchi.sol";
import {MockBaazaar} from "../src/MockBaazaar.sol";
import {FlipEscrow} from "../src/FlipEscrow.sol";
import {HolderWeightedPicker} from "../src/HolderWeightedPicker.sol";
import {ForeverLiquidity} from "../src/ForeverLiquidity.sol";

/// @notice Mirrors the launch floor: every application contract deploys from a nonpayable constructor
/// with address-only arguments against the literal Sepolia PoolManager, never touches the token supply,
/// fits EIP-170 and contains no DELEGATECALL / CALLCODE / SELFDESTRUCT.
contract ProjectFloorTest is Test {
    address constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address deployer = makeAddr("factory");
    address owner = makeAddr("owner");

    address[] contracts;
    LaunchToken token;

    function setUp() public {
        vm.startPrank(deployer);
        token = new LaunchToken();
        GotchiFeeHook hook = new GotchiFeeHook(SEPOLIA_POOL_MANAGER);
        MockAavegotchi nft = new MockAavegotchi(owner);
        MockBaazaar baazaar = new MockBaazaar(address(nft));
        HolderWeightedPicker picker = new HolderWeightedPicker(address(token), SEPOLIA_POOL_MANAGER);
        FlipEscrow escrow = new FlipEscrow(address(nft), address(baazaar), address(picker), owner);
        FeeSink sink = new FeeSink(address(hook), address(baazaar), address(escrow));
        ForeverLiquidity forever = new ForeverLiquidity(address(token), SEPOLIA_POOL_MANAGER, address(hook));
        vm.stopPrank();

        contracts.push(address(token));
        contracts.push(address(hook));
        contracts.push(address(nft));
        contracts.push(address(baazaar));
        contracts.push(address(picker));
        contracts.push(address(escrow));
        contracts.push(address(sink));
        contracts.push(address(forever));
    }

    function test_constructorsLeaveTheWholeSupplyWithTheDeployer() public view {
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(deployer), 1e27);
    }

    function test_runtimeIsPresentBoundedAndHasNoEscapeOpcodes() public view {
        for (uint256 i = 0; i < contracts.length; i++) {
            bytes memory code = contracts[i].code;
            assertGt(code.length, 0, "missing runtime");
            assertLe(code.length, 24_576, "runtime exceeds EIP-170");
            for (uint256 j = 0; j < code.length; j++) {
                uint8 op = uint8(code[j]);
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden project opcode");
            }
        }
    }

    function test_hookDeployedAgainstTheLiteralSepoliaManagerIsWiredAndGated() public {
        GotchiFeeHook hook = GotchiFeeHook(contracts[1]);
        assertEq(address(hook.POOL_MANAGER()), SEPOLIA_POOL_MANAGER);
        assertEq(hook.feeSink(), contracts[6], "the FeeSink bound itself from its constructor");
        vm.expectRevert(abi.encodeWithSelector(GotchiFeeHook.FeeSinkAlreadyBound.selector, contracts[6]));
        hook.bindFeeSink();
        PoolKey memory key = ForeverLiquidity(payable(contracts[7])).poolKey();
        vm.expectRevert(GotchiFeeHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, SwapParamsLib.any(), BalanceDelta.wrap(0), "");
    }
}

library SwapParamsLib {
    function any() internal pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
    }
}
