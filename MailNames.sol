// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// File Version: 0.0.7 (05/10/2025)
// Changelog: 
// - 0.0.7 (05/10): Ensured names can be renewed at any point after allowanceEnd. 
// - 0.0.6 (05/10): Implemented checkin queue with token locks via MailLocker, dynamic min required (1*2^len wei, assume 18dec), wait (10m+6h*len, cap 2w); advance() external, called post-queue. Replaced checkIn with queueCheckIn queue system; added mailToken/mailLocker/owner/PendingCheckin/pendingCheckins/nextProcessIndex; setters; helpers for calc; advance processes one at a time.
// - 0.0.5 (05/10): Fully implemented safeTransferFrom with onERC721Received check for contract receivers. 
// - 0.0.4 (04/10): Fixed ownership to single ERC721 ownerOf (removed retainer/retainerNames), efficient balanceOf via counter, enumerable allNameHashes for getNameRecords, bidderNameHashes for getBidderBids, centralized _transfer, improved _findBestBid, fixed subname push syntax, removed getRetainerNames, safeTransferFrom direct call, consistency across functions
// - 0.0.3 (04/10): Added new functions, mappings and variables for ERC721 compatibility
// - 0.0.2 (03/10): Added getBidderNameBids for granular bid retrieval
// - 0.0.2 (03/10): Patched DoS in closeBid, added fee-on-transfer support, optimized view functions
// - 0.0.1 (03/10): Initial implementation with minting, bidding, subnames

// Interface for external contract interactions
interface IERC20 {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// Inline interface for ERC721 receivers
interface IERC721Receiver {
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}

    // Inline interface for MailLocker
    interface MailLocker {
        function depositLock(uint256 amount, address user, uint256 unlockTime) external;
    }

contract MailNames {
    // Structs for name, subname, and custom records
    struct NameRecord {
        string name; // Domain name (no spaces, <=24 chars)
        uint256 nameHash; // keccak256 hash of name
        uint256 tokenId; // ERC721-compatible token ID
        uint256 allowanceEnd; // Timestamp when allowance expires
        CustomRecord[5] customRecords; // Custom records for name
    }

    struct SubnameRecord {
        uint256 parentHash; // Hash of parent name
        string subname; // Subname string
        uint256 subnameHash; // keccak256 hash of subname
        CustomRecord[5] customRecords; // Custom records for subname
    }

    struct Bid {
        address bidder; // Bidder address
        uint256 amount; // Bid amount in payment token or ETH
        uint256 timestamp; // Bid placement time
        bool isETH; // Indicates if bid is in ETH
        address token; // ERC20 token address for non-ETH bids
    }

    struct CustomRecord {
        string text; // General text (e.g., description)
        string resolver; // Resolver info
        string contentHash; // Content hash (e.g., IPFS)
        uint256 ttl; // Time-to-live
        address targetAddress; // Associated address
    }

    // State variables
    mapping(uint256 => NameRecord) private nameRecords; // nameHash => NameRecord
    mapping(uint256 => SubnameRecord[]) private subnameRecords; // nameHash => SubnameRecord[]
    mapping(uint256 => Bid[]) public bids; // nameHash => Bid[]
    uint256[] private allNameHashes; // Enumerable list of all minted nameHashes
    mapping(address => uint256[]) private bidderNameHashes; // bidder => nameHashes with active bids
    mapping(address => mapping(uint256 => uint256[])) private bidderBids; // bidder => nameHash => bidIndices
    uint256 public constant ALLOWANCE_PERIOD = 365 days;
    uint256 public constant GRACE_PERIOD = 30 days;
    
    // ERC721 state
    uint256 public totalNames; // Starts at 0, increments per mint
    mapping(uint256 => uint256) public tokenIdToNameHash; // tokenId => nameHash
    mapping(uint256 => uint256) public nameHashToTokenId; // nameHash => tokenId
    mapping(address => uint256) private _balances; // owner => total token count
    mapping(uint256 => address) public ownerOf; // tokenId => owner
    mapping(uint256 => address) public getApproved; // tokenId => approved spender
    mapping(address => mapping(address => bool)) public isApprovedForAll; // owner => operator => approved
    uint256 public constant MAX_NAME_LENGTH = 24;
    uint256 public constant MAX_STRING_LENGTH = 1024;
    
    // Events
    event NameMinted(uint256 indexed nameHash, string name, address owner);
    event NameCheckedIn(uint256 indexed nameHash, address owner);
    event BidPlaced(uint256 indexed nameHash, address bidder, uint256 amount, bool isETH);
    event BidSettled(uint256 indexed nameHash, address newOwner, uint256 amount, bool isETH);
    event BidClosed(uint256 indexed nameHash, address bidder, uint256 amount, bool isETH);
    event SubnameMinted(uint256 indexed parentHash, uint256 subnameHash, string subname, address owner);
    event RecordsUpdated(uint256 indexed nameHash, address owner);
    
    // ERC721 events
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    
        // ownership event
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
        // Events (queue)
    event QueueCheckInQueued(uint256 indexed nameHash, address indexed user, uint256 minRequired, uint256 waitDuration);
    event CheckInProcessed(uint256 indexed nameHash, address indexed user);
    
        // state for queue/locker
    address public owner;
    address public mailToken;
    address public mailLocker;
    struct PendingCheckin {
        uint256 nameHash;
        address user;
        uint256 queuedTime;
        uint256 waitDuration;
    }
    PendingCheckin[] public pendingCheckins;
    uint256 public nextProcessIndex;

    // New: Owner init (called post-deploy)
    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // Helper: Convert string to hash
    function _stringToHash(string memory _str) private pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(_str)));
    }

    // Helper: Validate name (no spaces, <=24 chars)
    function _validateName(string memory _name) private pure returns (bool) {
        bytes memory nameBytes = bytes(_name);
        if (nameBytes.length > MAX_NAME_LENGTH || nameBytes.length == 0) {
            return false;
        }
        for (uint256 i = 0; i < nameBytes.length; i++) {
            if (nameBytes[i] == " ") return false;
        }
        return true;
    }

    // Helper: Validate string lengths in records
    function _validateRecord(CustomRecord memory _record) private pure {
        require(bytes(_record.text).length <= MAX_STRING_LENGTH, "Text too long");
        require(bytes(_record.resolver).length <= MAX_STRING_LENGTH, "Resolver too long");
        require(bytes(_record.contentHash).length <= MAX_STRING_LENGTH, "Content hash too long");
    }
    
    // Helper: Improved - find highest ETH bid or oldest ERC20 bid
    function _findBestBid(uint256 _nameHash) private view returns (uint256 bestIndex, bool found) {
        Bid[] memory nameBids = bids[_nameHash];
        uint256 highestETHAmount = 0;
        uint256 bestETHIndex = type(uint256).max;
        uint256 oldestERC20Time = type(uint256).max;
        uint256 bestERC20Index = type(uint256).max;
        for (uint256 i = 0; i < nameBids.length; i++) {
            Bid memory bid = nameBids[i];
            if (bid.isETH) {
                if (bid.amount > highestETHAmount) {
                    highestETHAmount = bid.amount;
                    bestETHIndex = i;
                }
            } else {
                if (bid.timestamp < oldestERC20Time) {
                    oldestERC20Time = bid.timestamp;
                    bestERC20Index = i;
                }
            }
        }
        if (bestETHIndex != type(uint256).max) {
            bestIndex = bestETHIndex;
            found = true;
        } else if (bestERC20Index != type(uint256).max) {
            bestIndex = bestERC20Index;
            found = true;
        }
    }

    // Internal: Centralized ERC721 transfer logic
    function _transfer(uint256 _tokenId, address _to) internal {
        require(_to != address(0), "Invalid to");
        address from = ownerOf[_tokenId];
        require(from != address(0), "Token not minted");
        require(from == msg.sender || getApproved[_tokenId] == msg.sender || isApprovedForAll[from][msg.sender], "Unauthorized");
        
        _balances[from]--;
        _balances[_to]++;
        ownerOf[_tokenId] = _to;
        delete getApproved[_tokenId];
        
        emit Transfer(from, _to, _tokenId);
    }

    // Changelog: 0.0.4 (04/10/2025) - Use ownerOf via nameHashToTokenId, add allNameHashes, _balances++, no retainer
    function mintName(string memory _name) external {
        require(_validateName(_name), "Invalid name");
        uint256 nameHash = _stringToHash(_name);
        require(nameRecords[nameHash].nameHash == 0, "Name already minted");
        uint256 tokenId = totalNames++;
        NameRecord storage record = nameRecords[nameHash];
        record.name = _name;
        record.nameHash = nameHash;
        record.tokenId = tokenId;
        record.allowanceEnd = block.timestamp + ALLOWANCE_PERIOD;
        for (uint256 i = 0; i < 5; i++) {
            record.customRecords[i] = CustomRecord("", "", "", 0, address(0));
        }
        tokenIdToNameHash[tokenId] = nameHash;
        nameHashToTokenId[nameHash] = tokenId;
        ownerOf[tokenId] = msg.sender;
        _balances[msg.sender]++;
        allNameHashes.push(nameHash);
        emit NameMinted(nameHash, _name, msg.sender);
        emit Transfer(address(0), msg.sender, tokenId);
    }

    // Changelog: 0.0.4 (04/10/2025) - Fix push syntax, use ownerOf check via nameHashToTokenId
    function mintSubname(string memory _parentName, string memory _subname) external {
        require(_validateName(_subname), "Invalid subname");
        uint256 parentHash = _stringToHash(_parentName);
        uint256 tokenId = nameHashToTokenId[parentHash];
        require(tokenId != 0 && ownerOf[tokenId] == msg.sender, "Not parent owner");
        uint256 subnameHash = _stringToHash(_subname);
        subnameRecords[parentHash].push(); // Push default SubnameRecord
        uint256 newIndex = subnameRecords[parentHash].length - 1;
        SubnameRecord storage subname = subnameRecords[parentHash][newIndex];
        subname.parentHash = parentHash;
        subname.subname = _subname;
        subname.subnameHash = subnameHash;
        for (uint256 i = 0; i < 5; i++) {
            subname.customRecords[i] = CustomRecord("", "", "", 0, address(0));
        }
        emit SubnameMinted(parentHash, subnameHash, _subname, msg.sender);
    }

    // Changelog: 0.0.6 (05/10/2025) - Setters for locker/token (owner-only)
    function setMailToken(address _mailToken) external onlyOwner {
        mailToken = _mailToken;
    }

    function setMailLocker(address _mailLocker) external onlyOwner {
        mailLocker = _mailLocker;
    }

    // Helper: Calc min required wei (1 * 2^queueLen, assume 18dec token)
    function _calculateMinRequired(uint256 _queueLen) private pure returns (uint256) {
        return 1 * (2 ** _queueLen);
    }

    // Helper: Calc wait duration (10m + 6h * queueLen, cap 2w)
    function _calculateWaitDuration(uint256 _queueLen) private pure returns (uint256) {
        uint256 wait = 10 minutes + 6 hours * _queueLen;
        return wait > 2 weeks ? 2 weeks : wait;
    }

    // Helper: Process next if ready (extends allowance, assumes still owner—risk if transferred)
    function _processNextCheckin() private {
        if (nextProcessIndex >= pendingCheckins.length) return;
        PendingCheckin memory nextCheck = pendingCheckins[nextProcessIndex];
        if (block.timestamp < nextCheck.queuedTime + nextCheck.waitDuration) return;
        uint256 tokenId = nameHashToTokenId[nextCheck.nameHash];
        require(tokenId != 0 && ownerOf[tokenId] == nextCheck.user, "No longer owner");
        NameRecord storage record = nameRecords[nextCheck.nameHash];
        record.allowanceEnd = block.timestamp + ALLOWANCE_PERIOD;
        emit NameCheckedIn(nextCheck.nameHash, nextCheck.user);
        emit CheckInProcessed(nextCheck.nameHash, nextCheck.user);
        nextProcessIndex++;
    }

// Changelog: 0.0.7 (05/10/2025) - Modified queueCheckIn: Allow post-grace (anytime after allowanceEnd); retain auto-settle in place*Bid on expired (post +GRACE_PERIOD)
function queueCheckIn(uint256 _nameHash) external {
    uint256 tokenId = nameHashToTokenId[_nameHash];
    require(tokenId != 0 && ownerOf[tokenId] == msg.sender, "Not owner");
    NameRecord storage record = nameRecords[_nameHash];
    require(block.timestamp > record.allowanceEnd, "Not expired"); // Removed grace upper bound
    uint256 queueLen = pendingCheckins.length - nextProcessIndex;
    uint256 minRequired = _calculateMinRequired(queueLen);
    IERC20(mailToken).transferFrom(msg.sender, address(this), minRequired);
    uint8 decimals = IERC20(mailToken).decimals();
    uint256 normalized = minRequired / (10 ** decimals);
    MailLocker(mailLocker).depositLock(normalized, msg.sender, block.timestamp + 365 days * 10);
    uint256 waitDuration = _calculateWaitDuration(queueLen);
    pendingCheckins.push(PendingCheckin(_nameHash, msg.sender, block.timestamp, waitDuration));
    emit QueueCheckInQueued(_nameHash, msg.sender, minRequired, waitDuration);
    this.advance();
}

    // Changelog: 0.0.6 (05/10/2025) - External advance: Processes one ready checkin (gas safe, callable anytime)
    function advance() external {
        _processNextCheckin();
    }
    
        // Changelog: 0.0.6 (05/10/2025) - Owner-only transferOwnership: Sets new owner, emits event
    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Invalid owner");
        owner = _newOwner;
        emit OwnershipTransferred(msg.sender, _newOwner);
    }

    // Changelog: 0.0.4 (04/10/2025) - Add bidderNameHashes update
    function placeTokenBid(string memory _name, uint256 _amount, address _token) external {
        uint256 nameHash = _stringToHash(_name);
        uint256 tokenId = nameHashToTokenId[nameHash];
        require(tokenId != 0, "Name not minted");
        require(_amount > 0, "Invalid bid amount");
        IERC20 token = IERC20(_token);
        uint8 decimals = token.decimals();
        uint256 transferAmount = _amount * (10 ** decimals);
        uint256 balanceBefore = token.balanceOf(address(this));
        require(token.transferFrom(msg.sender, address(this), transferAmount), "Transfer failed");
        uint256 balanceAfter = token.balanceOf(address(this));
        uint256 receivedAmount = (balanceAfter - balanceBefore) / (10 ** decimals);
        require(receivedAmount > 0, "No tokens received");
        uint256 bidIndex = bids[nameHash].length;
        bids[nameHash].push(Bid(msg.sender, receivedAmount, block.timestamp, false, _token));
        bidderBids[msg.sender][nameHash].push(bidIndex);
        // Update bidderNameHashes if new
        uint256[] storage names = bidderNameHashes[msg.sender];
        bool hasName = false;
        for (uint256 i = 0; i < names.length; i++) {
            if (names[i] == nameHash) {
                hasName = true;
                break;
            }
        }
        if (!hasName) {
            names.push(nameHash);
        }
        emit BidPlaced(nameHash, msg.sender, receivedAmount, false);
        NameRecord storage record = nameRecords[nameHash];
        if (block.timestamp > record.allowanceEnd + GRACE_PERIOD) {
            (uint256 bestIndex, bool found) = _findBestBid(nameHash);
            if (found) _settleBid(nameHash, bestIndex);
        }
    }

    // Changelog: 0.0.4 (04/10/2025) - Add bidderNameHashes update, remove redundant balance check
    function placeETHBid(string memory _name) external payable {
        uint256 nameHash = _stringToHash(_name);
        uint256 tokenId = nameHashToTokenId[nameHash];
        require(tokenId != 0, "Name not minted");
        require(msg.value > 0, "Invalid bid amount");
        uint256 bidIndex = bids[nameHash].length;
        bids[nameHash].push(Bid(msg.sender, msg.value, block.timestamp, true, address(0)));
        bidderBids[msg.sender][nameHash].push(bidIndex);
        // Update bidderNameHashes if new
        uint256[] storage names = bidderNameHashes[msg.sender];
        bool hasName = false;
        for (uint256 i = 0; i < names.length; i++) {
            if (names[i] == nameHash) {
                hasName = true;
                break;
            }
        }
        if (!hasName) {
            names.push(nameHash);
        }
        emit BidPlaced(nameHash, msg.sender, msg.value, true);
        NameRecord storage record = nameRecords[nameHash];
        if (block.timestamp > record.allowanceEnd + GRACE_PERIOD) {
            (uint256 bestIndex, bool found) = _findBestBid(nameHash);
            if (found) _settleBid(nameHash, bestIndex);
        }
    }

    // Changelog: 0.0.4 (04/10/2025) - If no more bids, remove from bidderNameHashes
    function closeBid(uint256 _nameHash, uint256 _bidIndex) external {
        Bid[] storage nameBids = bids[_nameHash];
        require(_bidIndex < nameBids.length, "Invalid bid index");
        Bid memory bid = nameBids[_bidIndex];
        require(bid.bidder == msg.sender, "Not bidder");
        if (bid.isETH) {
            payable(msg.sender).transfer(bid.amount);
        } else {
            IERC20(bid.token).transfer(msg.sender, bid.amount * (10 ** IERC20(bid.token).decimals()));
        }
        // Swap and pop to remove bid efficiently
        nameBids[_bidIndex] = nameBids[nameBids.length - 1];
        nameBids.pop();
        // Update bidderBids mapping
        uint256[] storage indices = bidderBids[msg.sender][_nameHash];
        for (uint256 i = 0; i < indices.length; i++) {
            if (indices[i] == _bidIndex) {
                indices[i] = indices[indices.length - 1];
                indices.pop();
                break;
            }
        }
        // If no more bids, remove nameHash from bidderNameHashes
        if (indices.length == 0) {
            uint256[] storage names = bidderNameHashes[msg.sender];
            for (uint256 i = 0; i < names.length; i++) {
                if (names[i] == _nameHash) {
                    names[i] = names[names.length - 1];
                    names.pop();
                    break;
                }
            }
        }
        emit BidClosed(_nameHash, msg.sender, bid.amount, bid.isETH);
    }

    // Changelog: 0.0.4 (04/10/2025) - Removed allowanceEnd reset
    function _settleBid(uint256 _nameHash, uint256 _bidIndex) private {
        NameRecord storage record = nameRecords[_nameHash];
        uint256 tokenId = record.tokenId;
        address oldOwner = ownerOf[tokenId];
        Bid memory bid = bids[_nameHash][_bidIndex];
        // Transfer funds to old owner
        if (bid.isETH) {
            payable(oldOwner).transfer(bid.amount);
        } else {
            IERC20(bid.token).transfer(oldOwner, bid.amount * (10 ** IERC20(bid.token).decimals()));
        }
        _transfer(tokenId, bid.bidder); // Updates ownerOf, _balances, emits Transfer
        emit BidSettled(_nameHash, bid.bidder, bid.amount, bid.isETH);
    }

    // Accept bid during valid allowance
    function acceptBid(uint256 _nameHash, uint256 _bidIndex) external {
        uint256 tokenId = nameHashToTokenId[_nameHash];
        require(tokenId != 0 && ownerOf[tokenId] == msg.sender, "Not owner");
        NameRecord storage record = nameRecords[_nameHash];
        require(block.timestamp <= record.allowanceEnd, "Allowance expired");
        _settleBid(_nameHash, _bidIndex);
    }

    // Changelog: 0.0.4 (04/10/2025) - Call _transfer via tokenId, no retainerNames
    function transferName(uint256 _nameHash, address _newOwner) external {
        uint256 tokenId = nameHashToTokenId[_nameHash];
        require(tokenId != 0, "Name not minted");
        _transfer(tokenId, _newOwner);
    }

    // Changelog: 0.0.4 (04/10/2025) - Removed allowanceEnd update
    function transferFrom(address _from, address _to, uint256 _tokenId) external {
        require(_from == ownerOf[_tokenId], "Wrong from");
        uint256 nameHash = tokenIdToNameHash[_tokenId];
        require(nameHash != 0, "Invalid tokenId");
        _transfer(_tokenId, _to);
    }
    
       // Helper: Checks if address is contract (non-zero code length)
    function _isContract(address _account) private view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_account)
        }
        return size > 0;
    }
    
        // Helper: Checks if receiver is contract and calls onERC721Received, reverts if fails
    function _checkOnERC721Received(address _to, address _from, uint256 _tokenId, bytes memory _data) private {
        if (_isContract(_to)) {
            try IERC721Receiver(_to).onERC721Received(msg.sender, _from, _tokenId, _data) returns (bytes4 retval) {
                require(retval == IERC721Receiver.onERC721Received.selector, "ERC721: transfer to non ERC721Receiver implementer");
            } catch {
                revert("ERC721: transfer to non ERC721Receiver implementer");
            }
        }
    }

    // Changelog: 0.0.5 (05/10/2025) - Added IERC721Receiver interface above contract; implemented full safeTransferFrom with _checkOnERC721Received call after _transfer to ensure receiver hook succeeds if _to is contract
    function safeTransferFrom(address _from, address _to, uint256 _tokenId, bytes memory _data) external {
        require(_from == ownerOf[_tokenId], "Wrong from");
        uint256 nameHash = tokenIdToNameHash[_tokenId];
        require(nameHash != 0, "Invalid tokenId");
        _transfer(_tokenId, _to);
        _checkOnERC721Received(_to, _from, _tokenId, _data);
    }

    // Changelog: 0.0.4 (04/10/2025) - Use ownerOf check via nameHashToTokenId
    function setCustomRecord(uint256 _nameHash, uint256 _index, CustomRecord memory _record) external {
        _validateRecord(_record);
        uint256 tokenId = nameHashToTokenId[_nameHash];
        require(tokenId != 0 && ownerOf[tokenId] == msg.sender, "Not owner");
        require(_index < 5, "Invalid index");
        nameRecords[_nameHash].customRecords[_index] = _record;
        emit RecordsUpdated(_nameHash, msg.sender);
    }
    
    // Changelog: 0.0.6 (05/10/2025) - Added getName view: Resolves name string to owner address or reverts if unregistered
function getName(string memory _name) external view returns (address _owner) {
    uint256 nameHash = _stringToHash(_name);
    uint256 tokenId = nameHashToTokenId[nameHash];
    require(tokenId != 0, "Name not registered!");
    return ownerOf[tokenId];
}

    // Changelog: 0.0.4 (04/10/2025) - Use ownerOf check via nameHashToTokenId for parent
    function setSubnameRecord(uint256 _parentHash, uint256 _subnameIndex, uint256 _recordIndex, CustomRecord memory _record) external {
        _validateRecord(_record);
        uint256 tokenId = nameHashToTokenId[_parentHash];
        require(tokenId != 0 && ownerOf[tokenId] == msg.sender, "Not parent owner");
        require(_subnameIndex < subnameRecords[_parentHash].length, "Invalid subname index");
        require(_recordIndex < 5, "Invalid record index");
        subnameRecords[_parentHash][_subnameIndex].customRecords[_recordIndex] = _record;
        emit RecordsUpdated(_parentHash, msg.sender);
    }

    // View functions
    // Changelog: 0.0.4 (04/10/2025) - Use allNameHashes for proper enumeration from step
    function getNameRecords(uint256 step, uint256 maxIterations) external view returns (NameRecord[] memory records) {
        uint256 total = allNameHashes.length;
        uint256 end = step + maxIterations > total ? total : step + maxIterations;
        uint256 count = end > step ? end - step : 0;
        records = new NameRecord[](count);
        for (uint256 i = 0; i < count; i++) {
            uint256 nameHash = allNameHashes[step + i];
            records[i] = nameRecords[nameHash];
        }
    }
    
    // Get subname index by parent name and subname string
    function getSubnameID(string memory _parentName, string memory _subname) external view returns (uint256 subnameIndex, bool found) {
        uint256 parentHash = _stringToHash(_parentName);
        uint256 subnameHash = _stringToHash(_subname);
        SubnameRecord[] storage subnames = subnameRecords[parentHash];
        for (uint256 i = 0; i < subnames.length; i++) {
            if (subnames[i].subnameHash == subnameHash) {
                return (i, true);
            }
        }
        return (0, false);
    }

    // Get custom records for a specific subname
    function getSubRecords(string memory _parentName, string memory _subname) external view returns (CustomRecord[5] memory customRecords) {
        uint256 parentHash = _stringToHash(_parentName);
        (uint256 subnameIndex, bool found) = this.getSubnameID(_parentName, _subname);
        require(found, "Subname not found");
        return subnameRecords[parentHash][subnameIndex].customRecords;
    }

    // Get subnames for a parent name with pagination
    function getSubnames(string memory _parentName, uint256 step, uint256 maxIterations) external view returns (string[] memory subnames) {
        uint256 parentHash = _stringToHash(_parentName);
        SubnameRecord[] storage subs = subnameRecords[parentHash];
        uint256 length = subs.length;
        uint256 end = step + maxIterations > length ? length : step + maxIterations;
        uint256 count = end > step ? end - step : 0;
        subnames = new string[](count);
        for (uint256 i = 0; i < count; i++) {
            subnames[i] = subs[step + i].subname;
        }
    }
    
    function getNameBids(string memory _name, uint256 maxIterations) external view returns (Bid[] memory nameBids) {
        uint256 nameHash = _stringToHash(_name);
        Bid[] storage allBids = bids[nameHash];
        uint256 length = allBids.length > maxIterations ? maxIterations : allBids.length;
        nameBids = new Bid[](length);
        for (uint256 i = 0; i < length; i++) {
            nameBids[i] = allBids[i];
        }
    }

    // Changelog: 0.0.4 (04/10/2025) - Use bidderNameHashes for iteration over actual nameHashes
    function getBidderBids(address _bidder, uint256 maxIterations) external view returns (uint256[] memory nameHashes, Bid[][] memory bidderBidsArray) {
        uint256[] memory hashes = bidderNameHashes[_bidder];
        uint256 length = hashes.length > maxIterations ? maxIterations : hashes.length;
        nameHashes = new uint256[](length);
        bidderBidsArray = new Bid[][](length);
        for (uint256 i = 0; i < length; i++) {
            uint256 nameHash = hashes[i];
            nameHashes[i] = nameHash;
            uint256[] memory indices = bidderBids[_bidder][nameHash];
            bidderBidsArray[i] = new Bid[](indices.length);
            for (uint256 j = 0; j < indices.length; j++) {
                bidderBidsArray[i][j] = bids[nameHash][indices[j]];
            }
        }
    }

    function getBidderNameBids(address _bidder, string memory _name) external view returns (Bid[] memory nameBids) {
        uint256 nameHash = _stringToHash(_name);
        uint256[] memory indices = bidderBids[_bidder][nameHash];
        nameBids = new Bid[](indices.length);
        for (uint256 i = 0; i < indices.length; i++) {
            nameBids[i] = bids[nameHash][indices[i]];
        }
    }

    function approve(address _to, uint256 _tokenId) external {
        uint256 nameHash = tokenIdToNameHash[_tokenId];
        require(nameHash != 0, "Invalid tokenId");
        address tokenOwner = ownerOf[_tokenId];
        require(msg.sender == tokenOwner || isApprovedForAll[tokenOwner][msg.sender], "Unauthorized");
        getApproved[_tokenId] = _to;
        emit Approval(tokenOwner, _to, _tokenId);
    }

    function setApprovalForAll(address _operator, bool _approved) external {
        isApprovedForAll[msg.sender][_operator] = _approved;
        emit ApprovalForAll(msg.sender, _operator, _approved);
    }

    // Changelog: 0.0.4 (04/10/2025) - Simple O(1) return from _balances counter
    function balanceOf(address _owner) external view returns (uint256) {
        require(_owner != address(0), "Zero address");
        return _balances[_owner];
    }
}