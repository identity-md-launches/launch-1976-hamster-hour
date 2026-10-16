// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HamsterHour} from "../src/HamsterHour.sol";

/// @dev Exercises arbitrary sequences among a closed set of holders, including self-transfers.
contract HamsterHandler is Test {
    HamsterHour public immutable token;
    address[4] public actors;

    constructor(HamsterHour token_) {
        token = token_;
        actors[0] = makeAddr("holder 0");
        actors[1] = makeAddr("holder 1");
        actors[2] = makeAddr("holder 2");
        actors[3] = makeAddr("holder 3");
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 beforeFrom = token.balanceOf(from);
        uint256 beforeTo = token.balanceOf(to);
        uint256 amount = bound(amountSeed, 0, beforeFrom);

        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _assertBalances(from, to, beforeFrom, beforeTo, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];

        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(owner, spender), amount);
    }

    function transferFrom(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 beforeFrom = token.balanceOf(from);
        uint256 beforeTo = token.balanceOf(to);
        uint256 allowed = token.allowance(from, spender);
        uint256 amount = bound(amountSeed, 0, beforeFrom < allowed ? beforeFrom : allowed);

        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        _assertBalances(from, to, beforeFrom, beforeTo, amount);
        assertEq(token.allowance(from, spender), allowed == type(uint256).max ? allowed : allowed - amount);
    }

    function _assertBalances(address from, address to, uint256 beforeFrom, uint256 beforeTo, uint256 amount)
        private
        view
    {
        if (from == to) {
            assertEq(token.balanceOf(from), beforeFrom);
        } else {
            assertEq(token.balanceOf(from), beforeFrom - amount);
            assertEq(token.balanceOf(to), beforeTo + amount);
        }
    }
}

contract HamsterHourInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    HamsterHour private token;
    HamsterHandler private handler;

    function setUp() public {
        token = new HamsterHour();
        handler = new HamsterHandler(token);
        token.transfer(handler.actors(0), SUPPLY);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = HamsterHandler.transfer.selector;
        selectors[1] = HamsterHandler.approve.selector;
        selectors[2] = HamsterHandler.transferFrom.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_supplyAndAggregateBalancesRemainFixed() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }
}
