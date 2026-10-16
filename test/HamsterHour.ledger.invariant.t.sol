// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HamsterHour} from "../src/HamsterHour.sol";

/// @notice Drives the token with random, bounded calls from several holders and keeps its own
/// ledger of what every balance and allowance should be. Every failure path is attempted too,
/// inside try/catch, and each must revert with the exact ERC-6093 error and leave nothing behind.
contract LedgerHandler is Test {
    uint256 internal constant MAX = type(uint256).max;

    HamsterHour public immutable token;

    /// @dev Holders who can send: ordinary accounts.
    address[6] public holders;
    /// @dev Everyone who may hold a balance: the holders, the token itself, and a precompile sink.
    address[8] public tracked;

    mapping(address => uint256) public ghostBalance;
    mapping(address => uint256) public ghostReceived;
    mapping(address => uint256) public ghostSent;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    uint256 public ghostStuckInToken;
    uint256 public ghostTransferred;

    uint256 public successfulTransfers;
    uint256 public successfulApprovals;
    uint256 public successfulDelegatedTransfers;
    uint256 public rejectedCalls;

    constructor(HamsterHour token_) {
        token = token_;
        for (uint256 i; i < holders.length; ++i) {
            holders[i] = makeAddr(string.concat("holder ", vm.toString(i)));
            tracked[i] = holders[i];
        }
        tracked[6] = address(token_);
        tracked[7] = address(1);
    }

    /// @dev Called once after the test has distributed the supply, so the ledger starts in sync.
    function syncInitial() external {
        for (uint256 i; i < tracked.length; ++i) {
            uint256 held = token.balanceOf(tracked[i]);
            ghostBalance[tracked[i]] = held;
            ghostReceived[tracked[i]] = held;
        }
        ghostStuckInToken = token.balanceOf(address(token));
    }

    // ---------------------------------------------------------------------------------------------
    // Happy paths
    // ---------------------------------------------------------------------------------------------

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = holders[fromSeed % holders.length];
        address to = tracked[toSeed % tracked.length];
        uint256 amount = bound(amountSeed, 0, ghostBalance[from]);

        vm.prank(from);
        bool ok = token.transfer(to, amount);
        assertTrue(ok, "transfer returned false");
        _recordMove(from, to, amount);
        successfulTransfers++;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = holders[ownerSeed % holders.length];
        address spender = holders[spenderSeed % holders.length];

        vm.prank(owner);
        bool ok = token.approve(spender, amount);
        assertTrue(ok, "approve returned false");
        ghostAllowance[owner][spender] = amount;
        successfulApprovals++;
    }

    function transferFrom(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = holders[fromSeed % holders.length];
        address spender = holders[spenderSeed % holders.length];
        address to = tracked[toSeed % tracked.length];
        uint256 allowed = ghostAllowance[from][spender];
        uint256 cap = ghostBalance[from] < allowed ? ghostBalance[from] : allowed;
        uint256 amount = bound(amountSeed, 0, cap);

        vm.prank(spender);
        bool ok = token.transferFrom(from, to, amount);
        assertTrue(ok, "transferFrom returned false");
        _recordMove(from, to, amount);
        if (allowed != MAX) ghostAllowance[from][spender] = allowed - amount;
        successfulDelegatedTransfers++;
    }

    // ---------------------------------------------------------------------------------------------
    // Failure paths: each must revert with the exact error and change nothing
    // ---------------------------------------------------------------------------------------------

    function transferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 excessSeed) external {
        address from = holders[fromSeed % holders.length];
        address to = tracked[toSeed % tracked.length];
        uint256 held = ghostBalance[from];
        uint256 amount = held + bound(excessSeed, 1, MAX - held);

        vm.prank(from);
        try token.transfer(to, amount) {
            assertTrue(false, "transfer above balance succeeded");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount));
        }
        _assertUntouched(from, to);
        rejectedCalls++;
    }

    function transferToZero(uint256 fromSeed, uint256 amountSeed) external {
        address from = holders[fromSeed % holders.length];
        uint256 amount = bound(amountSeed, 0, ghostBalance[from]);

        vm.prank(from);
        try token.transfer(address(0), amount) {
            assertTrue(false, "transfer to the zero address succeeded");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        }
        _assertUntouched(from, from);
        assertEq(token.balanceOf(address(0)), 0);
        rejectedCalls++;
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = holders[ownerSeed % holders.length];
        vm.prank(owner);
        try token.approve(address(0), amount) {
            assertTrue(false, "approve of the zero spender succeeded");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        }
        assertEq(token.allowance(owner, address(0)), 0);
        rejectedCalls++;
    }

    function transferFromAboveAllowance(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 excessSeed)
        external
    {
        address from = holders[fromSeed % holders.length];
        address spender = holders[spenderSeed % holders.length];
        address to = tracked[toSeed % tracked.length];
        uint256 allowed = ghostAllowance[from][spender];
        uint256 held = ghostBalance[from];

        bytes memory expected;
        uint256 amount;
        if (allowed == MAX) {
            // Unlimited allowance: the only way to fail is the balance.
            amount = held + bound(excessSeed, 1, MAX - held);
            expected = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount);
        } else {
            amount = allowed + bound(excessSeed, 1, MAX - allowed);
            expected =
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount);
        }

        vm.prank(spender);
        try token.transferFrom(from, to, amount) {
            assertTrue(false, "transferFrom above allowance or balance succeeded");
        } catch (bytes memory reason) {
            assertEq(reason, expected);
        }
        _assertUntouched(from, to);
        assertEq(token.allowance(from, spender), allowed, "a failed transferFrom changed the allowance");
        rejectedCalls++;
    }

    function transferFromWithoutBalance(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 excessSeed)
        external
    {
        // Allowance covers it, balance does not: the allowance must survive the failed spend.
        address from = holders[fromSeed % holders.length];
        address spender = holders[spenderSeed % holders.length];
        address to = tracked[toSeed % tracked.length];
        uint256 allowed = ghostAllowance[from][spender];
        uint256 held = ghostBalance[from];
        if (allowed <= held) return;
        uint256 amount = held + bound(excessSeed, 1, allowed - held);

        vm.prank(spender);
        try token.transferFrom(from, to, amount) {
            assertTrue(false, "transferFrom above balance succeeded");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount));
        }
        _assertUntouched(from, to);
        assertEq(token.allowance(from, spender), allowed, "a failed transferFrom changed the allowance");
        rejectedCalls++;
    }

    function unsupportedCall(uint256 callerSeed, uint256 targetSeed, uint256 sigSeed) external {
        address caller = holders[callerSeed % holders.length];
        address target = holders[targetSeed % holders.length];
        string[14] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "seize(address)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "increaseAllowance(address,uint256)"
        ];
        bytes memory data = abi.encodeWithSignature(signatures[sigSeed % signatures.length], target, MAX);

        uint256 supplyBefore = token.totalSupply();
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        assertFalse(ok, "an unsupported call succeeded");
        assertEq(token.totalSupply(), supplyBefore);
        _assertUntouched(caller, target);
        rejectedCalls++;
    }

    function sendEth(uint256 fromSeed, uint256 amountSeed) external {
        address from = holders[fromSeed % holders.length];
        uint256 amount = bound(amountSeed, 1, 1_000 ether);
        vm.deal(from, amount);
        vm.prank(from);
        (bool ok,) = address(token).call{value: amount}("");
        assertFalse(ok, "the token accepted ETH");
        assertEq(address(token).balance, 0);
        assertEq(from.balance, amount);
        rejectedCalls++;
    }

    // ---------------------------------------------------------------------------------------------
    // Ledger helpers
    // ---------------------------------------------------------------------------------------------

    function _recordMove(address from, address to, uint256 amount) private {
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostSent[from] += amount;
        ghostReceived[to] += amount;
        ghostTransferred += amount;
        if (to == address(token) && from != address(token)) ghostStuckInToken += amount;
    }

    function _assertUntouched(address a, address b) private view {
        assertEq(token.balanceOf(a), ghostBalance[a], "a failed call changed a balance");
        assertEq(token.balanceOf(b), ghostBalance[b], "a failed call changed a balance");
    }

    function holderCount() external pure returns (uint256) {
        return 6;
    }

    function trackedCount() external pure returns (uint256) {
        return 8;
    }
}

/// @notice Invariants a fixed-supply token must keep under any sequence of calls: the supply is
/// constant, the token's own view of every balance and allowance equals a ledger kept outside it,
/// nobody sends more than they received, what reaches the token contract never leaves, and the
/// failure paths leave no trace.
contract HamsterHourLedgerInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;

    HamsterHour private token;
    LedgerHandler private handler;

    function setUp() public {
        token = new HamsterHour();
        handler = new LedgerHandler(token);

        // Uneven initial distribution: one whale, a few small holders, one empty, and a wei already
        // stuck in the token so that sink is live from the first call.
        uint256 n = handler.holderCount();
        for (uint256 i = 1; i < n - 1; ++i) {
            token.transfer(handler.holders(i), (SUPPLY / 1_000) * i);
        }
        token.transfer(address(token), 1);
        token.transfer(handler.holders(0), token.balanceOf(address(this)));
        handler.syncInitial();

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = LedgerHandler.transfer.selector;
        selectors[1] = LedgerHandler.approve.selector;
        selectors[2] = LedgerHandler.transferFrom.selector;
        selectors[3] = LedgerHandler.transferAboveBalance.selector;
        selectors[4] = LedgerHandler.transferToZero.selector;
        selectors[5] = LedgerHandler.approveZeroSpender.selector;
        selectors[6] = LedgerHandler.transferFromAboveAllowance.selector;
        selectors[7] = LedgerHandler.transferFromWithoutBalance.selector;
        selectors[8] = LedgerHandler.unsupportedCall.selector;
        selectors[9] = LedgerHandler.sendEth.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_totalSupplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
    }

    function invariant_trackedBalancesSumToSupply() public view {
        uint256 sum;
        uint256 n = handler.trackedCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.tracked(i));
        }
        assertEq(sum, SUPPLY, "value leaked outside the tracked set");
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function invariant_balancesMatchTheLedger() public view {
        uint256 n = handler.trackedCount();
        for (uint256 i; i < n; ++i) {
            address who = handler.tracked(i);
            assertEq(token.balanceOf(who), handler.ghostBalance(who), "balance diverged from the ledger");
            assertEq(
                handler.ghostBalance(who),
                handler.ghostReceived(who) - handler.ghostSent(who),
                "balance is not received minus sent"
            );
            assertLe(handler.ghostSent(who), handler.ghostReceived(who), "a holder sent more than they received");
            assertLe(token.balanceOf(who), SUPPLY);
        }
    }

    function invariant_allowancesMatchTheLedger() public view {
        uint256 n = handler.holderCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.holders(i);
                address spender = handler.holders(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender));
            }
            assertEq(token.allowance(handler.holders(i), address(0)), 0);
            assertEq(token.allowance(address(0), handler.holders(i)), 0);
        }
    }

    function invariant_whatReachesTheTokenNeverLeaves() public view {
        assertEq(token.balanceOf(address(token)), handler.ghostStuckInToken());
        assertGe(handler.ghostStuckInToken(), 1, "the stuck balance decreased");
    }

    function invariant_tokenHoldsNoEth() public view {
        assertEq(address(token).balance, 0);
    }

    function afterInvariant() public view {
        // A run that never reached a failure path would prove nothing about them.
        assertGt(handler.rejectedCalls(), 0, "no failure path was exercised");
        assertGt(handler.successfulTransfers() + handler.successfulDelegatedTransfers(), 0, "no transfer was exercised");
    }
}
