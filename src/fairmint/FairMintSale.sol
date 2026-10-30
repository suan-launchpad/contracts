// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FairMintERC20} from "./FairMintERC20.sol";
import {IPancakeV2Factory, IPancakeV2Pair, IWBNB} from "./IPancakeV2.sol";

/// @title FairMintSale
/// @notice One fair mint, deployed as a clone by `FairMintFactory`. Only `.ai` Agent ID holders mint shares for BNB.
///         Every rule is fixed at creation; there is no owner and no withdrawal. The BNB can only leave through:
///         - success (sold out, or the target reached by the deadline): 2% to SuanBuyBurn, the creator's share into
///           linear vesting, the rest paired with tokens in a new PancakeSwap V2 pool whose LP goes to the dead
///           address; minters then claim their tokens;
///         - failure (target missed at the deadline): every minter takes back exactly what they paid, and the
///           creator's bond goes to SuanBuyBurn.
/// @dev Pricing. Tier prices never decrease and every share returns the same `tokensPerShare`. The pool opens at the
///      price of the last share sold, so no minter's cost is above the opening price. With
///      `tokensPerShare = (SUPPLY - creatorTokens) / (2 * maxShares)` the minters' tokens and the pool's tokens always
///      fit in the supply: `lpBnb <= raised <= sold * lastPrice`, so `lpTokens = lpBnb * T / lastPrice <= sold * T`.
///      Only what is needed is minted (holders + pool + creator); the token's supply is therefore at most `SUPPLY`.
///      Rounding: `lpTokens` rounds down, which opens the pool at or a hair above the last share's price.
contract FairMintSale is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint16 public constant PLATFORM_FEE_BPS = 200;
    uint16 internal constant BPS = 10_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct Tier {
        uint64 upTo; // cumulative share count this tier ends at (inclusive)
        uint128 price; // BNB wei per share
    }

    /// @notice What the creator chooses. Bounds are checked by the factory.
    struct Params {
        string name;
        string symbol;
        string meta;
        Tier[] tiers;
        uint64 maxShares;
        uint64 targetShares;
        uint64 deadline;
        uint32 perWallet;
        uint32 inviteBonus; // extra cap a referrer earns per invitee's first mint
        uint32 maxInviteBonus; // ceiling on all invite bonus for one wallet
        uint16 creatorBnbBps;
        uint16 creatorTokenBps;
        uint32 vestingSeconds;
        FairMintERC20.Tax tax;
    }

    /// @notice Addresses fixed by the factory.
    struct Wiring {
        address creator;
        address agentId;
        address v2Factory;
        address wbnb;
        address suanBuyBurn;
        address taxSink;
        bytes32 pairInitCodeHash;
    }

    enum State {
        Minting,
        Live,
        Failed
    }

    error AlreadyInitialized();
    error MintClosed();
    error NotAgent();
    error ZeroShares();
    error SoldOut();
    error OverWalletCap(uint256 cap);
    error Underpaid(uint256 cost);
    error NotYet();
    error WrongState();
    error NothingToClaim();
    error TransferFailed();
    error PairMismatch();

    event Minted(address indexed user, address indexed referrer, uint64 shares, uint256 cost, uint64 sold);
    event InviteCounted(address indexed referrer, address indexed invitee);
    event Launched(address indexed token, address indexed pair, uint256 lpBnb, uint256 lpTokens, uint256 fee);
    event Failed(uint64 sold, uint256 raised);
    event Claimed(address indexed user, uint256 amount);
    event Refunded(address indexed user, uint256 amount);
    event CreatorPaid(uint256 bnb, uint256 tokens);
    event FeeSent(uint256 amount);
    event FeeOwed(uint256 amount);

    // configuration (set once in `initialize`)
    string public name;
    string public symbol;
    string public meta;
    Tier[] internal _tiers;
    uint64 public maxShares;
    uint64 public targetShares;
    uint64 public deadline;
    uint32 public perWallet;
    uint32 public inviteBonus;
    uint32 public maxInviteBonus;
    uint16 public creatorBnbBps;
    uint16 public creatorTokenBps;
    uint32 public vestingSeconds;
    uint256 public tokensPerShare;
    uint256 public creatorTokens;
    address public creator;
    address public agentId;
    address public v2Factory;
    address public wbnb;
    address public suanBuyBurn;
    address public taxSink;
    bytes32 public pairInitCodeHash;
    FairMintERC20.Tax public tax;
    uint256 public bond;

    // live state
    State public state;
    uint64 public sold;
    uint256 public raised;
    address public token;
    address public pair;
    uint64 public launchedAt;
    uint256 public creatorBnb;
    uint256 public creatorBnbPaid;
    uint256 public creatorTokensPaid;
    uint256 public bondOwedToCreator;
    uint256 public feeOwed;

    mapping(address => uint64) public sharesOf;
    mapping(address => uint256) public paidOf;
    mapping(address => uint32) public inviteBonusOf;
    mapping(address => address) public referrerOf;
    mapping(address => bool) public claimed;

    /// @dev The implementation is locked; only clones are initialized.
    constructor() {
        creator = address(this);
    }

    /// @notice Called once by the factory in the creation transaction, with the creator's bond as `msg.value`.
    function initialize(Params calldata p, Wiring calldata w) external payable {
        if (creator != address(0)) revert AlreadyInitialized();
        name = p.name;
        symbol = p.symbol;
        meta = p.meta;
        for (uint256 i; i < p.tiers.length; ++i) _tiers.push(p.tiers[i]);
        maxShares = p.maxShares;
        targetShares = p.targetShares;
        deadline = p.deadline;
        perWallet = p.perWallet;
        inviteBonus = p.inviteBonus;
        maxInviteBonus = p.maxInviteBonus;
        creatorBnbBps = p.creatorBnbBps;
        creatorTokenBps = p.creatorTokenBps;
        vestingSeconds = p.vestingSeconds;
        creatorTokens = SUPPLY * p.creatorTokenBps / BPS;
        tokensPerShare = (SUPPLY - creatorTokens) / (2 * uint256(p.maxShares));
        creator = w.creator;
        agentId = w.agentId;
        v2Factory = w.v2Factory;
        wbnb = w.wbnb;
        suanBuyBurn = w.suanBuyBurn;
        taxSink = w.taxSink;
        pairInitCodeHash = w.pairInitCodeHash;
        tax = p.tax;
        bond = msg.value;
    }

    // ---------------------------------------------------------------- minting

    /// @notice Mint `shares` for BNB. `msg.value` is the most you will pay; any excess is returned.
    ///         `referrer` counts only on your first mint, and only if it has minted itself and is not you.
    function mint(uint64 shares, address referrer) external payable nonReentrant {
        if (state != State.Minting || block.timestamp >= deadline) revert MintClosed();
        if (shares == 0) revert ZeroShares();
        if (uint256(sold) + shares > maxShares) revert SoldOut();
        if (IERC721(agentId).balanceOf(msg.sender) == 0) revert NotAgent();
        uint256 cap = walletCap(msg.sender);
        if (uint256(sharesOf[msg.sender]) + shares > cap) revert OverWalletCap(cap);
        uint256 cost = costOf(sold, shares);
        if (msg.value < cost) revert Underpaid(cost);

        if (sharesOf[msg.sender] == 0 && referrer != address(0) && referrer != msg.sender && sharesOf[referrer] > 0) {
            referrerOf[msg.sender] = referrer;
            inviteBonusOf[referrer] += inviteBonus;
            emit InviteCounted(referrer, msg.sender);
        }
        sharesOf[msg.sender] += shares;
        paidOf[msg.sender] += cost;
        sold += shares;
        raised += cost;
        emit Minted(msg.sender, referrerOf[msg.sender], shares, cost, sold);

        if (msg.value > cost) _send(msg.sender, msg.value - cost);
    }

    /// @notice Most shares `user` may hold: the per-wallet cap plus earned invite bonus (capped).
    function walletCap(address user) public view returns (uint256) {
        return uint256(perWallet) + Math.min(inviteBonusOf[user], maxInviteBonus);
    }

    /// @notice BNB for `shares` more shares when `start` are already sold.
    function costOf(uint64 start, uint64 shares) public view returns (uint256 cost) {
        uint256 from = start;
        uint256 to = uint256(start) + shares;
        for (uint256 i; i < _tiers.length && from < to; ++i) {
            Tier memory t = _tiers[i];
            if (t.upTo <= from) continue;
            uint256 end = Math.min(t.upTo, to);
            cost += (end - from) * t.price;
            from = end;
        }
    }

    /// @notice Price of share number `n` (1-based).
    function priceAt(uint64 n) public view returns (uint256) {
        for (uint256 i; i < _tiers.length; ++i) {
            if (_tiers[i].upTo >= n) return _tiers[i].price;
        }
        return _tiers[_tiers.length - 1].price;
    }

    function tiers() external view returns (Tier[] memory) {
        return _tiers;
    }

    // ---------------------------------------------------------------- settlement

    /// @notice Can be settled now, and how: sold out or target reached at the deadline opens the pool; a missed
    ///         target at the deadline fails the sale.
    function outcome() public view returns (bool ready, bool success) {
        if (state != State.Minting) return (false, false);
        if (sold == maxShares) return (true, true);
        if (block.timestamp < deadline) return (false, false);
        return (true, sold >= targetShares);
    }

    /// @notice Anyone settles the sale once `outcome()` is ready. Nothing here takes a price or amount from the
    ///         caller: every number comes from this contract's own records.
    function finalize() external nonReentrant {
        (bool ready, bool success) = outcome();
        if (!ready) revert NotYet();
        if (success) _launch();
        else _fail();
    }

    function _launch() private {
        state = State.Live;
        launchedAt = uint64(block.timestamp);
        uint256 fee = raised * PLATFORM_FEE_BPS / BPS;
        creatorBnb = raised * creatorBnbBps / BPS;
        uint256 lpBnb = raised - fee - creatorBnb;
        uint256 holders = uint256(sold) * tokensPerShare;
        uint256 lpTokens = Math.mulDiv(lpBnb, tokensPerShare, priceAt(sold));

        address t = address(
            new FairMintERC20(
                name,
                symbol,
                meta,
                holders + lpTokens + creatorTokens,
                address(this),
                tax,
                FairMintERC20.Wiring({
                    v2Factory: v2Factory,
                    wbnb: wbnb,
                    pairInitCodeHash: pairInitCodeHash,
                    agentId: agentId,
                    creator: creator,
                    taxSink: taxSink
                })
            )
        );
        token = t;
        address p = IPancakeV2Factory(v2Factory).getPair(t, wbnb);
        if (p == address(0)) {
            p = IPancakeV2Factory(v2Factory).createPair(t, wbnb);
            if (p != FairMintERC20(t).pair()) revert PairMismatch();
        } else {
            // a pair can be created for an address before its token exists; whatever was sent to it is not ours
            IPancakeV2Pair(p).skim(DEAD);
        }
        pair = p;
        IERC20(t).safeTransfer(p, lpTokens);
        IWBNB(wbnb).deposit{value: lpBnb}();
        if (!IWBNB(wbnb).transfer(p, lpBnb)) revert TransferFailed();
        IPancakeV2Pair(p).mint(DEAD);

        bondOwedToCreator = bond;
        _payFee(fee);
        emit Launched(t, p, lpBnb, lpTokens, fee);
    }

    function _fail() private {
        state = State.Failed;
        emit Failed(sold, raised);
        _payFee(bond);
    }

    /// @notice After launch, send minters their tokens. Anyone may call it for anyone (the keeper batches it).
    function claim(address[] calldata users) external nonReentrant {
        if (state != State.Live) revert WrongState();
        for (uint256 i; i < users.length; ++i) {
            address u = users[i];
            if (claimed[u] || sharesOf[u] == 0) continue;
            claimed[u] = true;
            uint256 amount = uint256(sharesOf[u]) * tokensPerShare;
            IERC20(token).safeTransfer(u, amount);
            emit Claimed(u, amount);
        }
    }

    /// @notice After a failed sale, take back exactly what you paid.
    function refund() external nonReentrant {
        if (state != State.Failed) revert WrongState();
        uint256 amount = paidOf[msg.sender];
        if (amount == 0) revert NothingToClaim();
        paidOf[msg.sender] = 0;
        emit Refunded(msg.sender, amount);
        _send(msg.sender, amount);
    }

    /// @notice Creator's BNB and token shares unlock linearly from launch; the bond is returned at launch.
    ///         Anyone may trigger it; payment always goes to the creator.
    function payCreator() external nonReentrant {
        if (state != State.Live) revert WrongState();
        uint256 elapsed = block.timestamp - launchedAt;
        uint256 bnbDue = _vested(creatorBnb, elapsed) - creatorBnbPaid;
        uint256 tokenDue = _vested(creatorTokens, elapsed) - creatorTokensPaid;
        uint256 bnbOut = bnbDue + bondOwedToCreator;
        if (bnbOut == 0 && tokenDue == 0) revert NothingToClaim();
        creatorBnbPaid += bnbDue;
        creatorTokensPaid += tokenDue;
        bondOwedToCreator = 0;
        emit CreatorPaid(bnbOut, tokenDue);
        if (tokenDue > 0) IERC20(token).safeTransfer(creator, tokenDue);
        if (bnbOut > 0) _send(creator, bnbOut);
    }

    /// @notice Retry a platform fee whose transfer to SuanBuyBurn failed.
    function flushFee() external nonReentrant {
        uint256 amount = feeOwed;
        if (amount == 0) revert NothingToClaim();
        feeOwed = 0;
        _payFee(amount);
    }

    function _vested(uint256 total, uint256 elapsed) private view returns (uint256) {
        if (total == 0) return 0;
        if (vestingSeconds == 0 || elapsed >= vestingSeconds) return total;
        return total * elapsed / vestingSeconds;
    }

    /// @dev A failed fee transfer is recorded for `flushFee`; it never blocks settlement.
    function _payFee(uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = suanBuyBurn.call{value: amount}("");
        if (ok) {
            emit FeeSent(amount);
        } else {
            feeOwed += amount;
            emit FeeOwed(amount);
        }
    }

    function _send(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
