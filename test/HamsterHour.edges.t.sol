// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// forge-config: default.fuzz.runs = 1024

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HamsterHour} from "../src/HamsterHour.sol";

/// @dev Deploys the token through raw CREATE so the test can attach ETH to the creation, which the
/// Solidity `new` expression refuses to compile for a non-payable constructor.
contract RawCreator {
    receive() external payable {}

    function create(bytes memory code, uint256 value) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create(value, add(code, 32), mload(code))
        }
    }
}

/// @notice Inputs the happy path does not reach: the maximum, one wei off it, the same call twice,
/// callers the code never assumed, and the ways a deployment or a call can go wrong.
contract HamsterHourEdgesTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 private constant MAX = type(uint256).max;

    HamsterHour private token;
    address private alice;
    address private bob;
    address private spender;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new HamsterHour();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
    }

    // ---------------------------------------------------------------------------------------------
    // Deployment
    // ---------------------------------------------------------------------------------------------

    function test_supplyIsOneBillionWholeTokensAtTheDeclaredDecimals() public view {
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** uint256(token.decimals()));
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.INITIAL_SUPPLY(), token.totalSupply());
    }

    function test_creationCodeTakesNoConstructorArguments() public {
        RawCreator creator = new RawCreator();
        address deployed = creator.create(type(HamsterHour).creationCode, 0);
        assertTrue(deployed != address(0), "raw creation failed");
        HamsterHour raw = HamsterHour(deployed);
        assertEq(raw.name(), "Hamster Hour");
        assertEq(raw.symbol(), "HAMSTER");
        assertEq(raw.decimals(), 18);
        assertEq(raw.totalSupply(), SUPPLY);
        assertEq(raw.balanceOf(address(creator)), SUPPLY);
        assertEq(deployed.code.length, address(token).code.length, "runtime differs between deployments");
        assertEq(keccak256(deployed.code), keccak256(address(token).code));
    }

    function test_deploymentWithEthReverts() public {
        RawCreator creator = new RawCreator();
        vm.deal(address(creator), 1 ether);
        address deployed = creator.create(type(HamsterHour).creationCode, 1 wei);
        assertEq(deployed, address(0), "a non-payable constructor accepted ETH");
        assertEq(address(creator).balance, 1 ether, "the failed creation kept the ETH");
    }

    function test_independentDeploymentsDoNotShareState() public {
        vm.prank(alice);
        HamsterHour second = new HamsterHour();
        assertEq(second.balanceOf(alice), SUPPLY);
        assertEq(second.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice), 0);

        token.transfer(bob, 5 ether);
        token.approve(spender, 7 ether);
        assertEq(second.balanceOf(bob), 0);
        assertEq(second.allowance(address(this), spender), 0);
        assertEq(second.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_anyDeployerReceivesTheWholeSupply(uint256 seed) public {
        // Skip precompiles and the zero address, which cannot originate a creation on chain.
        address deployer = address(uint160(bound(seed, 1 << 20, type(uint160).max)));
        vm.prank(deployer);
        HamsterHour launched = new HamsterHour();
        assertEq(launched.balanceOf(deployer), SUPPLY);
        assertEq(launched.totalSupply(), SUPPLY);
        assertEq(launched.balanceOf(address(this)), 0);
        assertEq(launched.balanceOf(address(launched)), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Calls the token does not implement
    // ---------------------------------------------------------------------------------------------

    function test_plainEthTransferToTokenReverts() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(token).call{value: 1 wei}("");
        assertFalse(ok, "the token accepted ETH with empty calldata");
        (ok,) = address(token).call{value: 1 wei}(abi.encodeWithSelector(token.totalSupply.selector));
        assertFalse(ok, "a non-payable view accepted ETH");
        assertEq(address(token).balance, 0);
        assertEq(address(this).balance, 1 ether);
    }

    function test_emptyCalldataAndUnknownSelectorsRevert() public {
        (bool ok,) = address(token).call("");
        assertFalse(ok, "empty calldata did not revert");
        (ok,) = address(token).call(hex"deadbeef");
        assertFalse(ok, "an unknown selector did not revert");
        (ok,) = address(token)
            .call(abi.encodeWithSignature("permit(address,address,uint256,uint256,uint8,bytes32,bytes32)"));
        assertFalse(ok, "permit is not implemented but did not revert");
        (ok,) = address(token).call(abi.encodeWithSignature("increaseAllowance(address,uint256)", spender, 1));
        assertFalse(ok, "increaseAllowance is not implemented but did not revert");
        (ok,) = address(token).call(abi.encodeWithSignature("decreaseAllowance(address,uint256)", spender, 1));
        assertFalse(ok, "decreaseAllowance is not implemented but did not revert");
        assertEq(token.allowance(address(this), spender), 0);
    }

    /// @dev The launch floor's supply-growth list, tried from a stranger and from the deployer.
    function test_launchFloorSupplyGrowthCallsAllFail() public {
        address attacker = makeAddr("attacker");
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    /// @dev The launch floor's freeze-and-seize list, tried from the deployer against a holder.
    function test_launchFloorPrivilegedCallsCannotMoveOrFreezeAHolder() public {
        address holder = makeAddr("holder");
        address other = makeAddr("other");
        token.transfer(holder, SUPPLY / 1_000);
        uint256 held = token.balanceOf(holder);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], holder, true);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(holder, address(this), 1);
        assertEq(token.balanceOf(holder), held, "a privileged call moved the holder's balance");
        assertEq(token.totalSupply(), SUPPLY);

        vm.prank(holder);
        assertTrue(token.transfer(other, held / 2), "the holder can no longer transfer");
        assertEq(token.balanceOf(other), held / 2);
        assertEq(token.balanceOf(holder), held - held / 2);
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers at the edges
    // ---------------------------------------------------------------------------------------------

    function test_transferOfOneWeiAboveBalanceRevertsWithExactAmounts() public {
        token.transfer(alice, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10, 11));
        vm.prank(alice);
        token.transfer(bob, 11);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 10));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 10);
    }

    function test_transferOfMaxUintRevertsWithoutOverflow() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, MAX)
        );
        token.transfer(alice, MAX);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, MAX));
        vm.prank(alice);
        token.transfer(bob, MAX);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_emptyAccountCannotSendEvenAfterReceivingZero() public {
        token.transfer(alice, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
    }

    function test_tokensSentToTheTokenContractAreHeldAndUnrecoverable() public {
        assertTrue(token.transfer(address(token), 3 ether));
        assertEq(token.balanceOf(address(token)), 3 ether);
        assertEq(token.totalSupply(), SUPPLY);
        // No entrypoint moves them: the token never calls transfer on itself, and nobody can prank it
        // on chain. The only way out would be an allowance the contract cannot grant.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(token), alice, 1);
        (bool ok,) = address(token).call(abi.encodeWithSignature("rescue(address,uint256)", alice, 3 ether));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("recoverERC20(address,uint256)", address(token), 3 ether));
        assertFalse(ok);
        assertEq(token.balanceOf(address(token)), 3 ether);
    }

    function test_transfersToPrecompileAndContractAddressesSucceed() public {
        assertTrue(token.transfer(address(1), 1));
        assertEq(token.balanceOf(address(1)), 1);
        RawCreator sink = new RawCreator();
        assertTrue(token.transfer(address(sink), 2));
        assertEq(token.balanceOf(address(sink)), 2);
        assertEq(token.balanceOf(address(this)), SUPPLY - 3);
    }

    function test_repeatedTransfersAccumulateExactly() public {
        for (uint256 i; i < 100; ++i) {
            assertTrue(token.transfer(alice, 1));
        }
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(address(this)), SUPPLY - 100);
    }

    function test_supplySplitAcrossRecipientsSumsToSupply() public {
        uint256 n = 7;
        uint256 share = SUPPLY / n;
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            address to = address(uint160(0x1000 + i));
            uint256 amount = i == n - 1 ? SUPPLY - share * (n - 1) : share;
            assertTrue(token.transfer(to, amount));
            sum += token.balanceOf(to);
        }
        assertEq(sum, SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 1));
        token.transfer(alice, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowances at the edges
    // ---------------------------------------------------------------------------------------------

    function test_allowanceIsCheckedBeforeBalance() public {
        // alice holds nothing and allowed 5: spending 10 fails on the allowance, not the balance.
        vm.prank(alice);
        token.approve(spender, 5);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 5, 10));
        vm.prank(spender);
        token.transferFrom(alice, bob, 10);
        assertEq(token.allowance(alice, spender), 5);
    }

    function test_infiniteAllowanceDoesNotBypassBalance() public {
        vm.prank(alice);
        token.approve(spender, MAX);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(alice, spender), MAX);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_maxMinusOneAllowanceIsFinite() public {
        token.approve(spender, MAX - 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), spender), MAX - 2);
        assertEq(token.balanceOf(alice), 1);
    }

    function test_infiniteAllowanceCanBeReducedToFinite() public {
        token.approve(spender, MAX);
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
        assertEq(token.allowance(address(this), spender), MAX);
        token.approve(spender, 2);
        vm.prank(spender);
        token.transferFrom(address(this), alice, 2);
        assertEq(token.allowance(address(this), spender), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
    }

    function test_holderMayApproveThemselvesAndSpendIt() public {
        token.transfer(alice, 10);
        vm.prank(alice);
        token.approve(alice, 4);
        vm.prank(alice);
        assertTrue(token.transferFrom(alice, bob, 4));
        assertEq(token.allowance(alice, alice), 0);
        assertEq(token.balanceOf(alice), 6);
        assertEq(token.balanceOf(bob), 4);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(alice, bob, 1);
    }

    function test_transferFromDoesNotEmitApproval() public {
        token.approve(spender, 10);
        vm.recordLogs();
        vm.prank(spender);
        token.transferFrom(address(this), alice, 4);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "transferFrom emitted more than the Transfer event");
        assertEq(logs[0].topics[0], Transfer.selector);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), address(this));
        assertEq(address(uint160(uint256(logs[0].topics[2]))), alice);
        assertEq(abi.decode(logs[0].data, (uint256)), 4);
    }

    function test_allowanceOfZeroOwnerIsAlwaysZeroAndCannotBeSet() public view {
        assertEq(token.allowance(address(0), spender), 0);
        assertEq(token.allowance(address(0), address(0)), 0);
    }

    function test_transferFromZeroSenderRevertsBeforeAnything() public {
        vm.prank(alice);
        token.approve(spender, MAX);
        // Nobody can grant an allowance for the zero address, so a nonzero spend fails there first.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(0), alice, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(0), address(0), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_approveSameValueTwiceIsIdempotentAndStillEmits() public {
        token.approve(spender, 9);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), spender, 9);
        assertTrue(token.approve(spender, 9));
        assertEq(token.allowance(address(this), spender), 9);
    }

    function test_approvalIsDirectional() public {
        token.approve(spender, 10);
        assertEq(token.allowance(spender, address(this)), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(spender, alice, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzzed properties
    // ---------------------------------------------------------------------------------------------

    function testFuzz_approveRecordsExactlyAnyValue(uint256 value, uint256 replacement) public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), spender, value);
        assertTrue(token.approve(spender, value));
        assertEq(token.allowance(address(this), spender), value);
        assertTrue(token.approve(spender, replacement));
        assertEq(token.allowance(address(this), spender), replacement);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testFuzz_roundTripRestoresBothBalances(uint256 rawFunding, uint256 rawAmount) public {
        uint256 funding = bound(rawFunding, 0, SUPPLY);
        uint256 amount = bound(rawAmount, 0, funding);
        token.transfer(alice, funding);
        vm.prank(alice);
        token.transfer(bob, amount);
        vm.prank(bob);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), funding);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - funding);
    }

    function testFuzz_holderCannotSendMoreThanHeld(uint256 rawFunding, uint256 rawExcess) public {
        uint256 funding = bound(rawFunding, 0, SUPPLY - 1);
        uint256 amount = bound(rawExcess, funding + 1, MAX);
        token.transfer(alice, funding);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, funding, amount));
        vm.prank(alice);
        token.transfer(bob, amount);
        assertEq(token.balanceOf(alice), funding);
        assertEq(token.balanceOf(bob), 0);
    }

    function testFuzz_splitSpendsConsumeExactlyTheirSum(uint256 rawApproved, uint256 rawA, uint256 rawB) public {
        uint256 approved = bound(rawApproved, 0, SUPPLY);
        uint256 a = bound(rawA, 0, approved);
        uint256 b = bound(rawB, 0, approved - a);
        token.approve(spender, approved);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(address(this), alice, a));
        assertTrue(token.transferFrom(address(this), bob, b));
        vm.stopPrank();
        assertEq(token.allowance(address(this), spender), approved - a - b);
        assertEq(token.balanceOf(alice), a);
        assertEq(token.balanceOf(bob), b);
        assertEq(token.balanceOf(address(this)), SUPPLY - a - b);
        if (approved - a - b < SUPPLY - a - b) {
            uint256 over = approved - a - b + 1;
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved - a - b, over
                )
            );
            vm.prank(spender);
            token.transferFrom(address(this), alice, over);
        }
    }

    function testFuzz_infiniteAllowanceSpendsAnyAmountUpToBalance(uint256 rawFunding, uint256 rawAmount) public {
        uint256 funding = bound(rawFunding, 0, SUPPLY);
        uint256 amount = bound(rawAmount, 0, funding);
        token.transfer(alice, funding);
        vm.prank(alice);
        token.approve(spender, MAX);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, amount));
        assertEq(token.allowance(alice, spender), MAX);
        assertEq(token.balanceOf(alice), funding - amount);
        assertEq(token.balanceOf(bob), amount);
        if (amount < funding) return;
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
    }

    function testFuzz_transferEventCarriesExactArguments(uint256 rawAmount, uint256 seed) public {
        address to = address(uint160(bound(seed, 1, type(uint160).max)));
        if (to == address(this)) to = alice;
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(address(this), to, amount);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
    }

    function testFuzz_selfTransferOfAnyAmountUpToBalanceIsANoOp(uint256 rawFunding, uint256 rawAmount) public {
        uint256 funding = bound(rawFunding, 0, SUPPLY);
        uint256 amount = bound(rawAmount, 0, funding);
        token.transfer(alice, funding);
        vm.prank(alice);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), funding);
        if (funding == SUPPLY) return;
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, funding, funding + 1)
        );
        vm.prank(alice);
        token.transfer(alice, funding + 1);
    }
}
