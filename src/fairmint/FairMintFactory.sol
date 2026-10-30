// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {FairMintERC20} from "./FairMintERC20.sol";
import {FairMintSale} from "./FairMintSale.sol";

/// @title FairMintFactory
/// @notice Anyone creates a `.ai` Agent ID fair mint here. Creation costs `creationFee` (to SuanBuyBurn, not
///         refunded) plus `bond` (held by the sale: returned to the creator on launch, sent to SuanBuyBurn if the
///         sale fails). Every rule is checked against the bounds below and then fixed in the sale forever.
/// @dev The owner can only change the creation fee and bond for future sales (within hard caps) and open or close
///      creation. Nothing here reaches into a sale that already exists.
contract FairMintFactory is Ownable2Step {
    uint256 public constant MAX_CREATION_FEE = 0.1 ether;
    uint256 public constant MAX_BOND = 0.5 ether;
    uint256 public constant MAX_TIERS = 20;
    uint256 public constant MIN_SHARE_PRICE = 1e12; // 0.000001 BNB
    uint64 public constant MIN_SHARES = 1_000;
    uint64 public constant MAX_SHARES = 10_000_000;
    uint16 public constant MIN_TARGET_BPS = 2_000;
    uint64 public constant MIN_DURATION = 1 hours;
    uint64 public constant MAX_DURATION = 14 days;
    uint32 public constant MAX_PER_WALLET = 100;
    uint32 public constant MAX_INVITE_BONUS = 5;
    uint32 public constant MAX_TOTAL_INVITE_BONUS = 20;
    uint16 public constant MAX_CREATOR_BNB_BPS = 1_500;
    uint16 public constant MAX_CREATOR_TOKEN_BPS = 500;
    uint32 public constant MIN_VESTING = 30 days;
    uint32 public constant MAX_VESTING = 180 days;
    uint256 public constant MAX_META_BYTES = 128;
    uint256 public constant MAX_NAME_BYTES = 32;
    uint256 public constant MAX_SYMBOL_BYTES = 12;
    uint16 public constant MAX_TAX_BPS = 500;
    uint32 public constant MIN_TAX_DURATION = 1 days;
    uint32 public constant MAX_TAX_DURATION = 365 days;
    uint32 public constant PERMANENT = type(uint32).max;

    address public immutable implementation;
    address public immutable agentId;
    address public immutable v2Factory;
    address public immutable wbnb;
    address public immutable suanBuyBurn;
    address public immutable taxSink;
    bytes32 public immutable pairInitCodeHash;

    uint256 public creationFee;
    uint256 public bond;
    bool public open;

    address[] public sales;
    mapping(address => bool) public isSale;

    error Closed();
    error WrongPayment(uint256 expected);
    error BadParams(string reason);
    error ZeroAddress();
    error FeeTooHigh();
    error TransferFailed();

    event SaleCreated(
        address indexed sale, address indexed creator, string name, string symbol, string meta, uint64 deadline
    );
    event CreationFeeSet(uint256 fee);
    event BondSet(uint256 bond);
    event OpenSet(bool open);

    constructor(
        address agentId_,
        address v2Factory_,
        address wbnb_,
        bytes32 pairInitCodeHash_,
        address suanBuyBurn_,
        address taxSink_,
        address owner_
    ) Ownable(owner_) {
        if (
            agentId_ == address(0) || v2Factory_ == address(0) || wbnb_ == address(0) || suanBuyBurn_ == address(0)
                || taxSink_ == address(0)
        ) {
            revert ZeroAddress();
        }
        taxSink = taxSink_;
        pairInitCodeHash = pairInitCodeHash_;
        implementation = address(new FairMintSale());
        agentId = agentId_;
        v2Factory = v2Factory_;
        wbnb = wbnb_;
        suanBuyBurn = suanBuyBurn_;
        creationFee = 0.01 ether;
        bond = 0.05 ether;
        open = true;
        emit CreationFeeSet(creationFee);
        emit BondSet(bond);
        emit OpenSet(true);
    }

    /// @notice Create a sale. Send exactly `creationFee + bond`.
    function create(FairMintSale.Params calldata p) external payable returns (address sale) {
        if (!open) revert Closed();
        uint256 fee = creationFee;
        uint256 b = bond;
        if (msg.value != fee + b) revert WrongPayment(fee + b);
        validate(p);

        sale = Clones.clone(implementation);
        isSale[sale] = true;
        sales.push(sale);
        FairMintSale(sale).initialize{value: b}(
            p,
            FairMintSale.Wiring({
                creator: msg.sender,
                agentId: agentId,
                v2Factory: v2Factory,
                wbnb: wbnb,
                suanBuyBurn: suanBuyBurn,
                taxSink: taxSink,
                pairInitCodeHash: pairInitCodeHash
            })
        );
        emit SaleCreated(sale, msg.sender, p.name, p.symbol, p.meta, p.deadline);
        if (fee > 0) {
            (bool ok,) = suanBuyBurn.call{value: fee}("");
            if (!ok) revert TransferFailed();
        }
    }

    /// @notice Reverts with the first broken rule. The web and skill call it to check a form before sending.
    function validate(FairMintSale.Params calldata p) public view {
        uint256 nameLen = bytes(p.name).length;
        uint256 symbolLen = bytes(p.symbol).length;
        if (nameLen == 0 || nameLen > MAX_NAME_BYTES) revert BadParams("name");
        if (symbolLen == 0 || symbolLen > MAX_SYMBOL_BYTES) revert BadParams("symbol");
        if (bytes(p.meta).length > MAX_META_BYTES) revert BadParams("meta");
        if (p.maxShares < MIN_SHARES || p.maxShares > MAX_SHARES) revert BadParams("maxShares");
        if (p.targetShares > p.maxShares || uint256(p.targetShares) * 10_000 < uint256(p.maxShares) * MIN_TARGET_BPS) {
            revert BadParams("targetShares");
        }
        if (p.deadline < block.timestamp + MIN_DURATION || p.deadline > block.timestamp + MAX_DURATION) {
            revert BadParams("deadline");
        }
        if (p.perWallet == 0 || p.perWallet > MAX_PER_WALLET) revert BadParams("perWallet");
        if (p.inviteBonus > MAX_INVITE_BONUS) revert BadParams("inviteBonus");
        if (p.maxInviteBonus > MAX_TOTAL_INVITE_BONUS) revert BadParams("maxInviteBonus");
        if (p.creatorBnbBps > MAX_CREATOR_BNB_BPS) revert BadParams("creatorBnbBps");
        if (p.creatorTokenBps > MAX_CREATOR_TOKEN_BPS) revert BadParams("creatorTokenBps");
        bool creatorShare = p.creatorBnbBps > 0 || p.creatorTokenBps > 0;
        if (creatorShare && (p.vestingSeconds < MIN_VESTING || p.vestingSeconds > MAX_VESTING)) {
            revert BadParams("vestingSeconds");
        }
        if (!creatorShare && p.vestingSeconds != 0) revert BadParams("vestingSeconds");

        _validateTax(p.tax);

        uint256 n = p.tiers.length;
        if (n == 0 || n > MAX_TIERS) revert BadParams("tiers");
        uint256 prevUpTo;
        uint256 prevPrice;
        for (uint256 i; i < n; ++i) {
            FairMintSale.Tier calldata t = p.tiers[i];
            if (t.upTo <= prevUpTo) revert BadParams("tier upTo");
            if (t.price < MIN_SHARE_PRICE || t.price < prevPrice) revert BadParams("tier price");
            prevUpTo = t.upTo;
            prevPrice = t.price;
        }
        if (prevUpTo != p.maxShares) revert BadParams("last tier");
    }

    function _validateTax(FairMintERC20.Tax calldata t) private pure {
        if (t.buyBps > MAX_TAX_BPS || t.sellBps > MAX_TAX_BPS) revert BadParams("tax");
        if (t.agentBuyBps > t.buyBps || t.agentSellBps > t.sellBps) revert BadParams("agent tax");
        if (t.burnShareBps > 10_000) revert BadParams("burnShareBps");
        bool taxed = t.buyBps > 0 || t.sellBps > 0;
        if (!taxed) {
            if (t.duration != 0 || t.burnShareBps != 0) revert BadParams("taxDuration");
            return;
        }
        if (t.duration != PERMANENT && (t.duration < MIN_TAX_DURATION || t.duration > MAX_TAX_DURATION)) {
            revert BadParams("taxDuration");
        }
    }

    function salesCount() external view returns (uint256) {
        return sales.length;
    }

    function setCreationFee(uint256 fee) external onlyOwner {
        if (fee > MAX_CREATION_FEE) revert FeeTooHigh();
        creationFee = fee;
        emit CreationFeeSet(fee);
    }

    function setBond(uint256 b) external onlyOwner {
        if (b > MAX_BOND) revert FeeTooHigh();
        bond = b;
        emit BondSet(b);
    }

    function setOpen(bool o) external onlyOwner {
        open = o;
        emit OpenSet(o);
    }
}
