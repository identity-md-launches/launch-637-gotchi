// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {HolderWeightedPicker} from "./HolderWeightedPicker.sol";

/// @title FlipEscrow
/// @notice Holds every NFT the FeeSink buys and resolves it 50/50: burn (send to the dead address) or
/// airdrop to a $GOTCHI holder chosen by `HolderWeightedPicker`.
///
/// @dev Randomness is a commit-reveal *mock*, not production randomness:
///  1. `OPERATOR` commits `keccak256(abi.encodePacked(secret))` ahead of time (`commit`). Commitments
///     form a FIFO queue.
///  2. When an acquisition arrives it is bound to the oldest unused commitment that was made *before*
///     the block the NFT was received in (`FlipRequested`). If none qualifies it waits as `Pending`
///     until `requestFlip` finds one.
///  3. Anyone who knows the secret calls `reveal`. The roll is
///     `keccak256(abi.encode(secret, requestId))`; `roll % 10_000 < FLIP_BURN_BPS` burns, otherwise the
///     picker chooses the recipient (no eligible holder, or a stale weight, falls back to a burn).
///  4. A commitment whose secret is withheld past `REVEAL_WINDOW_BLOCKS`, or an acquisition left
///     `Pending` past `PENDING_TIMEOUT_BLOCKS`, is force-burned by anyone through `expire`.
///  Limitations: the operator can predict the outcome once they know the request id, and can refuse
///  to reveal (which only ever produces a burn). Chainlink VRF on Sepolia is the documented upgrade.
///
/// Admin role: `OPERATOR` only supplies commitments. It cannot pick winners, move NFTs or skip burns.
contract FlipEscrow is IERC721Receiver, ReentrancyGuard {
    enum Status {
        None,
        Pending,
        Requested,
        Resolved
    }

    struct Acquisition {
        uint256 tokenId;
        Status status;
        uint256 commitmentIndex;
        uint256 receivedBlock;
        uint256 requestBlock;
        bytes32 requestId;
        bool burned;
        address recipient;
    }

    struct Commitment {
        bytes32 hash;
        uint256 commitBlock;
        bool bound;
        uint256 acquisitionId;
    }

    /// @notice Share of flips that burn, in basis points.
    uint256 public constant FLIP_BURN_BPS = 5_000;
    /// @notice Basis-point denominator.
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Burned NFTs go here.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    /// @notice Blocks after a request during which the secret may be revealed (about a day on Sepolia).
    uint256 public constant REVEAL_WINDOW_BLOCKS = 7_200;
    /// @notice Blocks a `Pending` acquisition may wait for a commitment before anyone can force-burn it.
    uint256 public constant PENDING_TIMEOUT_BLOCKS = 7_200;

    /// @notice The NFT collection held here.
    IERC721 public immutable NFT;
    /// @notice The only `from` accepted on `onERC721Received`: NFTs arrive from the Baazaar purchase.
    address public immutable BAAZAAR;
    /// @notice Chooses airdrop recipients.
    HolderWeightedPicker public immutable PICKER;
    /// @notice Supplies randomness commitments.
    address public immutable OPERATOR;

    /// @notice Index of the oldest commitment that is not bound yet.
    uint256 public nextCommitment;

    Acquisition[] private _acquisitions;
    Commitment[] private _commitments;

    /// @notice An NFT bought by the FeeSink arrived and is now an acquisition.
    event AcquisitionReceived(uint256 indexed acquisitionId, uint256 tokenId);
    /// @notice An acquisition was bound to a commitment; `requestId` identifies the pending roll.
    event FlipRequested(uint256 indexed acquisitionId, uint256 tokenId, bytes32 requestId);
    /// @notice An acquisition was resolved; `recipient` is the dead address when `burned`.
    event FlipResolved(uint256 indexed acquisitionId, uint256 tokenId, bool burned, address indexed recipient);
    /// @notice The NFT was burned (sent to the dead address).
    event Burned(uint256 indexed tokenId, address indexed to);
    /// @notice The NFT was airdropped to a holder selected with `weight`.
    event Airdropped(uint256 indexed tokenId, address indexed recipient, uint256 weight);
    /// @notice The operator committed to a secret.
    event RandomnessCommitted(uint256 indexed commitmentIndex, bytes32 hash);
    /// @notice A secret was revealed for an acquisition; `roll` is the derived randomness.
    event FlipRevealed(uint256 indexed acquisitionId, uint256 roll);
    /// @notice An acquisition was force-burned because its reveal (or its commitment) never came.
    event FlipExpired(uint256 indexed acquisitionId);

    error ZeroAddress();
    error NotOperator();
    error NotTheNft();
    error NotFromBaazaar(address from);
    error ZeroCommitment();
    error UnknownAcquisition(uint256 acquisitionId);
    error InvalidStatus(uint256 acquisitionId, Status status);
    error NoCommitmentAvailable();
    error RevealWindowClosed(uint256 acquisitionId);
    error BadSecret();
    error NotExpired(uint256 acquisitionId);

    modifier onlyOperator() {
        if (msg.sender != OPERATOR) revert NotOperator();
        _;
    }

    constructor(address nft, address baazaar, address picker, address operator) {
        if (nft == address(0) || baazaar == address(0) || picker == address(0) || operator == address(0)) {
            revert ZeroAddress();
        }
        NFT = IERC721(nft);
        BAAZAAR = baazaar;
        PICKER = HolderWeightedPicker(picker);
        OPERATOR = operator;
    }

    // ---------------------------------------------------------------------------------------------
    // Commitments (operator)
    // ---------------------------------------------------------------------------------------------

    /// @notice Queues `keccak256(abi.encodePacked(secret))` for a future flip.
    function commit(bytes32 hash) external onlyOperator {
        _commit(hash);
    }

    /// @notice Queues several commitments at once.
    function commitMany(bytes32[] calldata hashes) external onlyOperator {
        for (uint256 i = 0; i < hashes.length; i++) {
            _commit(hashes[i]);
        }
    }

    function _commit(bytes32 hash) private {
        if (hash == bytes32(0)) revert ZeroCommitment();
        uint256 index = _commitments.length;
        _commitments.push(Commitment({hash: hash, commitBlock: block.number, bound: false, acquisitionId: 0}));
        emit RandomnessCommitted(index, hash);
    }

    // ---------------------------------------------------------------------------------------------
    // Intake
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IERC721Receiver
    /// @dev Only the configured NFT contract may call this, and only for transfers out of the Baazaar
    /// (the FeeSink buys with the escrow as recipient). Registers the acquisition and binds a
    /// commitment when one is available.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata)
        external
        override
        nonReentrant
        returns (bytes4)
    {
        if (msg.sender != address(NFT)) revert NotTheNft();
        if (from != BAAZAAR) revert NotFromBaazaar(from);

        uint256 acquisitionId = _acquisitions.length;
        _acquisitions.push(
            Acquisition({
                tokenId: tokenId,
                status: Status.Pending,
                commitmentIndex: 0,
                receivedBlock: block.number,
                requestBlock: 0,
                requestId: bytes32(0),
                burned: false,
                recipient: address(0)
            })
        );
        emit AcquisitionReceived(acquisitionId, tokenId);
        _tryRequest(acquisitionId);
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Binds a `Pending` acquisition to the next eligible commitment. Anyone may call it.
    function requestFlip(uint256 acquisitionId) external nonReentrant {
        Acquisition storage acquisition = _get(acquisitionId);
        if (acquisition.status != Status.Pending) revert InvalidStatus(acquisitionId, acquisition.status);
        if (!_tryRequest(acquisitionId)) revert NoCommitmentAvailable();
    }

    /// @dev Commitments are FIFO and their blocks are non-decreasing, so only the oldest unbound one
    /// needs checking: it must predate the block the NFT was received in.
    function _tryRequest(uint256 acquisitionId) private returns (bool) {
        if (nextCommitment >= _commitments.length) return false;
        Acquisition storage acquisition = _acquisitions[acquisitionId];
        uint256 index = nextCommitment;
        Commitment storage commitment = _commitments[index];
        if (commitment.commitBlock >= acquisition.receivedBlock) return false;

        nextCommitment = index + 1;
        commitment.bound = true;
        commitment.acquisitionId = acquisitionId;
        bytes32 requestId = computeRequestId(acquisitionId, acquisition.tokenId, index, commitment.hash);
        acquisition.status = Status.Requested;
        acquisition.commitmentIndex = index;
        acquisition.requestBlock = block.number;
        acquisition.requestId = requestId;
        emit FlipRequested(acquisitionId, acquisition.tokenId, requestId);
        return true;
    }

    // ---------------------------------------------------------------------------------------------
    // Resolution
    // ---------------------------------------------------------------------------------------------

    /// @notice Reveals the secret behind the acquisition's commitment and resolves the flip.
    function reveal(uint256 acquisitionId, bytes32 secret) external nonReentrant {
        Acquisition storage acquisition = _get(acquisitionId);
        if (acquisition.status != Status.Requested) revert InvalidStatus(acquisitionId, acquisition.status);
        if (block.number > acquisition.requestBlock + REVEAL_WINDOW_BLOCKS) revert RevealWindowClosed(acquisitionId);
        if (keccak256(abi.encodePacked(secret)) != _commitments[acquisition.commitmentIndex].hash) revert BadSecret();

        uint256 roll = rollFor(secret, acquisition.requestId);
        emit FlipRevealed(acquisitionId, roll);

        bool burned = isBurnRoll(roll);
        address recipient = BURN_ADDRESS;
        uint256 weight = 0;
        if (!burned) {
            (address winner, uint256 winnerWeight) = PICKER.pick(roll);
            if (winner == address(0)) {
                burned = true;
            } else {
                recipient = winner;
                weight = winnerWeight;
            }
        }
        _resolve(acquisitionId, burned, recipient, weight);
    }

    /// @notice Force-burns an acquisition whose reveal window closed, or that never got a commitment in
    /// time. Anyone may call it.
    function expire(uint256 acquisitionId) external nonReentrant {
        Acquisition storage acquisition = _get(acquisitionId);
        if (acquisition.status == Status.Requested) {
            if (block.number <= acquisition.requestBlock + REVEAL_WINDOW_BLOCKS) revert NotExpired(acquisitionId);
        } else if (acquisition.status == Status.Pending) {
            if (block.number <= acquisition.receivedBlock + PENDING_TIMEOUT_BLOCKS) revert NotExpired(acquisitionId);
        } else {
            revert InvalidStatus(acquisitionId, acquisition.status);
        }
        emit FlipExpired(acquisitionId);
        _resolve(acquisitionId, true, BURN_ADDRESS, 0);
    }

    /// @dev Effects and events first, the NFT transfer last. `transferFrom` (not safe) so that a
    /// recipient that cannot receive NFTs can never block the pipeline.
    function _resolve(uint256 acquisitionId, bool burned, address recipient, uint256 weight) private {
        Acquisition storage acquisition = _acquisitions[acquisitionId];
        uint256 tokenId = acquisition.tokenId;
        acquisition.status = Status.Resolved;
        acquisition.burned = burned;
        acquisition.recipient = recipient;
        emit FlipResolved(acquisitionId, tokenId, burned, recipient);
        if (burned) {
            emit Burned(tokenId, recipient);
        } else {
            emit Airdropped(tokenId, recipient, weight);
        }
        NFT.transferFrom(address(this), recipient, tokenId);
    }

    // ---------------------------------------------------------------------------------------------
    // Views and pure helpers
    // ---------------------------------------------------------------------------------------------

    /// @notice The request id an acquisition is bound under.
    function computeRequestId(uint256 acquisitionId, uint256 tokenId, uint256 commitmentIndex, bytes32 hash)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(address(this), block.chainid, acquisitionId, tokenId, commitmentIndex, hash));
    }

    /// @notice The randomness derived from a revealed secret and a request id.
    function rollFor(bytes32 secret, bytes32 requestId) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(secret, requestId)));
    }

    /// @notice True when `roll` lands in the burning share.
    function isBurnRoll(uint256 roll) public pure returns (bool) {
        return roll % BPS_DENOMINATOR < FLIP_BURN_BPS;
    }

    /// @notice Number of acquisitions ever received; ids run from 0 to this value minus one.
    function acquisitionCount() external view returns (uint256) {
        return _acquisitions.length;
    }

    /// @notice An acquisition by id.
    function getAcquisition(uint256 acquisitionId) external view returns (Acquisition memory) {
        return _get(acquisitionId);
    }

    /// @notice Number of commitments ever made.
    function commitmentCount() external view returns (uint256) {
        return _commitments.length;
    }

    /// @notice A commitment by index.
    function getCommitment(uint256 index) external view returns (Commitment memory) {
        return _commitments[index];
    }

    /// @notice Commitments queued but not yet bound to an acquisition.
    function availableCommitments() external view returns (uint256) {
        return _commitments.length - nextCommitment;
    }

    function _get(uint256 acquisitionId) private view returns (Acquisition storage) {
        if (acquisitionId >= _acquisitions.length) revert UnknownAcquisition(acquisitionId);
        return _acquisitions[acquisitionId];
    }
}
