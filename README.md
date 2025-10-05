# MailNames
**Version**: 0.0.8  
**Date**: 05/10/2025  
**SPDX-License-Identifier**: BSL 1.1 - Peng Protocol 2025  
**Solidity Version**: ^0.8.2  

## Overview
`MailNames` is a decentralized domain name system with ERC721 compatibility, enabling free name minting (tokenId from 0 upward) with a 1-year allowance and 30-day grace period. Owners can queue check-ins post-expiration (locks min token in `MailLocker` for 10y; dynamic wait 10min-2w). Bidding moved to `MailMarket` (ETH/ERC20, auto-settle post-grace). Supports subnames (transferred with parents) with custom records (strings <=1024 chars). Names limited to 24 chars. Primary for Chainmail (link unavailable). Ownership via `ownerOf`; transfers inherit allowance. Safe transfers enforce ERC721Receiver hooks.

## Structs
- **NameRecord**: Stores domain details.
  - `name`: String (no spaces, <=24 chars).
  - `nameHash`: keccak256 hash of name.
  - `tokenId`: ERC721 token ID.
  - `allowanceEnd`: Timestamp when allowance expires.
  - `graceEnd`: Grace period end (reset on post-grace settle).
  - `customRecords`: Array of 5 `CustomRecord` structs.
- **SubnameRecord**: Stores subname details.
  - `parentHash`: Parent name's hash.
  - `subname`: Subname string (<=24 chars).
  - `subnameHash`: keccak256 hash of subname.
  - `customRecords`: Array of 5 `CustomRecord` structs.
- **PendingCheckin**: Stores queued checkin details.
  - `nameHash`: Name to check in.
  - `user`: Owner address.
  - `queuedTime`: Block timestamp at queue.
  - `waitDuration`: Wait (10min + 6h*queueLen, cap 2w).
- **CustomRecord**: Stores metadata (strings <=1024 chars).
  - `text`: General text (e.g., description).
  - `resolver`: Resolver info.
  - `contentHash`: Content hash (e.g., IPFS).
  - `ttl`: Time-to-live.
  - `targetAddress`: Associated address.
- **SettlementData**: Stores settlement data.
  - `nameHash`: Name hash.
  - `tokenId`: ERC721 token ID.
  - `oldOwner`: Previous owner.
  - `newOwner`: New owner.
  - `amount`: Bid amount.
  - `postGrace`: True if post-grace period.

## State Variables
- `nameRecords`: Maps `uint256` (nameHash) to `NameRecord`.
- `subnameRecords`: Maps `uint256` (parentHash) to `SubnameRecord[]`.
- `allNameHashes`: Array of `uint256` (minted nameHashes).
- `totalNames`: uint256 (starts 0, ++ per mint).
- `tokenIdToNameHash`: Maps `uint256` (tokenId) to `uint256` (nameHash).
- `nameHashToTokenId`: Maps `uint256` (nameHash) to `uint256` (tokenId).
- `_balances`: Maps `address` to `uint256` (owner => token count).
- `ownerOf`: Maps `uint256` (tokenId) to `address` (owner).
- `getApproved`: Maps `uint256` (tokenId) to `address` (spender).
- `isApprovedForAll`: Maps `address` to `mapping(address => bool)` (owner => operator => approved).
- `pendingCheckins`: Array of `PendingCheckin`.
- `nextProcessIndex`: uint256 (processed queue position).
- `owner`: address (contract owner).
- `mailToken`: address (ERC20 token).
- `mailLocker`: address (MailLocker contract).
- `mailMarket`: address (MailMarket contract).
- `ALLOWANCE_PERIOD`: 365 days.
- `GRACE_PERIOD`: 30 days.
- `MAX_NAME_LENGTH`: 24.
- `MAX_STRING_LENGTH`: 1024.

## External Functions and Call Trees
### mintName(string _name)
- **Purpose**: Mints ERC721 name (free, 1-year allowance).
- **Checks**: `_validateName` (spaces/length), name not minted.
- **Internal Calls**:
  - `_stringToHash`: Generates nameHash.
  - `_validateName`: Validates format/length.
- **Effects**: Sets `NameRecord`, maps `tokenIdToNameHash`/`nameHashToTokenId`/`ownerOf`/`_balances`, pushes to `allNameHashes`, emits `NameMinted`/`Transfer`.

### queueCheckIn(uint256 _nameHash)
- **Purpose**: Queues checkin post-expiration (locks token in `MailLocker` for 10y).
- **Checks**: Caller=owner, expired, transfer succeeds.
- **Internal Calls**:
  - `_processQueueRequirements`: Locks tokens via `MailLocker.depositLock`.
  - `_calculateMinRequired`: 1 * 2^queueLen wei.
  - `_calculateWaitDuration`: 10min + 6h*queueLen, cap 2w.
  - `this.advance`: Processes if ready.
- **Effects**: Pushes `PendingCheckin`, emits `QueueCheckInQueued`.

### advance()
- **Purpose**: Processes one ready checkin.
- **Checks**: Time/user eligibility.
- **Internal Calls**:
  - `_processNextCheckin`: Updates `allowanceEnd`, emits `NameCheckedIn`/`CheckInProcessed`.
- **Effects**: Increments `nextProcessIndex`.

### transferName(uint256 _nameHash, address _newOwner)
- **Purpose**: Transfers name (inherits allowance).
- **Checks**: Name exists, auth via `_transfer`.
- **Internal Calls**:
  - `_transfer`: Updates `ownerOf`/`_balances`, emits `Transfer`.
- **Effects**: ERC721 transfer.

### transferFrom(address _from, address _to, uint256 _tokenId)
- **Purpose**: ERC721 transfer.
- **Checks**: `_from==ownerOf`, valid tokenId.
- **Internal Calls**:
  - `_transfer`: Updates `ownerOf`/`_balances`, emits `Transfer`.
- **Effects**: Transfers name.

### safeTransferFrom(address _from, address _to, uint256 _tokenId, bytes _data)
- **Purpose**: Safe ERC721 transfer.
- **Checks**: `_from==ownerOf`, valid tokenId, receiver hook.
- **Internal Calls**:
  - `_transfer`: Updates `ownerOf`/`_balances`.
  - `_checkOnERC721Received`: Invokes receiver hook.
  - `_isContract`: Checks if `_to` is contract.
- **Effects**: Transfers with hook verification.

### approve(address _to, uint256 _tokenId)
- **Purpose**: Approves spender.
- **Checks**: Caller=owner/operator, valid tokenId.
- **Effects**: Sets `getApproved`, emits `Approval`.

### setApprovalForAll(address _operator, bool _approved)
- **Purpose**: Batch operator approval.
- **Effects**: Updates `isApprovedForAll`, emits `ApprovalForAll`.

### balanceOf(address _owner)
- **Purpose**: Returns name count.
- **Returns**: uint256 (`_balances`).

### setCustomRecord(uint256 _nameHash, uint256 _index, CustomRecord _record)
- **Purpose**: Sets name record (0-4).
- **Checks**: Caller=owner, valid index/tokenId, `_validateRecord`.
- **Internal Calls**:
  - `_validateRecord`: String length checks.
- **Effects**: Updates `customRecords`, emits `RecordsUpdated`.

### setSubnameRecord(uint256 _parentHash, uint256 _subnameIndex, uint256 _recordIndex, CustomRecord _record)
- **Purpose**: Sets subname record.
- **Checks**: Caller=parent owner, valid indices, `_validateRecord`.
- **Internal Calls**:
  - `_validateRecord`: String limits.
- **Effects**: Updates `subnameRecords`, emits `RecordsUpdated`.

### mintSubname(string _parentName, string _subname)
- **Purpose**: Mints subname under parent.
- **Checks**: Valid subname, caller=parent owner.
- **Internal Calls**:
  - `_stringToHash`: Hashes parent/subname.
  - `_validateName`: Subname format.
- **Effects**: Pushes `SubnameRecord`, emits `SubnameMinted`.

### setMailToken(address _mailToken) [onlyOwner]
- **Purpose**: Sets ERC20 token.
- **Effects**: Updates `mailToken`.

### setMailLocker(address _mailLocker) [onlyOwner]
- **Purpose**: Sets `MailLocker` address.
- **Effects**: Updates `mailLocker`.

### setMailMarket(address _mailMarket) [onlyOwner]
- **Purpose**: Sets `MailMarket` address.
- **Effects**: Updates `mailMarket`.

### transferOwnership(address _newOwner) [onlyOwner]
- **Purpose**: Transfers ownership.
- **Checks**: `_newOwner !=0`.
- **Effects**: Sets `owner`, emits `OwnershipTransferred`.

### getName(string _name)
- **Purpose**: Resolves name to owner.
- **Internal Calls**:
  - `_stringToHash`: Name hash.
- **Returns**: address (`ownerOf`).

### getNameRecords(uint256 step, uint256 maxIterations)
- **Purpose**: Paginated name query.
- **Returns**: `NameRecord[]`.

### getSubnameID(string _parentName, string _subname)
- **Purpose**: Finds subname index.
- **Internal Calls**:
  - `_stringToHash`: Hashes.
- **Returns**: (index, found).

### getSubRecords(string _parentName, string _subname)
- **Purpose**: Retrieves subname records.
- **Internal Calls**:
  - `_stringToHash`, `this.getSubnameID`.
- **Returns**: `CustomRecord[5]`.

### getSubnames(string _parentName, uint256 step, uint256 maxIterations)
- **Purpose**: Paginated subname strings.
- **Internal Calls**:
  - `_stringToHash`.
- **Returns**: `string[]`.

## Internal Functions
- **_stringToHash(string _str)**: Generates keccak256 hash.
- **_validateName(string _name)**: Checks length <=24, no spaces.
- **_validateRecord(CustomRecord _record)**: Checks string lengths <=1024.
- **_transfer(uint256 _tokenId, address _to)**: Updates `ownerOf`/`_balances`, emits `Transfer`.
- **_isContract(address _account)**: Assembly check for contract.
- **_checkOnERC721Received(address _to, address _from, uint256 _tokenId, bytes _data)**: Invokes receiver hook.
- **_calculateMinRequired(uint256 _queueLen)**: 1 * 2^_queueLen wei.
- **_calculateWaitDuration(uint256 _queueLen)**: 10min + 6h*_queueLen, cap 2w.
- **_processNextCheckin()**: Updates `allowanceEnd`, emits events.
- **_processQueueRequirements()**: Locks tokens, calls `MailLocker.depositLock`.
- **_settleBid(uint256 _nameHash, uint256 _bidIndex, bool _isETH, address _token)**: Calls `MailMarket.settleBid`, handles post-grace checkin.

## Key Insights
- **ERC721 Integration**: `tokenId` enables standard transfers; `_balances` O(1); `nameHashToTokenId` speeds auth.
- **Queue Mechanics**: Locks via `MailLocker`; `advance` O(1); transfers don’t cancel queue.
- **Bidding**: Moved to `MailMarket`; `_settleBid` routes to `MailMarket.settleBid`.
- **Fee Handling**: Handled in `MailMarket` for token bids.
- **DoS/Gas**: Paginated views, O(1) queue processing, assembly for `_isContract`.
- **Ownership**: Unified via `ownerOf`.
- **Grace/Queue**: Post-grace bids via `MailMarket`, queues race for renewal.
- **Events**: ERC721 and custom; no emits in views.
- **Degradation**: Reverts on critical failures; try/catch for hooks.

## MailLocker
**Version**: 0.0.1  
**Date**: 05/10/2025  

### Overview
Locks `MailToken` deposits from `MailNames` queues (10y unlock, multi-indexed). Owner-set post-deploy; handles normalized amounts.

### Structs
- **Deposit**: 
  - `amount`: Normalized (no decimals).
  - `unlockTime`: Timestamp.

### State Variables
- `owner`: Contract owner.
- `mailToken`: IERC20 token.
- `mailNames`: `MailNames` address.
- `userDeposits`: Maps `address` to `Deposit[]`.

### External Functions and Call Trees
#### depositLock(uint256 _normalizedAmount, address _user, uint256 _unlockTime) [only MailNames]
- **Purpose**: Locks deposit.
- **Checks**: Caller=`mailNames`, transfer succeeds.
- **Effects**: Pushes to `userDeposits`, emits `DepositLocked`.

#### withdraw(uint256 _index)
- **Purpose**: Withdraws deposit (swap-pop).
- **Checks**: Valid index, time >= unlock.
- **Effects**: Transfers, emits `DepositWithdrawn`.

#### setMailToken(address _mailToken) [onlyOwner]
- **Purpose**: Sets token.
- **Effects**: Updates `mailToken`.

#### setMailNames(address _mailNames) [onlyOwner]
- **Purpose**: Sets `MailNames`.
- **Effects**: Updates `mailNames`.

#### transferOwnership(address _newOwner) [onlyOwner]
- **Purpose**: Transfers ownership.
- **Checks**: `_newOwner !=0`.
- **Effects**: Sets `owner`, emits `OwnershipTransferred`.

#### getUserDeposits(address _user, uint256 _step, uint256 _maxIterations)
- **Purpose**: Paginated deposits.
- **Returns**: `Deposit[]`.

#### getTotalLocked(address _user)
- **Purpose**: Sums locked amounts.
- **Returns**: uint256 total.

### Key Insights
- **Multi-Deposits**: Separate 10y locks per user.
- **Normalization**: Stores sans decimals; transfers use decimals.
- **Gas/DoS**: Swap-pop, paginated views.
- **Events**: `DepositLocked`/`Withdrawn`.
- **Degradation**: Reverts on critical failures.

## MailMarket
**Version**: 0.0.1  
**Date**: 05/10/2025  

### Overview
Handles bidding for `MailNames` (ETH/ERC20, auto-settle post-grace). Supports token bids with fee handling. Owner-set `mailNames`/`mailToken`.

### Structs
- **Bid**: 
  - `bidder`: Bidder address.
  - `amount`: Bid amount (post-fee for tokens).
  - `timestamp`: Bid time.
- **BidValidation**: 
  - `nameHash`: Name hash.
  - `tokenId`: ERC721 token ID.
  - `queueLen`: Queue length (0 in `MailMarket`).
  - `minReq`: Minimum required wei.
  - `normMin`: Normalized minimum.
- **TokenTransferData**: 
  - `balanceBefore`: Pre-transfer balance.
  - `balanceAfter`: Post-transfer balance.
  - `receivedAmount`: Actual tokens received.
  - `transferAmount`: Requested transfer amount.

### State Variables
- `owner`: Contract owner.
- `mailToken`: ERC20 token.
- `mailNames`: `MailNames` address.
- `ethBids`: Maps `uint256` (nameHash) to `Bid[100]`.
- `tokenBids`: Maps `uint256` (nameHash) to `mapping(address => Bid[100])`.
- `allowedTokens`: Array of allowed ERC20 tokens.
- `tokenCounts`: Maps `address` to count in `allowedTokens`.
- `MAX_BIDS`: 100.

### External Functions and Call Trees
#### placeETHBid(string _name)
- **Purpose**: Places ETH bid.
- **Checks**: Name exists, `msg.value>0`, sufficient `mailToken`.
- **Internal Calls**:
  - `_validateBidRequirements`: Checks name, amount, `mailToken` balance.
  - `_insertAndSort`: Sorts bids descending.
- **Effects**: Stores bid, emits `BidPlaced`.

#### placeTokenBid(string _name, uint256 _amount, address _token)
- **Purpose**: Places ERC20 bid.
- **Checks**: Valid token, name, amount, `mailToken` balance.
- **Internal Calls**:
  - `_validateBidRequirements`: Validates inputs.
  - `_handleTokenTransfer`: Computes received amount.
  - `_insertAndSort`: Sorts bids.
- **Effects**: Stores bid, emits `BidPlaced`.

#### closeBid(uint256 _nameHash, bool _isETH, address _token, uint256 _bidIndex)
- **Purpose**: Refunds/removes bid.
- **Checks**: Valid index, caller=bidder.
- **Internal Calls**:
  - `_removeBidFromArray`: Shifts array.
- **Effects**: Transfers refund, emits `BidClosed`.

#### acceptBid(uint256 _nameHash, bool _isETH, address _token, uint256 _bidIndex)
- **Purpose**: Manual bid settlement.
- **Checks**: Caller=owner, valid bid.
- **Internal Calls**:
  - `this.settleBid`: Transfers funds, calls `MailNames.transfer`.
- **Effects**: Transfers ownership, emits `BidSettled`.

#### settleBid(uint256 _nameHash, uint256 _bidIndex, bool _isETH, address _token)
- **Purpose**: Settles bid (called by `MailNames`).
- **Checks**: Caller=`mailNames`, valid bid.
- **Internal Calls**:
  - `_transferBidFunds`: Transfers to old owner.
  - `_removeBidFromArray`: Clears bid.
- **Effects**: Calls `MailNames.transfer`, emits `BidSettled`.

#### checkTopBidder(uint256 _nameHash)
- **Purpose**: Validates top ETH bid.
- **Checks**: Sufficient `mailToken` balance.
- **Internal Calls**:
  - `_calculateMinRequired`: Minimum wei.
- **Effects**: Trims invalid bid, emits `TopBidInvalidated`.
- **Returns**: (bidder, amount, valid).

#### getNameBids(string _name, bool _isETH, address _token)
- **Purpose**: Retrieves bids for name.
- **Internal Calls**:
  - `_stringToHash`: Name hash.
- **Returns**: `Bid[100]`.

#### addAllowedToken(address _token) [onlyOwner]
- **Purpose**: Adds ERC20 token.
- **Effects**: Pushes to `allowedTokens`, emits `TokenAdded`.

#### removeAllowedToken(address _token) [onlyOwner]
- **Purpose**: Removes token.
- **Effects**: Removes from `allowedTokens`, emits `TokenRemoved`.

#### setMailToken(address _mailToken) [onlyOwner]
- **Purpose**: Sets token.
- **Effects**: Updates `mailToken`.

#### setMailNames(address _mailNames) [onlyOwner]
- **Purpose**: Sets `MailNames`.
- **Effects**: Updates `mailNames`.

#### transferOwnership(address _newOwner) [onlyOwner]
- **Purpose**: Transfers ownership.
- **Checks**: `_newOwner !=0`.
- **Effects**: Sets `owner`, emits `OwnershipTransferred`.

### Internal Functions
- **_stringToHash(string _str)**: Generates keccak256 hash.
- **_validateBidRequirements(string _name, uint256 _bidAmount)**: Validates name, amount, `mailToken`.
- **_handleTokenTransfer(address _token, uint256 _amount)**: Computes received amount.
- **_insertAndSort(Bid[100] storage bidsArray, Bid newBid)**: Sorts bids descending.
- **_removeBidFromArray(Bid[100] storage bidsArray, uint256 _bidIndex)**: Clears bid.
- **_transferBidFunds(address _oldOwner, uint256 _amount, bool _isETH, address _token)**: Transfers funds.
- **_calculateMinRequired(uint256 _queueLen)**: 1 * 2^_queueLen wei.

### Key Insights
- **Bidding**: ETH/ERC20 bids, auto-settle via `MailNames._settleBid`.
- **Fee Handling**: `TokenTransferData` ensures accurate amounts.
- **Gas/DoS**: Fixed 100 bids, sorted descending.
- **Events**: `BidPlaced`/`BidSettled`/`BidClosed`/`TopBidInvalidated`.

## Notes
- Deploy `MailLocker`, `MailMarket`, then `MailNames`.
- Set `mailToken`/`mailLocker`/`mailMarket` post-deploy.
- No `ReentrancyGuard` needed.
- All on-chain; try/catch for hooks.
