// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken token;
    address deployer = makeAddr("deployer");

    function setUp() public {
        vm.prank(deployer);
        token = new LaunchToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "GOTCHI");
        assertEq(token.symbol(), "GOTCHI");
        assertEq(token.decimals(), 18);
    }

    function test_mintsExactlyOneBillionToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.TOTAL_SUPPLY(), 1e27);
        assertEq(token.balanceOf(deployer), 1e27);
    }

    function test_transferMovesExactlyTheAmount() public {
        address alice = makeAddr("alice");
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1_000e18));
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.balanceOf(deployer), 1e27 - 1_000e18);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_transferFromRespectsAllowance() public {
        address spender = makeAddr("spender");
        address bob = makeAddr("bob");
        vm.prank(deployer);
        token.approve(spender, 5e18);
        vm.prank(spender);
        token.transferFrom(deployer, bob, 5e18);
        assertEq(token.balanceOf(bob), 5e18);
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(deployer, bob, 1);
    }

    function test_transferRevertsBeyondBalance() public {
        address alice = makeAddr("alice");
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(deployer, 1);
    }

    function test_noAdminOrMintSelectorChangesSupply() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "pause()",
            "setMinter(address)",
            "burn(uint256)"
        ];
        address attacker = makeAddr("attacker");
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(deployer);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), 1e27, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
    }

    function test_runtimeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory code = address(token).code;
        assertGt(code.length, 0);
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
