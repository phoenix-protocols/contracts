// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// a library for handling binary fixed point numbers (https://en.wikipedia.org/wiki/Q_(number_format))

// range: [0, 2**112 - 1]
// resolution: 1 / 2**112

library UQ112x112 {
    uint224 constant Q112 = 2 ** 112;

    // encode a uint112 as a UQ112x112
    function encode(uint112 y) internal pure returns (uint224 z) {
        z = uint224(y) * Q112; // never overflows
    }

    // divide a UQ112x112 by a uint112, returning a UQ112x112
    function uqdiv(uint224 x, uint112 y) internal pure returns (uint224 z) {
        z = x / uint224(y);
    }

    // y is a UQ112x112 fixed point number, returns y * x (no overflow check, rely on solidity 0.8)
    function mul(uint224 y, uint256 x) internal pure returns (uint256) {
        return (uint256(y) * x);
    }

    // Decode a UQ112x112 to a regular integer, keeping the high 144 bits (common usage)
    function decode144(uint224 y) internal pure returns (uint144) {
        return uint144(uint256(y) >> 112);
    }
}
