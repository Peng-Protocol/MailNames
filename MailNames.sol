// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// File Version: 0.0.2 (03/10/2025)
// Changelog:
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

contract MailNames {
    // Structs for name, subname, and custom records
    struct NameRecord {
        string name; // Domain name (no spaces)
        uint256 nameHash; // keccak256 hash of name
        address retainer; // Current holder
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
    uint256 public constant ALLOWANCE_PERIOD = 365 days;
    uint256 public constant GRACE_PERIOD = 30 days;
    mapping(address => uint256[]) private retainerNames; // retainer => nameHashes
    mapping(address => mapping(uint256 => uint256[])) private bidderBids; // bidder => nameHash => bidIndices
    // Events
    event NameMinted(uint256 indexed nameHash, string name, address retainer);
    event NameCheckedIn(uint256 indexed nameHash, address retainer);
    event BidPlaced(uint256 indexed nameHash, address bidder, uint256 amount, bool isETH);
    event BidSettled(uint256 indexed nameHash, address newRetainer, uint256 amount, bool isETH);
    event BidClosed(uint256 indexed nameHash, address bidder, uint256 amount, bool isETH);
    event SubnameMinted(uint256 indexed parentHash, uint256 subnameHash, string subname, address retainer);
    event NameTransferred(uint256 indexed nameHash, address newRetainer);
    event RecordsUpdated(uint256 indexed nameHash, address retainer);

    // Helper: Convert string to hash
    function _stringToHash(string memory _str) private pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(_str)));
    }

    // Helper: Validate name (no spaces)
    function _validateName(string memory _name) private pure returns (bool) {
        bytes memory nameBytes = bytes(_name);
        for (uint256 i = 0; i < nameBytes.length; i++) {
            if (nameBytes[i] == " ") return false;
        }
        return true;
    }
    
    // Helper: Find highest ETH bid or oldest ERC20 bid
function _findBestBid(uint256 _nameHash) private view returns (uint256 bestIndex, bool found) {
    Bid[] memory nameBids = bids[_nameHash];
    uint256 highestETHAmount = 0;
    uint256 oldestERC20Time = type(uint256).max;
    for (uint256 i = 0; i < nameBids.length; i++) {
        if (nameBids[i].isETH && nameBids[i].amount > highestETHAmount) {
            highestETHAmount = nameBids[i].amount;
            bestIndex = i;
            found = true;
        } else if (!nameBids[i].isETH && nameBids[i].timestamp < oldestERC20Time) {
            oldestERC20Time = nameBids[i].timestamp;
            bestIndex = i;
            found = true;
        }
    }
}

// Helper: Settle bid internally
function _settleBid(uint256 _nameHash, uint256 _bidIndex) private {
    NameRecord storage record = nameRecords[_nameHash];
    Bid[] storage nameBids = bids[_nameHash];
    Bid memory bid = nameBids[_bidIndex];
    address oldRetainer = record.retainer;
    record.retainer = bid.bidder;
    record.allowanceEnd = block.timestamp + ALLOWANCE_PERIOD;
    // Transfer funds to old retainer
    if (bid.isETH) {
        payable(oldRetainer).transfer(bid.amount);
    } else {
        IERC20(bid.token).transfer(oldRetainer, bid.amount * 10 ** IERC20(bid.token).decimals());
    }
    emit BidSettled(_nameHash, bid.bidder, bid.amount, bid.isETH);
}

// Changelog: 0.0.2 (03/10/2025) - Add nameHash to retainerNames mapping
function mintName(string memory _name) external {
    require(_validateName(_name), "Name contains spaces");
    uint256 nameHash = _stringToHash(_name);
    require(nameRecords[nameHash].retainer == address(0), "Name already minted");
    NameRecord storage record = nameRecords[nameHash];
    record.name = _name;
    record.nameHash = nameHash;
    record.retainer = msg.sender;
    record.allowanceEnd = block.timestamp + ALLOWANCE_PERIOD;
    for (uint256 i = 0; i < 5; i++) {
        record.customRecords[i] = CustomRecord("", "", "", 0, address(0));
    }
    retainerNames[msg.sender].push(nameHash);
    emit NameMinted(nameHash, _name, msg.sender);
}

// Mint subname under a name
function mintSubname(string memory _parentName, string memory _subname) external {
    require(_validateName(_subname), "Subname contains spaces");
    uint256 parentHash = _stringToHash(_parentName);
    NameRecord storage parent = nameRecords[parentHash];
    require(parent.retainer == msg.sender, "Not parent retainer");
    uint256 subnameHash = _stringToHash(_subname);
    SubnameRecord storage subname = subnameRecords[parentHash].push();
    subname.parentHash = parentHash;
    subname.subname = _subname;
    subname.subnameHash = subnameHash;
    for (uint256 i = 0; i < 5; i++) {
        subname.customRecords[i] = CustomRecord("", "", "", 0, address(0));
    }
    emit SubnameMinted(parentHash, subnameHash, _subname, msg.sender);
}

    // Check-in to extend allowance
    function checkIn(uint256 _nameHash) external {
        NameRecord storage record = nameRecords[_nameHash];
        require(record.retainer == msg.sender, "Not retainer");
        require(block.timestamp <= record.allowanceEnd + GRACE_PERIOD, "Grace period expired");
        require(block.timestamp > record.allowanceEnd, "Must be within grace period");
        record.allowanceEnd = block.timestamp + ALLOWANCE_PERIOD;
        emit NameCheckedIn(_nameHash, msg.sender);
    }

// Changelog: 0.0.2 (03/10/2025) - Calculate received amount to handle transfer fees ++ placeETHBid changes
function placeTokenBid(string memory _name, uint256 _amount, address _token) external {
    uint256 nameHash = _stringToHash(_name);
    NameRecord storage record = nameRecords[nameHash];
    require(record.retainer != address(0), "Name not minted");
    require(_amount > 0, "Invalid bid amount");
    IERC20 token = IERC20(_token);
    uint256 balanceBefore = token.balanceOf(address(this));
    require(token.transferFrom(msg.sender, address(this), _amount * 10 ** token.decimals()), "Transfer failed");
    uint256 balanceAfter = token.balanceOf(address(this));
    uint256 receivedAmount = (balanceAfter - balanceBefore) / 10 ** token.decimals();
    require(receivedAmount > 0, "No tokens received");
    uint256 bidIndex = bids[nameHash].length;
    bids[nameHash].push(Bid(msg.sender, receivedAmount, block.timestamp, false, _token));
    bidderBids[msg.sender][nameHash].push(bidIndex);
    emit BidPlaced(nameHash, msg.sender, receivedAmount, false);
    if (block.timestamp > record.allowanceEnd + GRACE_PERIOD) {
        (uint256 bestIndex, bool found) = _findBestBid(nameHash);
        if (found) _settleBid(nameHash, bestIndex);
    }
}

// Changelog: 0.0.2 (03/10/2025) - Add bidIndex to bidderBids mapping
function placeETHBid(string memory _name) external payable {
    uint256 nameHash = _stringToHash(_name);
    NameRecord storage record = nameRecords[nameHash];
    require(record.retainer != address(0), "Name not minted");
    require(msg.value > 0, "Invalid bid amount");
    uint256 balanceBefore = address(this).balance - msg.value;
    uint256 bidIndex = bids[nameHash].length;
    bids[nameHash].push(Bid(msg.sender, msg.value, block.timestamp, true, address(0)));
    bidderBids[msg.sender][nameHash].push(bidIndex);
    uint256 balanceAfter = address(this).balance;
    require(balanceAfter >= balanceBefore + msg.value, "Balance check failed");
    emit BidPlaced(nameHash, msg.sender, msg.value, true);
    if (block.timestamp > record.allowanceEnd + GRACE_PERIOD) {
        (uint256 bestIndex, bool found) = _findBestBid(nameHash);
        if (found) _settleBid(nameHash, bestIndex);
    }
}

// Changelog: 0.0.2 (03/10/2025) - Use swap-and-pop to avoid costly array shifts
function closeBid(uint256 _nameHash, uint256 _bidIndex) external {
    Bid[] storage nameBids = bids[_nameHash];
    require(_bidIndex < nameBids.length, "Invalid bid index");
    Bid memory bid = nameBids[_bidIndex];
    require(bid.bidder == msg.sender, "Not bidder");
    if (bid.isETH) {
        payable(msg.sender).transfer(bid.amount);
    } else {
        IERC20(bid.token).transfer(msg.sender, bid.amount * 10 ** IERC20(bid.token).decimals());
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
    emit BidClosed(_nameHash, msg.sender, bid.amount, bid.isETH);
}

    // Accept bid during valid allowance
    function acceptBid(uint256 _nameHash, uint256 _bidIndex) external {
        NameRecord storage record = nameRecords[_nameHash];
        require(record.retainer == msg.sender, "Not retainer");
        require(block.timestamp <= record.allowanceEnd, "Allowance expired");
        _settleBid(_nameHash, _bidIndex);
    }

// Changelog: 0.0.2 (03/10/2025) - Update retainerNames mapping
function transferName(uint256 _nameHash, address _newRetainer) external {
    NameRecord storage record = nameRecords[_nameHash];
    require(record.retainer == msg.sender, "Not retainer");
    require(_newRetainer != address(0), "Invalid address");
    // Remove from old retainer's mapping
    uint256[] storage oldNames = retainerNames[msg.sender];
    for (uint256 i = 0; i < oldNames.length; i++) {
        if (oldNames[i] == _nameHash) {
            oldNames[i] = oldNames[oldNames.length - 1];
            oldNames.pop();
            break;
        }
    }
    // Add to new retainer's mapping
    retainerNames[_newRetainer].push(_nameHash);
    record.retainer = _newRetainer;
    record.allowanceEnd = block.timestamp + ALLOWANCE_PERIOD;
    emit NameTransferred(_nameHash, _newRetainer);
}

    // Set a single custom record for a name at specified index
    function setCustomRecord(uint256 _nameHash, uint256 _index, CustomRecord memory _record) external {
        NameRecord storage record = nameRecords[_nameHash];
        require(record.retainer == msg.sender, "Not retainer");
        require(_index < 5, "Invalid index");
        record.customRecords[_index] = _record;
        emit RecordsUpdated(_nameHash, msg.sender);
    }
    
// Set a single custom record for a subname at specified index
function setSubnameRecord(uint256 _parentHash, uint256 _subnameIndex, uint256 _recordIndex, CustomRecord memory _record) external {
    NameRecord storage parent = nameRecords[_parentHash];
    require(parent.retainer == msg.sender, "Not parent retainer");
    require(_subnameIndex < subnameRecords[_parentHash].length, "Invalid subname index");
    require(_recordIndex < 5, "Invalid record index");
    subnameRecords[_parentHash][_subnameIndex].customRecords[_recordIndex] = _record;
    emit RecordsUpdated(_parentHash, msg.sender);
}

    // View functions
    function getNameRecords(uint256 step, uint256 maxIterations) external view returns (NameRecord[] memory records) {
        uint256 count = 0;
        for (uint256 i = step; i < step + maxIterations; i++) {
            if (nameRecords[i].retainer != address(0)) count++;
        }
        records = new NameRecord[](count);
        uint256 index = 0;
        for (uint256 i = step; i < step + maxIterations && index < count; i++) {
            if (nameRecords[i].retainer != address(0)) {
                records[index] = nameRecords[i];
                index++;
            }
        }
    }
    
// Get subname index by parent name and subname string
function getSubnameID(string memory _parentName, string memory _subname) external view returns (uint256 subnameIndex, bool found) {
    uint256 parentHash = _stringToHash(_parentName);
    uint256 subnameHash = _stringToHash(_subname);
    for (uint256 i = 0; i < subnameRecords[parentHash].length; i++) {
        if (subnameRecords[parentHash][i].subnameHash == subnameHash) {
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
    uint256 length = subnameRecords[parentHash].length;
    uint256 end = step + maxIterations > length ? length : step + maxIterations;
    uint256 count = end > step ? end - step : 0;
    subnames = new string[](count);
    for (uint256 i = step; i < end; i++) {
        subnames[i - step] = subnameRecords[parentHash][i].subname;
    }
}
    
    function getNameBids(string memory _name, uint256 maxIterations) external view returns (Bid[] memory nameBids) {
        uint256 nameHash = _stringToHash(_name);
        uint256 length = bids[nameHash].length > maxIterations ? maxIterations : bids[nameHash].length;
        nameBids = new Bid[](length);
        for (uint256 i = 0; i < length; i++) {
            nameBids[i] = bids[nameHash][i];
        }
    }

    // Changelog: 0.0.2 (03/10/2025) - Use mapping for efficient retrieval
function getRetainerNames(address _retainer, uint256 maxIterations) external view returns (uint256[] memory nameHashes, NameRecord[] memory records) {
    uint256[] memory hashes = retainerNames[_retainer];
    uint256 length = hashes.length > maxIterations ? maxIterations : hashes.length;
    nameHashes = new uint256[](length);
    records = new NameRecord[](length);
    for (uint256 i = 0; i < length; i++) {
        nameHashes[i] = hashes[i];
        records[i] = nameRecords[hashes[i]];
    }
}

// Changelog: 0.0.2 (03/10/2025) - Added for granular bid retrieval
function getBidderNameBids(address _bidder, string memory _name) external view returns (Bid[] memory nameBids) {
    uint256 nameHash = _stringToHash(_name);
    uint256[] memory indices = bidderBids[_bidder][nameHash];
    nameBids = new Bid[](indices.length);
    for (uint256 i = 0; i < indices.length; i++) {
        nameBids[i] = bids[nameHash][indices[i]];
    }
}


    // Changelog: 0.0.2 (03/10/2025) - Use mapping for efficient retrieval
function getBidderBids(address _bidder, uint256 maxIterations) external view returns (uint256[] memory nameHashes, Bid[][] memory bidderBidsArray) {
    uint256 count = 0;
    for (uint256 i = 0; i < maxIterations; i++) {
        if (bidderBids[_bidder][i].length > 0) count++;
    }
    nameHashes = new uint256[](count);
    bidderBidsArray = new Bid[][](count);
    uint256 index = 0;
    for (uint256 i = 0; i < maxIterations && index < count; i++) {
        uint256[] memory indices = bidderBids[_bidder][i];
        if (indices.length > 0) {
            nameHashes[index] = i;
            bidderBidsArray[index] = new Bid[](indices.length);
            for (uint256 j = 0; j < indices.length; j++) {
                bidderBidsArray[index][j] = bids[i][indices[j]];
            }
            index++;
        }
    }
}
}