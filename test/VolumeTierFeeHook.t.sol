// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {VolumeTierFeeHook} from "../src/VolumeTierFeeHook.sol";

contract VolumeTierFeeHookTest is Test {
    using PoolIdLibrary for PoolKey;

    PoolManager manager;
    VolumeTierFeeHook hook;
    PoolSwapTest router;
    PoolModifyLiquidityTest lp;
    PoolKey key;
    uint160 constant PRICE = 79228162514264337593543950336;

    function setUp() public {
        vm.warp(10 hours + 7);
        manager = new PoolManager(address(this));
        router = new PoolSwapTest(manager);
        lp = new PoolModifyLiquidityTest(manager);
        bytes memory code = abi.encodePacked(type(VolumeTierFeeHook).creationCode, abi.encode(manager));
        uint160 flags = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
        for (uint256 i;; i++) {
            bytes32 salt = bytes32(i);
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(code)))))
            );
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK != flags) continue;
            hook = new VolumeTierFeeHook{salt: salt}(manager);
            break;
        }
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (a, b) = address(a) < address(b) ? (a, b) : (b, a);
        a.mint(address(this), 1e30);
        b.mint(address(this), 1e30);
        a.approve(address(router), type(uint256).max);
        b.approve(address(router), type(uint256).max);
        a.approve(address(lp), type(uint256).max);
        b.approve(address(lp), type(uint256).max);
        key = PoolKey(
            Currency.wrap(address(a)),
            Currency.wrap(address(b)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            IHooks(address(hook))
        );
        manager.initialize(key, PRICE);
        lp.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, 1e26, 0), "");
    }

    function swap(PoolKey memory k, bool direction, int256 amount) internal returns (BalanceDelta) {
        return router.swap(
            k,
            SwapParams(direction, amount, direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            hex"deadbeef"
        );
    }

    function testTierBoundariesAndReset() public {
        assertEq(hook.currentFee(key.toId()), 3000);
        swap(key, true, -99 ether);
        assertEq(hook.currentVolume(key.toId()), 99 ether);
        assertEq(hook.currentFee(key.toId()), 3000);
        swap(key, false, -1 ether);
        assertEq(hook.currentFee(key.toId()), 2000);
        swap(key, true, -899 ether);
        assertEq(hook.currentFee(key.toId()), 2000);
        swap(key, false, -1 ether);
        assertEq(hook.currentVolume(key.toId()), 1000 ether);
        assertEq(hook.currentFee(key.toId()), 1000);
        vm.warp(11 hours - 1);
        assertEq(hook.currentFee(key.toId()), 1000);
        vm.warp(11 hours);
        assertEq(hook.currentFee(key.toId()), 3000);
        assertEq(hook.currentVolume(key.toId()), 0);
        swap(key, true, -2 ether);
        assertEq(hook.currentVolume(key.toId()), 2 ether);
    }

    function testFeeActuallyChargedByManager() public {
        // Core Swap event includes the applied fee, independent of the hook's getter.
        vm.recordLogs();
        swap(key, true, -100 ether);
        assertSwapFee(3000);
        vm.recordLogs();
        swap(key, false, -900 ether);
        assertSwapFee(2000);
        vm.recordLogs();
        swap(key, true, -1 ether);
        assertSwapFee(1000);
        vm.warp(11 hours);
        vm.recordLogs();
        swap(key, false, -1 ether);
        assertSwapFee(3000);
    }

    function assertSwapFee(uint24 expected) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == topic) {
                (,,,,, uint24 fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                assertEq(fee, expected);
                found = true;
            }
        }
        assertTrue(found);
    }

    function testExactOutputBothDirectionsCountsActualInput() public {
        BalanceDelta d = swap(key, true, 10 ether);
        uint256 first = uint256(-int256(d.amount0()));
        assertGt(first, 10 ether);
        assertEq(hook.currentVolume(key.toId()), first);
        d = swap(key, false, 20 ether);
        assertEq(hook.currentVolume(key.toId()), first + uint256(-int256(d.amount1())));
    }

    function testPartialFillCountsOnlyConsumedInput() public {
        BalanceDelta d = router.swap(
            key, SwapParams(true, -1e25, TickMath.getSqrtPriceAtTick(-60)), PoolSwapTest.TestSettings(false, false), ""
        );
        uint256 spent = uint256(-int256(d.amount0()));
        assertLt(spent, 1e25);
        assertEq(hook.currentVolume(key.toId()), spent);
    }

    function testPoolIsolationAndLiquidityExit() public {
        PoolKey memory other = key;
        other.tickSpacing = 10;
        manager.initialize(other, PRICE);
        lp.modifyLiquidity(other, ModifyLiquidityParams(-600, 600, 1e26, 0), "");
        swap(key, true, -1000 ether);
        assertEq(hook.currentVolume(other.toId()), 0);
        swap(other, false, -5 ether);
        assertEq(hook.currentVolume(other.toId()), 5 ether);
        assertEq(hook.currentVolume(key.toId()), 1000 ether);
        BalanceDelta d = lp.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, -1e26, 0), "");
        assertGt(d.amount0(), 0);
        assertGt(d.amount1(), 0);
        assertEq(hook.currentVolume(key.toId()), 1000 ether);
    }

    function testStaticFeePoolRejected() public {
        key.fee = 3000;
        vm.expectRevert();
        manager.initialize(key, PRICE);
    }

    function testEveryCallbackRejectsSpoofing() public {
        vm.expectRevert(VolumeTierFeeHook.OnlyPoolManager.selector);
        hook.afterInitialize(address(manager), key, PRICE, 0);
        SwapParams memory p = SwapParams(true, -1 ether, PRICE / 2);
        vm.expectRevert(VolumeTierFeeHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(manager), key, p, abi.encode(address(manager)));
        vm.expectRevert(VolumeTierFeeHook.OnlyPoolManager.selector);
        hook.afterSwap(address(manager), key, p, BalanceDelta.wrap(0), abi.encode(address(manager)));
    }

    function testRevertedSwapDoesNotChangeVolume() public {
        swap(key, true, -5 ether);
        vm.expectRevert();
        router.swap(key, SwapParams(true, -100 ether, PRICE * 2), PoolSwapTest.TestSettings(false, false), "");
        assertEq(hook.currentVolume(key.toId()), 5 ether);
    }

    function testFuzzInputAccounting(uint96 amount, bool direction) public {
        amount = uint96(bound(amount, 1, 2000 ether));
        BalanceDelta d = swap(key, direction, -int256(uint256(amount)));
        assertEq(hook.currentVolume(key.toId()), uint256(-int256(direction ? d.amount0() : d.amount1())));
    }
}
