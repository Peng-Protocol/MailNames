// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// File Version: 0.0.10 (18/11/2025)
// Changelog:
// - 18/11/2025: Aligned with new lock-up amount on MailNames. 
// - 17/11/2025: Added getBidDetails and cancelBid (MailNames only). 
// - 13/11/2035: Removed "tokenId != 0" in various functions , replaced with other suitable checks. 
// - 07/11/2025: Added time-warp system (currentTime, isWarped, warp(), unWarp(), _now()) to IMailNames, MailLocker, MailMarket for VM testing consistency with TrustlessFund
// - 0.0.6 (07/10): Updated checkTopBidder to close invalid top bid, refund, and clear data
// - 0.0.5 (07/10): Added getBidderBids to view bidder’s bid indices per token
// - 0.0.4 (07/10): Added bidderActiveBids; scaled minReq by user bids; optimized _insertAndSort
// - 0.0.3 (07/10): Updated _validateBidRequirements to scale minReq by active bid count
// - 0.0.2 (05/10): Updated acceptBid to call IMailNames.acceptMarketBid; added OwnershipTransferred event
// - 0.0.1 (05/10): Initial implementation with bidding from IMailNames

interface IIERC20 {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IMailNames {
    function ownerOf(uint256 tokenId) external view returns (address);
    function nameHashToTokenId(uint256 nameHash) external view returns (uint256);
    function transfer(uint256 tokenId, address to) external;
    function acceptMarketBid(uint256 _nameHash, bool _isETH, address _token, uint256 _bidIndex) external;
    function checkInCost() external view returns (uint256);
}

contract MailMarket {
    struct Bid {
        address bidder;
        uint256 amount;
        uint256 timestamp;
    }

    struct BidValidation {
        uint256 nameHash;
        uint256 tokenId;
        uint256 queueLen;
        uint256 minReq;
        uint256 normMin;
    }

    struct TokenTransferData {
        uint256 balanceBefore;
        uint256 balanceAfter;
        uint256 receivedAmount;
        uint256 transferAmount;
    }

    address public owner;
    address public mailToken;
    address public mailNames;
    mapping(uint256 => Bid[100]) public ethBids;
    mapping(uint256 => mapping(address => Bid[100])) public tokenBids;
    address[] public allowedTokens;
    mapping(address => uint256) public tokenCounts;
    uint256 public constant MAX_BIDS = 100;
    
    mapping(address => uint256) public bidderActiveBids;
    
    uint256 public currentTime;
    bool public isWarped;

    event BidPlaced(uint256 indexed nameHash, address bidder, uint256 amount, bool isETH);
    event BidSettled(uint256 indexed nameHash, address newOwner, uint256 amount, bool isETH);
    event BidClosed(uint256 indexed nameHash, address bidder, uint256 amount, bool isETH);
    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);
    event TopBidInvalidated(uint256 indexed nameHash);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

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

    function setMailNames(address _mailNames) external onlyOwner {
        mailNames = _mailNames;
    }

    function addAllowedToken(address _token) external onlyOwner {
        require(tokenCounts[_token] == 0, "Already allowed");
        allowedTokens.push(_token);
        tokenCounts[_token]++;
        emit TokenAdded(_token);
    }

    function removeAllowedToken(address _token) external onlyOwner {
        require(tokenCounts[_token] > 0, "Not allowed");
        for (uint256 i = 0; i < allowedTokens.length; i++) {
            if (allowedTokens[i] == _token) {
                allowedTokens[i] = allowedTokens[allowedTokens.length - 1];
                allowedTokens.pop();
                break;
            }
        }
        tokenCounts[_token]--;
        emit TokenRemoved(_token);
    }

    function _stringToHash(string memory _str) private pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(_str)));
    }

    function _insertAndSort(Bid[100] storage bidsArray, Bid memory newBid) private {
    uint256 insertPos = MAX_BIDS;
    for (uint256 i = 0; i < MAX_BIDS; i++) {
        if (bidsArray[i].bidder == address(0)) {
            insertPos = i;
            break;
        }
    }
    if (insertPos == MAX_BIDS) {
        insertPos = MAX_BIDS - 1;
        for (uint256 i = MAX_BIDS - 1; i > 0; i--) {
            bidsArray[i] = bidsArray[i - 1];
        }
    } else {
        for (uint256 i = insertPos; i > 0; i--) {
            if (bidsArray[i - 1].amount < newBid.amount ||
                (bidsArray[i - 1].amount == newBid.amount && bidsArray[i - 1].timestamp > newBid.timestamp)) {
                bidsArray[i] = bidsArray[i - 1];
            } else {
                insertPos = i;
                break;
            }
        }
    }
    bidsArray[insertPos] = newBid;
}

    function _removeBidFromArray(Bid[100] storage bidsArray, uint256 _bidIndex) private {
        for (uint256 i = _bidIndex; i < MAX_BIDS - 1; i++) {
            bidsArray[i] = bidsArray[i + 1];
        }
        bidsArray[MAX_BIDS - 1] = Bid(address(0), 0, 0);
    }

    function _transferBidFunds(address _oldOwner, uint256 _amount, bool _isETH, address _token) private {
        if (_isETH) {
            payable(_oldOwner).transfer(_amount);
        } else {
            IIERC20(_token).transfer(_oldOwner, _amount * (10 ** IIERC20(_token).decimals()));
        }
    }
    
function cancelBid(uint256 _nameHash, uint256 _bidIndex, bool _isETH, address _token) external {
    require(msg.sender == mailNames, "Only MailNames");
    Bid memory bid = _isETH ? ethBids[_nameHash][_bidIndex] : tokenBids[_nameHash][_token][_bidIndex];
    
    // Calculate penalty: 1% burn, 99% refund
    uint256 refundAmount = (bid.amount * 99) / 100;
    uint256 burnAmount = bid.amount - refundAmount;
    
    if (_isETH) {
        payable(bid.bidder).transfer(refundAmount);
        // Burn by sending to dead address
        payable(address(0xdead)).transfer(burnAmount);
    } else {
        IIERC20(_token).transfer(bid.bidder, refundAmount * (10 ** IIERC20(_token).decimals()));
        IIERC20(_token).transfer(address(0xdead), burnAmount * (10 ** IIERC20(_token).decimals()));
    }
    
    bidderActiveBids[bid.bidder]--;
    
    Bid[100] storage bidsArray = _isETH ? ethBids[_nameHash] : tokenBids[_nameHash][_token];
    _removeBidFromArray(bidsArray, _bidIndex);
    
    emit BidClosed(_nameHash, bid.bidder, bid.amount, _isETH);
}

function _validateBidRequirements(string memory _name, uint256 _bidAmount) private view returns (BidValidation memory validation) {
    validation.nameHash = _stringToHash(_name);
    validation.tokenId = IMailNames(mailNames).nameHashToTokenId(validation.nameHash);
    
    require(IMailNames(mailNames).ownerOf(validation.tokenId) != address(0), "Name not minted");
    require(_bidAmount > 0, "Invalid bid amount");
    
    validation.queueLen = 0;
validation.minReq = (IMailNames(mailNames).checkInCost() / (10 ** IIERC20(mailToken).decimals())) * (bidderActiveBids[msg.sender] + 1);
    uint8 dec = IIERC20(mailToken).decimals();
    
    // Fix: Check balance against full amount with decimals, not normalized
    uint256 fullMinReq = validation.minReq * (10 ** dec);
    require(IIERC20(mailToken).balanceOf(msg.sender) >= fullMinReq, "Insufficient MAIL");
    require(_bidAmount >= validation.minReq, "Bid below min lock");
    
    validation.normMin = validation.minReq; // Store normalized for later use
}

    function _handleTokenTransfer(address _token, uint256 _amount) private returns (uint256 receivedAmount) {
        IIERC20 token = IIERC20(_token);
        uint8 tdec = token.decimals();
        TokenTransferData memory data;
        data.transferAmount = _amount * (10 ** tdec);
        data.balanceBefore = token.balanceOf(address(this));
        require(token.transferFrom(msg.sender, address(this), data.transferAmount), "Transfer failed");
        data.balanceAfter = token.balanceOf(address(this));
        data.receivedAmount = (data.balanceAfter - data.balanceBefore) / (10 ** tdec);
        require(data.receivedAmount > 0, "No tokens received");
        return data.receivedAmount;
    }

    function settleBid(uint256 _nameHash, uint256 _bidIndex, bool _isETH, address _token) external {
    require(msg.sender == mailNames, "Only IMailNames");
    Bid memory bid = _isETH ? ethBids[_nameHash][_bidIndex] : tokenBids[_nameHash][_token][_bidIndex];
    address oldOwner = IMailNames(mailNames).ownerOf(IMailNames(mailNames).nameHashToTokenId(_nameHash));
    _transferBidFunds(oldOwner, bid.amount, _isETH, _token);
    IMailNames(mailNames).transfer(IMailNames(mailNames).nameHashToTokenId(_nameHash), bid.bidder);
    bidderActiveBids[bid.bidder]--; // Decrement bidder's active bids
    emit BidSettled(_nameHash, bid.bidder, bid.amount, _isETH);
    Bid[100] storage bidsArray = _isETH ? ethBids[_nameHash] : tokenBids[_nameHash][_token];
    _removeBidFromArray(bidsArray, _bidIndex);
}

    function placeETHBid(string memory _name) external payable {
    BidValidation memory validation = _validateBidRequirements(_name, msg.value);
    Bid memory newBid = Bid(msg.sender, msg.value, _now());
    Bid[100] storage eb = ethBids[validation.nameHash];
    _insertAndSort(eb, newBid);
    bidderActiveBids[msg.sender]++; // Increment bidder's active bids
    emit BidPlaced(validation.nameHash, msg.sender, msg.value, true);
}

    function placeTokenBid(string memory _name, uint256 _amount, address _token) external {
    require(tokenCounts[_token] > 0, "Token not allowed");
    BidValidation memory validation = _validateBidRequirements(_name, _amount);
    uint256 receivedAmount = _handleTokenTransfer(_token, _amount);
    Bid memory newBid = Bid(msg.sender, receivedAmount, _now());
    Bid[100] storage tb = tokenBids[validation.nameHash][_token];
    _insertAndSort(tb, newBid);
    bidderActiveBids[msg.sender]++; // Increment bidder's active bids
    emit BidPlaced(validation.nameHash, msg.sender, receivedAmount, false);
}

    function closeBid(uint256 _nameHash, bool _isETH, address _token, uint256 _bidIndex) external {
    Bid memory bid;
    Bid[100] storage bidsArray;
    if (_isETH) {
        require(_bidIndex < MAX_BIDS && ethBids[_nameHash][_bidIndex].bidder == msg.sender, "Not bidder");
        bid = ethBids[_nameHash][_bidIndex];
        bidsArray = ethBids[_nameHash];
    } else {
        require(_token != address(0) && tokenCounts[_token] > 0, "Invalid token");
        require(_bidIndex < MAX_BIDS && tokenBids[_nameHash][_token][_bidIndex].bidder == msg.sender, "Not bidder");
        bid = tokenBids[_nameHash][_token][_bidIndex];
        bidsArray = tokenBids[_nameHash][_token];
    }
    if (_isETH) {
        payable(msg.sender).transfer(bid.amount);
    } else {
        IIERC20(_token).transfer(msg.sender, bid.amount * (10 ** IIERC20(_token).decimals()));
    }
    _removeBidFromArray(bidsArray, _bidIndex);
    bidderActiveBids[msg.sender]--; // Decrement bidder's active bids
    emit BidClosed(_nameHash, msg.sender, bid.amount, _isETH);
}

    // Changelog: 0.0.2 (05/10/2025) - Updated to call IMailNames.acceptMarketBid
    function acceptBid(uint256 _nameHash, bool _isETH, address _token, uint256 _bidIndex) external {
        IMailNames(mailNames).acceptMarketBid(_nameHash, _isETH, _token, _bidIndex);
    }

    function checkTopBidder(uint256 _nameHash) external returns (address bidder, uint256 amount, bool valid) {
    Bid[100] storage bids = ethBids[_nameHash];
    if (bids[0].bidder == address(0)) return (address(0), 0, false);
    bidder = bids[0].bidder;
    amount = bids[0].amount;
    uint256 minReq = IMailNames(mailNames).checkInCost();
valid = IIERC20(mailToken).balanceOf(bidder) >= minReq;
    if (!valid) {
        payable(bidder).transfer(amount); // Refund invalid top bid
        bidderActiveBids[bidder]--; // Decrement bidder’s active bids
        _removeBidFromArray(bids, 0); // Clear invalid top bid
        emit BidClosed(_nameHash, bidder, amount, true); // Emit closure
        bidder = address(0);
        amount = 0;
    }
    emit TopBidInvalidated(_nameHash);
}
    
    // (v0.0.5) new view function to retrieve bidder's bid indices for a name and token (bool for ETH)
function getBidderBids(string memory _name, address _bidder, bool _isETH, address _token, uint256 _step, uint256 _maxIterations) external view returns (uint256[] memory bidIndices) {
    uint256 nameHash = _stringToHash(_name);
    Bid[100] memory bids = _isETH ? ethBids[nameHash] : tokenBids[nameHash][_token];
    require(_isETH || tokenCounts[_token] > 0, "Invalid token");
    uint256 count = 0;
    for (uint256 i = _step; i < MAX_BIDS && count < _maxIterations; i++) {
        if (bids[i].bidder == _bidder) count++;
    }
    bidIndices = new uint256[](count);
    uint256 index = 0;
    for (uint256 i = _step; i < MAX_BIDS && index < count; i++) {
        if (bids[i].bidder == _bidder) {
            bidIndices[index] = i;
            index++;
        }
    }
}

function getBidDetails(uint256 _nameHash, uint256 _bidIndex, bool _isETH, address _token) external view returns (address bidder, uint256 amount) {
    Bid memory bid = _isETH ? ethBids[_nameHash][_bidIndex] : tokenBids[_nameHash][_token][_bidIndex];
    return (bid.bidder, bid.amount);
}

    function getNameBids(string memory _name, bool _isETH, address _token) external view returns (Bid[100] memory nameBids) {
        uint256 nameHash = _stringToHash(_name);
        if (_isETH) {
            for (uint256 i = 0; i < MAX_BIDS; i++) {
                nameBids[i] = ethBids[nameHash][i];
            }
        } else {
            require(tokenCounts[_token] > 0, "Token not allowed");
            for (uint256 i = 0; i < MAX_BIDS; i++) {
                nameBids[i] = tokenBids[nameHash][_token][i];
            }
        }
    }
}