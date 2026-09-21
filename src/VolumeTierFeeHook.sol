// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Discounts subsequent swaps based on settled input in the current UTC hour.
/// @dev Units are raw token amounts; thresholds assume both currencies have 18 decimals.
contract VolumeTierFeeHook {
    using PoolIdLibrary for PoolKey;

    error OnlyPoolManager();
    error DynamicFeeRequired();
    error InvalidManager();

    IPoolManager public immutable poolManager;
    uint256 public constant FIRST_THRESHOLD = 100 ether;
    uint256 public constant SECOND_THRESHOLD = 1000 ether;

    struct Bucket {
        uint256 hour;
        uint256 volume;
    }

    mapping(PoolId => Bucket) public buckets;

    constructor(IPoolManager manager) {
        if (address(manager) == address(0)) revert InvalidManager();
        poolManager = manager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.afterInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24) external onlyPoolManager returns (bytes4) {
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) revert DynamicFeeRequired();
        return this.afterInitialize.selector;
    }

    function currentVolume(PoolId id) public view returns (uint256) {
        Bucket memory b = buckets[id];
        return b.hour == block.timestamp / 1 hours ? b.volume : 0;
    }

    function currentFee(PoolId id) public view returns (uint24) {
        uint256 volume = currentVolume(id);
        return volume < FIRST_THRESHOLD ? 3000 : volume < SECOND_THRESHOLD ? 2000 : 1000;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            currentFee(key.toId()) | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        Bucket storage b = buckets[key.toId()];
        uint256 hour = block.timestamp / 1 hours;
        if (b.hour != hour) {
            b.hour = hour;
            b.volume = 0;
        }
        // Widen before negation, including int128.min. Count actual gross input,
        // including LP/protocol fees, for exact-input and exact-output swaps alike.
        int256 input = params.zeroForOne ? int256(delta.amount0()) : int256(delta.amount1());
        if (input < 0) {
            uint256 amount = uint256(-input);
            // Saturation avoids ever blocking a swap at the accounting limit.
            b.volume = amount > type(uint256).max - b.volume ? type(uint256).max : b.volume + amount;
        }
        return (this.afterSwap.selector, 0);
    }
}
