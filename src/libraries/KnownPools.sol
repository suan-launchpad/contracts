// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Deterministic addresses of the pools a launch token could be paired in on BSC outside its own pool:
///         PancakeSwap and Uniswap V2 / V3 with WBNB and USDT, plus Likwid's singleton vault. The token blocks
///         them during its anti-farm window, so trading stays in the hooked pool. (Flap's newest tokens block the
///         same V2 / V3 set for their quote token; four also blocks LikwidVault.)
library KnownPools {
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    address internal constant PCS_V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    bytes32 internal constant PCS_V2_INIT_CODE_HASH = 0x00fb7f630766e6a796048ea87d01acd3068e8ff67d078148a3fa3f4a84f69bd5;
    address internal constant PCS_V3_DEPLOYER = 0x41ff9AA7e16B8B1a8a8dc4f0eFacd93D02d071c9;
    bytes32 internal constant PCS_V3_INIT_CODE_HASH = 0x6ce8eb472fa82df5469c6ab6d485f17c3ad13c8cd7af59b3d4a8026c5ce0f7e2;

    address internal constant UNI_V2_FACTORY = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
    bytes32 internal constant UNI_V2_INIT_CODE_HASH = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;
    address internal constant UNI_V3_FACTORY = 0xdB1d10011AD0Ff90774D0C6Bb92e5C5c8b4461F7;
    bytes32 internal constant UNI_V3_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

    /// @dev Likwid V2 singleton vault (Sourcify: `LikwidVault`).
    address internal constant LIKWID_VAULT = 0x065d449ec9D139740343990B7E1CF05fA830e4Ba;

    uint256 internal constant COUNT = 21;

    function v2Pair(address a, address b) internal pure returns (address) {
        return _v2(PCS_V2_FACTORY, PCS_V2_INIT_CODE_HASH, a, b);
    }

    function v3Pool(address a, address b, uint24 fee) internal pure returns (address) {
        return _v3(PCS_V3_DEPLOYER, PCS_V3_INIT_CODE_HASH, a, b, fee);
    }

    function uniV2Pair(address a, address b) internal pure returns (address) {
        return _v2(UNI_V2_FACTORY, UNI_V2_INIT_CODE_HASH, a, b);
    }

    function uniV3Pool(address a, address b, uint24 fee) internal pure returns (address) {
        return _v3(UNI_V3_FACTORY, UNI_V3_INIT_CODE_HASH, a, b, fee);
    }

    /// @return pools for `token` with WBNB and USDT: PancakeSwap V2 + V3 (0.01%, 0.05%, 0.25%, 1%), Uniswap V2 + V3
    ///         (0.01%, 0.05%, 0.3%, 1%), then LikwidVault
    function all(address token) internal pure returns (address[] memory pools) {
        address[2] memory quotes = [WBNB, USDT];
        uint24[4] memory pcsFees = [uint24(100), 500, 2500, 10000];
        uint24[4] memory uniFees = [uint24(100), 500, 3000, 10000];
        pools = new address[](COUNT);
        uint256 n;
        for (uint256 i; i < 2; ++i) {
            pools[n++] = v2Pair(token, quotes[i]);
            pools[n++] = uniV2Pair(token, quotes[i]);
            for (uint256 j; j < 4; ++j) {
                pools[n++] = v3Pool(token, quotes[i], pcsFees[j]);
                pools[n++] = uniV3Pool(token, quotes[i], uniFees[j]);
            }
        }
        pools[n] = LIKWID_VAULT;
    }

    function _v2(address factory, bytes32 initCodeHash, address a, address b) private pure returns (address) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return address(
            uint160(uint256(keccak256(abi.encodePacked(hex"ff", factory, keccak256(abi.encodePacked(t0, t1)), initCodeHash))))
        );
    }

    function _v3(address deployer, bytes32 initCodeHash, address a, address b, uint24 fee) private pure returns (address) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return address(
            uint160(uint256(keccak256(abi.encodePacked(hex"ff", deployer, keccak256(abi.encode(t0, t1, fee)), initCodeHash))))
        );
    }
}
