// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// File Version: 0.0.22 (07/11/2025)
// Changelog:
// - 08/11/2025: Removed unnecessary token count check in various functions. 
// - 07/11/2025: Added time-warp system (currentTime, isWarped, warp(), unWarp(), _now()) to MailNames, IMailLocker, IMailMarket for VM testing consistency with TrustlessFund
// - 0.0.20 (06/10): Updated getNameRecords to return single record; added getSettlementById
// - 0.0.19 (06/10): Updated getNameRecords, getPendingSettlements to use name string
// - 0.0.18 (06/10): Added getPendingSettlements for paginated view
// - 0.0.17 (06/10): Removed queueSettlement; updated _settleBid to handle all post-grace queuing
// - 0.0.16 (06/10): Changed GRACE_PERIOD to 7 days; updated _processNextCheckin to clear pendingSettlements on renewal
// - 0.0.15 (06/10): Added getNameByTokenId to retrieve name string by token ID
// - 0.0.14 (06/10): Added PendingSettlement struct, processSettlement; updated _settleBid to queue post-grace settlements
// - 0.0.13 (05/10): Added acceptMarketBid to call IMailMarket.settleBid for owner-initiated bid acceptance
// - 0.0.12 (05/10): Removed bidding, added mailMarket/setter, updated _settleBid, removed _nameHash from _processQueueRequirements
// - 0.0.11 (05/10): Added SettlementData, _removeBidFromArray, _transferBidFunds, _handlePostGraceSettlement, refactored _settleBid
// - 0.0.10 (05/10): Added TokenTransferData, BidValidation, helpers, refactored queueCheckIn
// - 0.0.9 (05/10): Restructured bidding, added graceEnd
// - 0.0.8 (05/10): Renewable names post-allowanceEnd
// - 0.0.7 (05/10): Added transferOwnership
// - 0.0.6 (05/10): Added checkin queue, IMailLocker integration
// - 0.0.5 (05/10): Implemented safeTransferFrom
// - 0.0.4 (04/10): Fixed ownership, added enumerable views
// - 0.0.3 (04/10): Added ERC721 compatibility
// - 0.0.2 (03/10): Added bidder views, fixed closeBid
// - 0.0.1 (03/10): Initial implementation

interface IERC20 {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external returns (bytes4);
}

interface IMailLocker {
    function depositLock(uint256 amount, address user, uint256 unlockTime) external;
}

interface IMailMarket {
    function settleBid(uint256 _nameHash, uint256 _bidIndex, bool _isETH, address _token) external;
}

contract MailNames {
    struct NameRecord {
        string name;
        uint256 nameHash;
        uint256 tokenId;
        uint256 allowanceEnd;
        uint256 graceEnd;
        CustomRecord[5] customRecords;
    }

    struct SubnameRecord {
        uint256 parentHash;
        string subname;
        uint256 subnameHash;
        CustomRecord[5] customRecords;
    }

    struct CustomRecord {
        string text;
        string resolver;
        string contentHash;
        uint256 ttl;
        address targetAddress;
    }

    struct SettlementData {
        uint256 nameHash;
        uint256 tokenId;
        address oldOwner;
        address newOwner;
        uint256 amount;
        bool postGrace;
    }
    
    struct PendingCheckin {
        uint256 nameHash;
        address user;
        uint256 queuedTime;
        uint256 waitDuration;
    }
    
            // New (0.0.14) struct for pending settlements
        struct PendingSettlement {
            uint256 nameHash;
            uint256 bidIndex;
            bool isETH;
            address token;
            uint256 queueTime;
        }

    mapping(uint256 => NameRecord) private nameRecords;
    mapping(uint256 => SubnameRecord[]) private subnameRecords;
    uint256[] private allNameHashes;
    uint256 public constant ALLOWANCE_PERIOD = 365 days;
    uint256 public constant GRACE_PERIOD = 7 days;
    uint256 public constant MAX_NAME_LENGTH = 24;
    uint256 public constant MAX_STRING_LENGTH = 1024;

    uint256 public totalNames;
    mapping(uint256 => uint256) public tokenIdToNameHash;
    mapping(uint256 => uint256) public nameHashToTokenId;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    address public owner;
    address public mailToken;
    address public mailLocker;
    address public mailMarket;
    
    uint256 public currentTime;
    bool public isWarped;
            // New (0.0.14) array to store pending settlements
        PendingSettlement[] public pendingSettlements;

    PendingCheckin[] public pendingCheckins;
    uint256 public nextProcessIndex;

    event NameMinted(uint256 indexed nameHash, string name, address owner);
    event NameCheckedIn(uint256 indexed nameHash, address owner);
    event SubnameMinted(uint256 indexed parentHash, uint256 subnameHash, string subname, address owner);
    event RecordsUpdated(uint256 indexed nameHash, address owner);
    event GraceReset(uint256 indexed nameHash, address indexed newOwner);
    event QueueCheckInQueued(uint256 indexed nameHash, address indexed user, uint256 minRequired, uint256 waitDuration);
    event CheckInProcessed(uint256 indexed nameHash, address indexed user);
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
          // New (0.0.14) events for settlement queueing and processing
        event SettlementProcessed(uint256 indexed nameHash, address newOwner);

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }
    
function warp(uint256 newTimestamp) external onlyOwner {
    currentTime = newTimestamp;
    isWarped = true;
}

function unWarp() external onlyOwner {
    isWarped = false;
}

function _now() internal view returns (uint256) {
    return isWarped ? currentTime : block.timestamp;
}

    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Invalid owner");
        address oldOwner = owner;
        owner = _newOwner;
        emit OwnershipTransferred(oldOwner, _newOwner);
    }

    function setMailToken(address _mailToken) external onlyOwner {
        mailToken = _mailToken;
    }

    function setMailLocker(address _mailLocker) external onlyOwner {
        mailLocker = _mailLocker;
    }

    function setMailMarket(address _mailMarket) external onlyOwner {
        mailMarket = _mailMarket;
    }

    function _stringToHash(string memory _str) private pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(_str)));
    }

    function _validateName(string memory _name) private pure returns (bool) {
        bytes memory nameBytes = bytes(_name);
        if (nameBytes.length > MAX_NAME_LENGTH || nameBytes.length == 0) return false;
        for (uint256 i = 0; i < nameBytes.length; i++) {
            if (nameBytes[i] == " ") return false;
        }
        return true;
    }

    function _validateRecord(CustomRecord memory _record) private pure {
        require(bytes(_record.text).length <= MAX_STRING_LENGTH, "Text too long");
        require(bytes(_record.resolver).length <= MAX_STRING_LENGTH, "Resolver too long");
        require(bytes(_record.contentHash).length <= MAX_STRING_LENGTH, "Content hash too long");
    }

    function _calculateMinRequired(uint256 _queueLen) private pure returns (uint256) {
        return 1 * (2 ** _queueLen);
    }

    function _calculateWaitDuration(uint256 _queueLen) private pure returns (uint256) {
        uint256 wait = 10 minutes + 6 hours * _queueLen;
        return wait > 2 weeks ? 2 weeks : wait;
    }

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

    function _isContract(address _account) private view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(_account)
        }
        return size > 0;
    }

    function _checkOnERC721Received(address _to, address _from, uint256 _tokenId, bytes memory _data) private {
        if (_isContract(_to)) {
            try IERC721Receiver(_to).onERC721Received(msg.sender, _from, _tokenId, _data) returns (bytes4 retval) {
                require(retval == IERC721Receiver.onERC721Received.selector, "ERC721: transfer to non ERC721Receiver");
            } catch {
                revert("ERC721: transfer to non ERC721Receiver");
            }
        }
    }

    function _processQueueRequirements() private returns (uint256 queueLen, uint256 minRequired) {
        queueLen = pendingCheckins.length - nextProcessIndex;
        minRequired = _calculateMinRequired(queueLen);
        IERC20(mailToken).transferFrom(msg.sender, address(this), minRequired);
        uint8 decimals = IERC20(mailToken).decimals();
        uint256 normalized = minRequired / (10 ** decimals);
        IMailLocker(mailLocker).depositLock(normalized, msg.sender, _now() + 365 days * 10);
    }

         // Changelog: 0.0.17 (06/10/2025) - Queues post-grace settlements, handles checkin
        function _settleBid(uint256 _nameHash, uint256 _bidIndex, bool _isETH, address _token) private {
            SettlementData memory settlement;
            settlement.nameHash = _nameHash;
            settlement.tokenId = nameHashToTokenId[_nameHash];
            settlement.oldOwner = ownerOf[settlement.tokenId];
            settlement.postGrace = _now() > nameRecords[_nameHash].graceEnd;

            if (settlement.postGrace) {
                pendingSettlements.push(PendingSettlement(_nameHash, _bidIndex, _isETH, _token, _now()));
            } else {
                IMailMarket(mailMarket).settleBid(_nameHash, _bidIndex, _isETH, _token);
            }

            if (settlement.postGrace) {
                NameRecord storage record = nameRecords[_nameHash];
                record.graceEnd = _now() + GRACE_PERIOD;
                emit GraceReset(_nameHash, ownerOf[settlement.tokenId]);
                uint256 queueLen = pendingCheckins.length - nextProcessIndex;
                uint256 minReq = _calculateMinRequired(queueLen);
                uint8 dec = IERC20(mailToken).decimals();
                uint256 normMin = minReq / (10 ** dec);
                require(IERC20(mailToken).balanceOf(ownerOf[settlement.tokenId]) >= normMin, "New owner insufficient MAIL");
                IERC20(mailToken).transferFrom(ownerOf[settlement.tokenId], address(this), minReq);
                IMailLocker(mailLocker).depositLock(normMin, ownerOf[settlement.tokenId], _now() + 365 days * 10);
                uint256 waitDuration = _calculateWaitDuration(queueLen);
                pendingCheckins.push(PendingCheckin(_nameHash, ownerOf[settlement.tokenId], _now(), waitDuration));
                emit QueueCheckInQueued(_nameHash, ownerOf[settlement.tokenId], minReq, waitDuration);
            }
        }

        // Changelog: 0.0.14 (06/10/2025) - added to Process queued settlements after 3 weeks
        function processSettlement(uint256 _index) external {
            require(_index < pendingSettlements.length, "Invalid index");
            PendingSettlement memory settlement = pendingSettlements[_index];
            require(_now() >= settlement.queueTime + 3 weeks, "Settlement not ready");
            IMailMarket(mailMarket).settleBid(settlement.nameHash, settlement.bidIndex, settlement.isETH, settlement.token);
            NameRecord storage record = nameRecords[settlement.nameHash];
            record.graceEnd = _now() + GRACE_PERIOD; // Reset secondary grace period
            emit SettlementProcessed(settlement.nameHash, ownerOf[nameHashToTokenId[settlement.nameHash]]);

            // Swap and pop to remove processed settlement
            pendingSettlements[_index] = pendingSettlements[pendingSettlements.length - 1];
            pendingSettlements.pop();
        }

    // Changelog: 0.0.13 (05/10/2025) - Added to allow owner to accept bid via IMailMarket
    function acceptMarketBid(uint256 _nameHash, bool _isETH, address _token, uint256 _bidIndex) external {
        uint256 tokenId = nameHashToTokenId[_nameHash];
        require(tokenId != 0 && ownerOf[tokenId] == msg.sender, "Not owner");
        NameRecord storage record = nameRecords[_nameHash];
        require(_now() <= record.allowanceEnd, "Allowance expired");
        _settleBid(_nameHash, _bidIndex, _isETH, _token);
    }

    function mintName(string memory _name) external {
        require(_validateName(_name), "Invalid name");
        uint256 nameHash = _stringToHash(_name);
        require(nameRecords[nameHash].nameHash == 0, "Name already minted");
        uint256 tokenId = totalNames++;
        NameRecord storage record = nameRecords[nameHash];
        record.name = _name;
        record.nameHash = nameHash;
        record.tokenId = tokenId;
        record.allowanceEnd = _now() + ALLOWANCE_PERIOD;
        record.graceEnd = _now() + ALLOWANCE_PERIOD + GRACE_PERIOD;
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

    function mintSubname(string memory _parentName, string memory _subname) external {
        require(_validateName(_subname), "Invalid subname");
        uint256 parentHash = _stringToHash(_parentName);
        uint256 tokenId = nameHashToTokenId[parentHash];
        require(ownerOf[tokenId] == msg.sender, "Not parent owner");
        uint256 subnameHash = _stringToHash(_subname);
        subnameRecords[parentHash].push();
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

       // Changelog: 0.0.16 (06/10/2025) - Added helper to clear pending settlements for a name
        function _clearPendingSettlements(uint256 _nameHash) private {
            for (uint256 i = 0; i < pendingSettlements.length; i++) {
                if (pendingSettlements[i].nameHash == _nameHash) {
                    pendingSettlements[i] = pendingSettlements[pendingSettlements.length - 1];
                    pendingSettlements.pop();
                    i--; // Adjust index after pop
                }
            }
        }
        
            // Changelog: 0.0.16 (06/10/2025) - Clears pending settlements on check-in
        function _processNextCheckin() private {
            if (nextProcessIndex >= pendingCheckins.length) return;
            PendingCheckin memory nextCheck = pendingCheckins[nextProcessIndex];
            if (_now() < nextCheck.queuedTime + nextCheck.waitDuration) return;
            uint256 tokenId = nameHashToTokenId[nextCheck.nameHash];
            require(tokenId != 0 && ownerOf[tokenId] == nextCheck.user, "No longer owner");
            NameRecord storage record = nameRecords[nextCheck.nameHash];
            record.allowanceEnd = _now() + ALLOWANCE_PERIOD;
            record.graceEnd = _now() + ALLOWANCE_PERIOD + GRACE_PERIOD;
            _clearPendingSettlements(nextCheck.nameHash); // Clear pending settlements
            emit NameCheckedIn(nextCheck.nameHash, nextCheck.user);
            emit CheckInProcessed(nextCheck.nameHash, nextCheck.user);
            nextProcessIndex++;
        }

    function advance() external {
        _processNextCheckin();
    }

    function queueCheckIn(uint256 _nameHash) external {
        uint256 tokenId = nameHashToTokenId[_nameHash];
        require(tokenId != 0 && ownerOf[tokenId] == msg.sender, "Not owner");
        NameRecord storage record = nameRecords[_nameHash];
        require(_now() > record.allowanceEnd, "Not expired");
        (uint256 queueLen, uint256 minRequired) = _processQueueRequirements();
        uint256 waitDuration = _calculateWaitDuration(queueLen);
        pendingCheckins.push(PendingCheckin(_nameHash, msg.sender, _now(), waitDuration));
        emit QueueCheckInQueued(_nameHash, msg.sender, minRequired, waitDuration);
        this.advance();
    }

    function transferName(uint256 _nameHash, address _newOwner) external {
        uint256 tokenId = nameHashToTokenId[_nameHash];
        require(tokenId != 0, "Name not minted");
        _transfer(tokenId, _newOwner);
    }

    function transferFrom(address _from, address _to, uint256 _tokenId) external {
        require(_from == ownerOf[_tokenId], "Wrong from");
        uint256 nameHash = tokenIdToNameHash[_tokenId];
        require(nameHash != 0, "Invalid tokenId");
        _transfer(_tokenId, _to);
    }

    function safeTransferFrom(address _from, address _to, uint256 _tokenId, bytes memory _data) external {
        require(_from == ownerOf[_tokenId], "Wrong from");
        uint256 nameHash = tokenIdToNameHash[_tokenId];
        require(nameHash != 0, "Invalid tokenId");
        _transfer(_tokenId, _to);
        _checkOnERC721Received(_to, _from, _tokenId, _data);
    }

    function setCustomRecord(uint256 _nameHash, uint256 _index, CustomRecord memory _record) external {
        _validateRecord(_record);
        uint256 tokenId = nameHashToTokenId[_nameHash];
        require(ownerOf[tokenId] == msg.sender, "Not owner");
        require(_index < 5, "Invalid index");
        nameRecords[_nameHash].customRecords[_index] = _record;
        emit RecordsUpdated(_nameHash, msg.sender);
    }

    function setSubnameRecord(uint256 _parentHash, uint256 _subnameIndex, uint256 _recordIndex, CustomRecord memory _record) external {
        _validateRecord(_record);
        uint256 tokenId = nameHashToTokenId[_parentHash];
        require(ownerOf[tokenId] == msg.sender, "Not parent owner");
        require(_subnameIndex < subnameRecords[_parentHash].length, "Invalid subname index");
        require(_recordIndex < 5, "Invalid record index");
        subnameRecords[_parentHash][_subnameIndex].customRecords[_recordIndex] = _record;
        emit RecordsUpdated(_parentHash, msg.sender);
    }

        // Changelog: 0.0.15 (06/10/2025) - Returns name string for a given token ID
        function getNameByTokenId(uint256 _tokenId) external view returns (string memory name) {
            uint256 nameHash = tokenIdToNameHash[_tokenId];
            require(nameHash != 0, "Token ID not minted");
            name = nameRecords[nameHash].name;
        }
    
    function getName(string memory _name) external view returns (address _owner) {
        uint256 nameHash = _stringToHash(_name);
        uint256 tokenId = nameHashToTokenId[nameHash];
        require(tokenId != 0, "Name not registered!");
        return ownerOf[tokenId];
    }

        // Changelog: 0.0.20 (06/10/2025) - Returns single NameRecord for name string
        function getNameRecords(string memory _name) external view returns (NameRecord memory record) {
            uint256 nameHash = _stringToHash(_name);
            require(nameRecords[nameHash].nameHash != 0, "Name not found");
            record = nameRecords[nameHash];
        }
    
                // Changelog: 0.0.20 (06/10/2025) - Returns PendingSettlement for given index
        function getSettlementById(uint256 _index) external view returns (PendingSettlement memory settlement) {
            require(_index < pendingSettlements.length, "Invalid index");
            settlement = pendingSettlements[_index];
        }
        
                // Changelog: 0.0.19 (06/10/2025) - Uses name string, returns paginated settlements
        function getPendingSettlements(string memory _name, uint256 _step, uint256 _maxIterations) external view returns (PendingSettlement[] memory settlements) {
            uint256 nameHash = _stringToHash(_name);
            uint256 count = 0;
            for (uint256 i = _step; i < pendingSettlements.length && count < _maxIterations; i++) {
                if (pendingSettlements[i].nameHash == nameHash) {
                    count++;
                }
            }
            settlements = new PendingSettlement[](count);
            uint256 index = 0;
            for (uint256 i = _step; i < pendingSettlements.length && index < count; i++) {
                if (pendingSettlements[i].nameHash == nameHash) {
                    settlements[index] = pendingSettlements[i];
                    index++;
                }
            }
        }

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

    function getSubRecords(string memory _parentName, string memory _subname) external view returns (CustomRecord[5] memory customRecords) {
        uint256 parentHash = _stringToHash(_parentName);
        (uint256 subnameIndex, bool found) = this.getSubnameID(_parentName, _subname);
        require(found, "Subname not found");
        return subnameRecords[parentHash][subnameIndex].customRecords;
    }

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

    function balanceOf(address _owner) external view returns (uint256) {
        require(_owner != address(0), "Zero address");
        return _balances[_owner];
    }
}