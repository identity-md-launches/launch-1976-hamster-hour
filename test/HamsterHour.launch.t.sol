// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// forge-config: default.fuzz.runs = 1024

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {HamsterHour} from "../src/HamsterHour.sol";

/// @dev Stands in for the launch factory: deploys the token through CREATE2 from raw creation code
/// in one call, checks the supply is whole and still here right after the constructor, and moves
/// the launch flows. Only its controller may drive it.
contract FactoryProbe {
    address private immutable controller = msg.sender;
    mapping(uint64 => address) public distributorOf;

    modifier onlyController() {
        require(msg.sender == controller, "not the controller");
        _;
    }

    function deploy(bytes memory code, bytes32 salt, uint256 expectedSupply)
        external
        onlyController
        returns (address deployed)
    {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "token constructor failed");
        require(HamsterHour(deployed).totalSupply() == expectedSupply, "manifest supply mismatch");
        require(HamsterHour(deployed).balanceOf(address(this)) == expectedSupply, "supply not held by the factory");
    }

    function tryDeploy(bytes memory code, bytes32 salt) external onlyController returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
    }

    function setDistributor(uint64 launchNumber, address distributor) external onlyController {
        distributorOf[launchNumber] = distributor;
    }

    function move(HamsterHour token, address to, uint256 amount) external onlyController returns (bool) {
        return token.transfer(to, amount);
    }

    function allow(HamsterHour token, address spender, uint256 amount) external onlyController returns (bool) {
        return token.approve(spender, amount);
    }
}

/// @dev A minimal stand-in for the pool manager's custody: it pulls the seed through an allowance,
/// pays traders on a buy, and takes tokens back on a sell. It is an ordinary holder to the token.
contract PoolCustodyProbe {
    HamsterHour private immutable token;

    constructor(HamsterHour token_) {
        token = token_;
    }

    function pull(address from, uint256 amount) external {
        require(token.transferFrom(from, address(this), amount), "pull returned false");
    }

    function pay(address trader, uint256 amount) external {
        require(token.transfer(trader, amount), "pay returned false");
    }

    function take(address trader, uint256 amount) external {
        require(token.transferFrom(trader, address(this), amount), "take returned false");
    }
}

/// @notice The launch as the factory performs it, reduced to the ERC-20 movements the floor checks:
/// one-call CREATE2 deployment at a predicted address, the swarm's tenth arriving and claimable
/// whole, the pool share pulled by allowance, and a stranger buying and selling without loss.
contract HamsterHourLaunchTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 private constant SWARM_BPS = 1_000;
    uint256 private constant POOL_BPS = 8_000;
    uint64 private constant LAUNCH_NUMBER = 42;

    FactoryProbe private factory;
    HamsterHour private token;
    address private distributor;
    address private claimant;
    address private remainder;
    address private trader;

    function setUp() public {
        factory = new FactoryProbe();
        distributor = makeAddr("distributor");
        claimant = makeAddr("claimant");
        remainder = makeAddr("remainder");
        trader = makeAddr("trader");
        token = HamsterHour(factory.deploy(type(HamsterHour).creationCode, bytes32(uint256(LAUNCH_NUMBER)), SUPPLY));
    }

    function test_create2AddressIsPredictableFromCreationCodeAlone() public view {
        bytes32 salt = bytes32(uint256(LAUNCH_NUMBER));
        bytes32 codeHash = keccak256(type(HamsterHour).creationCode);
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, codeHash)))));
        assertEq(address(token), predicted, "the token did not land at the predicted address");
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_redeployingTheSameSaltFails() public {
        address again = factory.tryDeploy(type(HamsterHour).creationCode, bytes32(uint256(LAUNCH_NUMBER)));
        assertEq(again, address(0), "CREATE2 collided silently");
        assertEq(token.totalSupply(), SUPPLY, "a failed redeploy changed the supply");
        assertEq(token.balanceOf(address(factory)), SUPPLY);
    }

    function test_differentSaltsGiveIndependentTokens() public {
        HamsterHour other =
            HamsterHour(factory.deploy(type(HamsterHour).creationCode, bytes32(uint256(LAUNCH_NUMBER) + 1), SUPPLY));
        assertTrue(address(other) != address(token));
        assertEq(other.balanceOf(address(factory)), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        factory.move(token, distributor, 1);
        assertEq(other.balanceOf(distributor), 0);
    }

    function test_swarmShareArrivesWholeAndIsClaimableWhole() public {
        factory.setDistributor(LAUNCH_NUMBER, distributor);
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        assertTrue(factory.move(token, distributor, swarm), "the transfer to the distributor returned false");
        assertEq(token.balanceOf(distributor), swarm, "the swarm's share arrived short");
        assertEq(token.balanceOf(address(factory)), SUPPLY - swarm);

        vm.prank(distributor);
        assertTrue(token.transfer(claimant, swarm), "the claim transfer returned false");
        assertEq(token.balanceOf(claimant), swarm, "a claim arrived short");
        assertEq(token.balanceOf(distributor), 0, "the distributor kept something back");
        assertEq(token.totalSupply(), SUPPLY, "the launch flows changed the supply");
    }

    function test_distributorCannotPayOutMoreThanItReceived() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        factory.move(token, distributor, swarm);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, distributor, swarm, swarm + 1)
        );
        vm.prank(distributor);
        token.transfer(claimant, swarm + 1);
        assertEq(token.balanceOf(distributor), swarm);
    }

    function test_poolSeedPulledByAllowanceIsExactAndBounded() public {
        PoolCustodyProbe pool = new PoolCustodyProbe(token);
        uint256 allowed = (SUPPLY * POOL_BPS) / 10_000;
        factory.allow(token, address(pool), allowed);

        pool.pull(address(factory), allowed);
        assertEq(token.balanceOf(address(pool)), allowed, "the seed arrived short");
        assertEq(token.allowance(address(factory), address(pool)), 0);

        // The pool cannot take a wei beyond the requester's pool share.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pool), 0, 1));
        pool.pull(address(factory), 1);
        assertEq(token.balanceOf(address(factory)), SUPPLY - allowed);
    }

    function test_traderBuysAndSellsBackWithoutLoss() public {
        PoolCustodyProbe pool = new PoolCustodyProbe(token);
        uint256 allowed = (SUPPLY * POOL_BPS) / 10_000;
        factory.allow(token, address(pool), allowed);
        pool.pull(address(factory), allowed);

        uint256 bought = 12_345 ether;
        pool.pay(trader, bought);
        assertEq(token.balanceOf(trader), bought, "the trader received less than the pool paid");

        vm.prank(trader);
        token.approve(address(pool), bought);
        pool.take(trader, bought);
        assertEq(token.balanceOf(trader), 0, "the trader could not sell everything back");
        assertEq(token.balanceOf(address(pool)), allowed, "the pool did not get back what it paid");
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_traderCannotSellWhatTheyDoNotHold() public {
        PoolCustodyProbe pool = new PoolCustodyProbe(token);
        vm.prank(trader);
        token.approve(address(pool), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, trader, 0, 1));
        pool.take(trader, 1);
    }

    function test_fullLaunchSplitLeavesTheFactoryEmpty() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        uint256 poolShare = (SUPPLY * POOL_BPS) / 10_000;
        uint256 rest = SUPPLY - swarm - poolShare;
        PoolCustodyProbe pool = new PoolCustodyProbe(token);

        factory.move(token, distributor, swarm);
        factory.allow(token, address(pool), poolShare);
        pool.pull(address(factory), poolShare);
        factory.move(token, remainder, rest);

        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(distributor) + token.balanceOf(address(pool)) + token.balanceOf(remainder), SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(factory), 0, 1));
        factory.move(token, remainder, 1);
    }

    function testFuzz_launchSplitAtAnyPoolShareIsExact(uint256 rawPoolBps, uint256 rawRemainderBps) public {
        uint256 poolBps = bound(rawPoolBps, 0, 10_000 - SWARM_BPS);
        uint256 remainderBps = bound(rawRemainderBps, 0, 10_000 - SWARM_BPS - poolBps);
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        uint256 poolShare = (SUPPLY * poolBps) / 10_000;
        uint256 rest = (SUPPLY * remainderBps) / 10_000;
        PoolCustodyProbe pool = new PoolCustodyProbe(token);

        assertTrue(factory.move(token, distributor, swarm));
        assertTrue(factory.allow(token, address(pool), poolShare));
        pool.pull(address(factory), poolShare);
        assertTrue(factory.move(token, remainder, rest));

        assertEq(token.balanceOf(distributor), swarm);
        assertEq(token.balanceOf(address(pool)), poolShare);
        assertEq(token.balanceOf(remainder), rest);
        assertEq(token.balanceOf(address(factory)), SUPPLY - swarm - poolShare - rest);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_runtimeFitsEip170() public view {
        assertGt(address(token).code.length, 0);
        assertLe(address(token).code.length, 24_576, "runtime exceeds EIP-170");
    }

    function test_runtimeCodeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0, "the token has no runtime code");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "runtime code contains DELEGATECALL");
            assertTrue(op != 0xF2, "runtime code contains CALLCODE");
            assertTrue(op != 0xFF, "runtime code contains SELFDESTRUCT");
        }
    }

    function test_runtimeCodeMakesNoExternalCallsAtAll() public view {
        // A fixed-supply token with no hooks has no reason to CALL or STATICCALL anything. CREATE
        // and CREATE2 would be a hidden deployment path. Push data is skipped as in the floor's scan.
        bytes memory runtime = address(token).code;
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF1, "runtime code contains CALL");
            assertTrue(op != 0xFA, "runtime code contains STATICCALL");
            assertTrue(op != 0xF0, "runtime code contains CREATE");
            assertTrue(op != 0xF5, "runtime code contains CREATE2");
        }
    }
}
