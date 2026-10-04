// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";

/// @notice ERC-20 edges for GOTCHI: conservation under random transfers, self and zero transfers, the
/// zero address, and allowance semantics.
/// forge-config: default.fuzz.runs = 1000
contract TokenEdgeTest is Test {
    LaunchToken token;
    address deployer = makeAddr("deployer");

    function setUp() public {
        vm.prank(deployer);
        token = new LaunchToken();
    }

    function testFuzz_transferConservesSupplyAndMovesExactly(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, token.totalSupply());
        uint256 fromBefore = token.balanceOf(deployer);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        if (to == deployer) {
            assertEq(token.balanceOf(deployer), fromBefore, "self transfer changes nothing");
        } else {
            assertEq(token.balanceOf(deployer), fromBefore - amount);
            assertEq(token.balanceOf(to), toBefore + amount);
        }
        assertEq(token.totalSupply(), 1e27, "supply is fixed");
    }

    function testFuzz_transferBeyondBalanceReverts(uint256 amount) public {
        amount = bound(amount, 1, type(uint256).max - 1e27);
        address alice = makeAddr("alice");
        vm.prank(deployer);
        token.transfer(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1e18, 1e18 + amount)
        );
        token.transfer(deployer, 1e18 + amount);
    }

    function test_zeroAmountTransferIsAllowedAndMovesNothing() public {
        address alice = makeAddr("alice");
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 0));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(deployer), 1e27);
    }

    function test_transferToTheZeroAddressReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        address spender = makeAddr("spender");
        address bob = makeAddr("bob");
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(deployer, bob, 5e18);
        assertEq(token.allowance(deployer, spender), type(uint256).max);
        assertEq(token.balanceOf(bob), 5e18);
    }

    function test_finiteAllowanceIsDecrementedAndThenExhausted() public {
        address spender = makeAddr("spender");
        address bob = makeAddr("bob");
        vm.prank(deployer);
        token.approve(spender, 5e18);
        vm.prank(spender);
        token.transferFrom(deployer, bob, 3e18);
        assertEq(token.allowance(deployer, spender), 2e18);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 2e18, 2e18 + 1)
        );
        token.transferFrom(deployer, bob, 2e18 + 1);
        vm.prank(spender);
        token.transferFrom(deployer, bob, 2e18);
        assertEq(token.allowance(deployer, spender), 0);
        assertEq(token.balanceOf(bob), 5e18);
    }

    function test_transferFromWithoutAnyAllowanceReverts() public {
        address spender = makeAddr("spender");
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(deployer, spender, 1);
    }

    function test_approvingTheZeroAddressReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_everyDeploymentMintsToItsOwnDeployer() public {
        address other = makeAddr("other");
        vm.prank(other);
        LaunchToken second = new LaunchToken();
        assertEq(second.balanceOf(other), 1e27);
        assertEq(second.balanceOf(deployer), 0);
        assertEq(token.balanceOf(other), 0, "deployments do not share state");
    }
}
