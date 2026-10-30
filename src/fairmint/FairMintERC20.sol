// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title FairMintERC20
/// @notice The token a successful fair mint creates. The whole supply is minted once, to the sale, in the constructor.
///         No owner, no blacklist, no pause, no further minting.
///         Optional trading tax, fixed forever at creation: buys from and sells to the token's own PancakeSwap V2
///         pair pay `buyTaxBps` / `sellTaxBps` (at most 5%); `.ai` Agent ID wallets pay the lower agent rates. The tax
///         stops for good at `taxEndsAt` (or never, if permanent). Every tax is split: 10% to the platform tax sink
///         (sold for BNB to buy back $SUAN), then `burnShareBps` of the rest to the dead address and the remainder to
///         the creator. Wallet-to-wallet transfers are never taxed.
/// @dev The pair address is derived with CREATE2 from the V2 factory and init code hash, so it is known before the
///      pair exists. The sale and the tax sink are exempt (seeding the pool, claims, and selling the platform share).
contract FairMintERC20 is ERC20 {
    uint16 public constant PLATFORM_SHARE_BPS = 1_000;
    uint16 internal constant BPS = 10_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct Tax {
        uint16 buyBps;
        uint16 sellBps;
        uint16 agentBuyBps;
        uint16 agentSellBps;
        uint16 burnShareBps; // of the non-platform part
        uint32 duration; // seconds after launch; type(uint32).max = permanent; 0 only with no tax
    }

    struct Wiring {
        address v2Factory;
        address wbnb;
        bytes32 pairInitCodeHash;
        address agentId;
        address creator;
        address taxSink;
    }

    /// @notice IPFS CID of the project's image and description, as set when the sale was created.
    string public meta;
    address public immutable pair;
    address public immutable sale;
    address public immutable creator;
    address public immutable taxSink;
    address public immutable agentId;
    uint16 public immutable buyTaxBps;
    uint16 public immutable sellTaxBps;
    uint16 public immutable agentBuyTaxBps;
    uint16 public immutable agentSellTaxBps;
    uint16 public immutable burnShareBps;
    uint64 public immutable taxEndsAt;

    event TaxTaken(address indexed payer, bool buy, uint256 platform, uint256 burned, uint256 toCreator);

    constructor(
        string memory name_,
        string memory symbol_,
        string memory meta_,
        uint256 supply,
        address to,
        Tax memory tax,
        Wiring memory w
    ) ERC20(name_, symbol_) {
        meta = meta_;
        sale = to;
        creator = w.creator;
        taxSink = w.taxSink;
        agentId = w.agentId;
        buyTaxBps = tax.buyBps;
        sellTaxBps = tax.sellBps;
        agentBuyTaxBps = tax.agentBuyBps;
        agentSellTaxBps = tax.agentSellBps;
        burnShareBps = tax.burnShareBps;
        if (tax.buyBps == 0 && tax.sellBps == 0) {
            taxEndsAt = 0;
        } else if (tax.duration == type(uint32).max) {
            taxEndsAt = type(uint64).max;
        } else {
            taxEndsAt = uint64(block.timestamp) + tax.duration;
        }
        (address t0, address t1) = address(this) < w.wbnb ? (address(this), w.wbnb) : (w.wbnb, address(this));
        pair = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(hex"ff", w.v2Factory, keccak256(abi.encodePacked(t0, t1)), w.pairInitCodeHash)
                    )
                )
            )
        );
        _mint(to, supply);
    }

    /// @notice The rate `from -> to` would pay right now, in basis points.
    function taxBpsOf(address from, address to) public view returns (uint256) {
        if (block.timestamp >= taxEndsAt) return 0;
        if (from == sale || to == sale || from == taxSink || to == taxSink) return 0;
        if (from == pair && to != pair) return _isAgent(to) ? agentBuyTaxBps : buyTaxBps;
        if (to == pair && from != pair) return _isAgent(from) ? agentSellTaxBps : sellTaxBps;
        return 0;
    }

    function _isAgent(address user) private view returns (bool) {
        return IERC721(agentId).balanceOf(user) > 0;
    }

    function _update(address from, address to, uint256 value) internal override {
        uint256 bps = from == address(0) ? 0 : taxBpsOf(from, to);
        if (bps == 0 || value == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 tax = value * bps / BPS;
        uint256 platform = tax * PLATFORM_SHARE_BPS / BPS;
        uint256 burned = (tax - platform) * burnShareBps / BPS;
        uint256 toCreator = tax - platform - burned;
        super._update(from, to, value - tax);
        if (platform > 0) super._update(from, taxSink, platform);
        if (burned > 0) super._update(from, DEAD, burned);
        if (toCreator > 0) super._update(from, creator, toCreator);
        emit TaxTaken(from == pair ? to : from, from == pair, platform, burned, toCreator);
    }
}
