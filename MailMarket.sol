// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// File Version: 0.0.2 (05/10/2025)
// Changelog:
// - 0.0.2 (05/10): Updated acceptBid to call MailNames.acceptMarketBid; added OwnershipTransferred event
// - 0.0.1 (05/10): Initial implementation with bidding from MailNames

interface IERC20 {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface MailNames {
    function ownerOf(uint256 tokenId) external view returns (address);
    function nameHashToTokenId(uint256 nameHash) external view returns (uint256);
    function transfer(uint256 tokenId, address to) external;
    function acceptMarketBid(uint256 _nameHash, bool _isETH, address _token, uint256 _bidIndex) external;
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

    function _calculateMinRequired(uint256 _queueLen) private pure returns (uint256) {
        return 1 * (2 ** _queueLen);
    }

    function _insertAndSort(Bid[100] storage bidsArray, Bid memory newBid) private {
        uint256 insertPos = MAX_BIDS;
        for (uint256 i = 0; i < MAX_BIDS; i++) {
            if (bidsArray[i].bidder == address(0)) {
                insertPos = i;
                break;
            }
        }
        if (insertPos == MAX_BIDS) insertPos = MAX_BIDS - 1;
        bidsArray[insertPos] = newBid;
        for (uint256 i = 0; i < MAX_BIDS - 1; i++) {
            for (uint256 j = 0; j < MAX_BIDS - i - 1; j++) {
                if (bidsArray[j].amount < bidsArray[j + 1].amount ||
                    (bidsArray[j].amount == bidsArray[j + 1].amount && bidsArray[j].timestamp > bidsArray[j + 1].timestamp)) {
                    Bid memory temp = bidsArray[j];
                    bidsArray[j] = bidsArray[j + 1];
                    bidsArray[j + 1] = temp;
                }
            }
        }
        if (bidsArray[MAX_BIDS - 1].bidder != address(0)) {
            bidsArray[MAX_BIDS - 1] = Bid(address(0), 0, 0);
        }
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
            IERC20(_token).transfer(_oldOwner, _amount * (10 ** IERC20(_token).decimals()));
        }
    }

    function _validateBidRequirements(string memory _name, uint256 _bidAmount) private view returns (BidValidation memory validation) {
        validation.nameHash = _stringToHash(_name);
        validation.tokenId = MailNames(mailNames).nameHashToTokenId(validation.nameHash);
        require(validation.tokenId != 0, "Name not minted");
        require(_bidAmount > 0, "Invalid bid amount");
        validation.queueLen = 0;
        validation.minReq = _calculateMinRequired(validation.queueLen);
        uint8 dec = IERC20(mailToken).decimals();
        validation.normMin = validation.minReq / (10 ** dec);
        require(IERC20(mailToken).balanceOf(msg.sender) >= validation.normMin, "Insufficient MAIL");
        require(_bidAmount >= validation.minReq, "Bid below min lock");
    }

    function _handleTokenTransfer(address _token, uint256 _amount) private returns (uint256 receivedAmount) {
        IERC20 token = IERC20(_token);
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
        require(msg.sender == mailNames, "Only MailNames");
        Bid memory bid = _isETH ? ethBids[_nameHash][_bidIndex] : tokenBids[_nameHash][_token][_bidIndex];
        address oldOwner = MailNames(mailNames).ownerOf(MailNames(mailNames).nameHashToTokenId(_nameHash));
        _transferBidFunds(oldOwner, bid.amount, _isETH, _token);
        MailNames(mailNames).transfer(MailNames(mailNames).nameHashToTokenId(_nameHash), bid.bidder);
        emit BidSettled(_nameHash, bid.bidder, bid.amount, _isETH);
        Bid[100] storage bidsArray = _isETH ? ethBids[_nameHash] : tokenBids[_nameHash][_token];
        _removeBidFromArray(bidsArray, _bidIndex);
    }

    function placeETHBid(string memory _name) external payable {
        BidValidation memory validation = _validateBidRequirements(_name, msg.value);
        Bid memory newBid = Bid(msg.sender, msg.value, block.timestamp);
        Bid[100] storage eb = ethBids[validation.nameHash];
        _insertAndSort(eb, newBid);
        emit BidPlaced(validation.nameHash, msg.sender, msg.value, true);
    }

    function placeTokenBid(string memory _name, uint256 _amount, address _token) external {
        require(tokenCounts[_token] > 0, "Token not allowed");
        BidValidation memory validation = _validateBidRequirements(_name, _amount);
        uint256 receivedAmount = _handleTokenTransfer(_token, _amount);
        Bid memory newBid = Bid(msg.sender, receivedAmount, block.timestamp);
        Bid[100] storage tb = tokenBids[validation.nameHash][_token];
        _insertAndSort(tb, newBid);
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
            IERC20(_token).transfer(msg.sender, bid.amount * (10 ** IERC20(_token).decimals()));
        }
        _removeBidFromArray(bidsArray, _bidIndex);
        emit BidClosed(_nameHash, msg.sender, bid.amount, _isETH);
    }

    // Changelog: 0.0.2 (05/10/2025) - Updated to call MailNames.acceptMarketBid
    function acceptBid(uint256 _nameHash, bool _isETH, address _token, uint256 _bidIndex) external {
        MailNames(mailNames).acceptMarketBid(_nameHash, _isETH, _token, _bidIndex);
    }

    function checkTopBidder(uint256 _nameHash) external returns (address topBidder, uint256 topAmount, bool valid) {
        Bid[100] storage eb = ethBids[_nameHash];
        if (eb[0].bidder == address(0)) return (address(0), 0, false);
        uint256 minReq = _calculateMinRequired(0);
        uint8 dec = IERC20(mailToken).decimals();
        uint256 normMin = minReq / (10 ** dec);
        if (IERC20(mailToken).balanceOf(eb[0].bidder) < normMin) {
            for (uint256 i = 0; i < MAX_BIDS - 1; i++) {
                eb[i] = eb[i + 1];
            }
            eb[MAX_BIDS - 1] = Bid(address(0), 0, 0);
            emit TopBidInvalidated(_nameHash);
            return (address(0), 0, false);
        }
        return (eb[0].bidder, eb[0].amount, true);
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