# MailNames
**Version**: 0.0.16  
**Date**: 07/10/2025  
**SPDX-License-Identifier**: BSL 1.1 - Peng Protocol 2025  
**Solidity Version**: ^0.8.2  

## Overview
`MailNames` is a decentralized domain name system with ERC721 compatibility, enabling free name minting with a 1-year allowance. 

### Renewal 
Names can only be renewed using "check-ins" during a 7-day grace period after the name's allowance ends.

- **Check-ins:** A check-in is a 10 year lockup of $MAIL (handled by `MailLocker`) required to renew a name. Check-ins are queued and can take a minimum of 10 minutes or maximum of 2 weeks, the time and amount required depend on the number of active check-ins waiting in queue. 

- **Retention:** Renewal is not strictly required to retain a name, however, after the primary grace-period; if any active ETH bids exist for the name, the system will settle the name to the highest ETH bidder after an additional 3-week secondary grace period. In this way only high value names require continuous renewal.

- **Wait Dynamics:** Because the check-in wait time is sandwiched within a one month grace period;
for valuable names, this forces the user to initiate renewal at any point during the first two weeks of their grace, absorbing any lock-up amount required to retain the name, or losing the name to the highest bidder. 

### Bidding 
Bids (handled by `MailMarket`) are limited to a maximum of (100) bids per token, bidders are required to hold enough $MAIL to cover the cost of renewing the name. Each new bid in a full array pushes out the lowest bid and ensures that the highest bid has enough $MAIL to cover renewal. 

### Subname and Records
Users can attach up to (5) "records" to their name, and create subnames in kind. Subnames are transferred with their parent name. Names are limited to (24) characters and records to (1024). 

---

MailNames is the primary name system for Chainmail (link unavailable). 

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
- **PendingSettlement**: Stores queued settlement details.
  - `nameHash`: Name to settle.
  - `bidIndex`: Bid index in `MailMarket`.
  - `isETH`: True if ETH bid.
  - `token`: Token address (if ERC20).
  - `queueTime`: Block timestamp at queue.
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
- `pendingSettlements`: Array of `PendingSettlement`.
- `nextProcessIndex`: uint256 (processed queue position).
- `owner`: address (contract owner).
- `mailToken`: address (ERC20 token).
- `mailLocker`: address (MailLocker contract).
- `mailMarket`: address (MailMarket contract).
- `ALLOWANCE_PERIOD`: 365 days.
- `GRACE_PERIOD`: 7 days.
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
  - `_processNextCheckin`: Updates `allowanceEnd`, clears `pendingSettlements`, emits `NameCheckedIn`/`CheckInProcessed`.
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

### acceptMarketBid(uint256 _nameHash, bool _isETH, address _token, uint256 _bidIndex)
- **Purpose**: Allows owner to accept bid via `MailMarket`.
- **Checks**: Caller=owner, within allowance, valid tokenId.
- **Internal Calls**:
  - `_settleBid`: Queues or settles via `MailMarket.settleBid`.
- **Effects**: Triggers settlement, emits `BidSettled` via `MailMarket`.

### processSettlement(uint256 _index)
- **Purpose**: Processes queued settlement after 3 weeks.
- **Checks**: Valid index, time elapsed.
- **Internal Calls**:
  - `MailMarket.settleBid`: Executes settlement.
- **Effects**: Resets `graceEnd`, swaps/pops queue, emits `SettlementProcessed`.

### getName(string _name)
- **Purpose**: Resolves name to owner.
- **Internal Calls**:
  - `_stringToHash`: Name hash.
- **Returns**: address (`ownerOf`).

### getNameRecords(string _name)
- **Purpose**: Resolves name to NameRecord.
- **Internal Calls**:
  - `_stringToHash`: Name hash.
- **Returns**: `NameRecord` (single record).

### getSettlementById(uint256 _index)
- **Purpose**: Returns PendingSettlement for given index.
- **Checks**: Valid index.
- **Returns**: `PendingSettlement` (single struct).

### getPendingSettlements(string _name, uint256 _step, uint256 _maxIterations)
- **Purpose**: Paginated pending settlements for a name.
- **Internal Calls**:
  - `_stringToHash`: Name hash.
- **Returns**: `PendingSettlement[]`.

### getNameByTokenId(uint256 _tokenId)
- **Purpose**: Resolves tokenId to name string.
- **Checks**: Token minted.
- **Returns**: string (`nameRecords[nameHash].name`).

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

### getSubnames(string _parentName, uint256 step, uint256 _maxIterations)
- **Purpose**: Paginated subname strings.
- **Internal Calls**:
  - `_stringToHash`.
- **Returns**: `string[]`.

## Internal Functions
- **_stringToHash(string _str)**: Generates keccak256 hash for storage/retrieval.
- **_validateName(string _name)**: Ensures length <=24, no spaces, >0.
- **_validateRecord(CustomRecord _record)**: Checks string lengths <=1024.
- **_transfer(uint256 _tokenId, address _to)**: Updates `ownerOf`/`_balances`, emits `Transfer`.
- **_isContract(address _account)**: Assembly check for contract detection.
- **_checkOnERC721Received(address _to, address _from, uint256 _tokenId, bytes _data)**: Invokes receiver hook with try/catch.
- **_calculateMinRequired(uint256 _queueLen)**: 1 * 2^_queueLen wei for checkin cost.
- **_calculateWaitDuration(uint256 _queueLen)**: 10min + 6h*_queueLen, cap 2w.
- **_processNextCheckin()**: Updates `allowanceEnd`, clears `pendingSettlements`, emits `NameCheckedIn`/`CheckInProcessed`.
- **_processQueueRequirements()**: Locks tokens via `MailLocker.depositLock`.
- **_settleBid(uint256 _nameHash, uint256 _bidIndex, bool _isETH, address _token)**: Queues settlement if post-grace (3w delay), immediate otherwise; handles checkin queueing.
- **_clearPendingSettlements(uint256 _nameHash)**: Removes all pending settlements for a name on renewal.

## Key Insights
- **ERC721 Integration**: `tokenId` enables standard transfers; `_balances` O(1); `nameHashToTokenId` speeds auth.
- **Queue Mechanics**: Locks via `MailLocker`; `advance` O(1); transfers don’t cancel queue; post-grace settlements queued for 3 weeks, cleared on renewal via `_clearPendingSettlements`.
- **Bidding**: `MailMarket` handles ETH/ERC20 bids; `acceptMarketBid` enables owner-initiated settlements within allowance; `processSettlement` for post-grace.
- **Settlement Management**: `pendingSettlements` uses swap-and-pop for removals (`processSettlement`, `_clearPendingSettlements`), preventing gaps; only one settlement finalizes per name.
- **Fee Handling**: Handled in `MailMarket` via `TokenTransferData`.
- **Gas/DoS**: Paginated views (`getPendingSettlements`, `getSubnames`), O(1) queue processing, swap-pop for settlements/checkins, assembly for `_isContract`.
- **Ownership**: Unified via `ownerOf`; `acceptMarketBid` ensures owner auth.
- **Grace/Queue**: 7-day primary grace; post-grace bids queue for 3 weeks; renewals clear settlements, preserving bids for later acceptance.
- **Events**: ERC721 (`Transfer`/`Approval`/`ApprovalForAll`) and custom (`SettlementProcessed`); no emits in views.
- **Degradation**: Reverts on critical failures; try/catch for hooks; `advance`/`processSettlement` skip gracefully.

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
- **Purpose**: Locks deposit from `MailNames`.
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
- **Purpose**: Paginated deposits view.
- **Returns**: `Deposit[]`.

#### getTotalLocked(address _user)
- **Purpose**: Sums locked amounts.
- **Returns**: uint256 total.

### Key Insights
- **Multi-Deposits**: Separate 10y locks per user; withdraw by index.
- **Normalization**: Stores sans decimals; transfers use decimals.
- **Gas/DoS**: Swap-pop on withdraw, paginated views.
- **Events**: `DepositLocked`/`Withdrawn`.
- **Degradation**: Reverts on invalid transfer/time.

## MailMarket
**Version**: 0.0.2  
**Date**: 05/10/2025  

### Overview
Handles bidding for `MailNames` (ETH/ERC20, auto-settle post-grace via queue). Supports token bids with tax token handling. Owner-set `mailNames`/`mailToken`.

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
- **Purpose**: Initiates owner-accepted bid.
- **Checks**: None (delegates to `MailNames`).
- **Internal Calls**:
  - `MailNames.acceptMarketBid`: Validates owner, calls `settleBid`.
- **Effects**: Triggers settlement via `MailNames`, emits `BidSettled`.

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
- **_validateBidRequirements(string _name, uint256 _bidAmount)**: Checks name, amount, $MAIL scaled by active bids.
- **_handleTokenTransfer(address _token, uint256 _amount)**: Computes received amount for token bids.
- **_insertAndSort(Bid[100] storage bidsArray, Bid newBid)**: Sorts bids descending by amount, then timestamp.
- **_removeBidFromArray(Bid[100] storage bidsArray, uint256 _bidIndex)**: Clears bid via shift.
- **_transferBidFunds(address _oldOwner, uint256 _amount, bool _isETH, address _token)**: Transfers funds (ETH or token).
- **_calculateMinRequired(uint256 _queueLen)**: 1 * 2^_queueLen wei.

### Key Insights
- **Bidding**: ETH bids; auto-settle post-grace via `MailNames._settleBid` (queued for 3w); owner-initiated via `acceptBid` -> `MailNames.acceptMarketBid`.
- **Fee Handling**: `TokenTransferData` ensures accurate token amounts.
- **Gas/DoS**: Fixed 100 bids, sorted descending; paginated views.
- **Events**: `BidPlaced`/`BidSettled`/`BidClosed`/`TopBidInvalidated`/`OwnershipTransferred`.
- **Access Control**: `settleBid` restricted to `MailNames`; `acceptMarketBid` ensures owner auth.

## Notes
- No `ReentrancyGuard` needed; no recursive calls.
- All on-chain; try/catch for ERC721 hooks.
- Automated renewal scripts can be outbid by users renewing during the script’s grace period, increasing lock-up costs and depleting script tokens before withdrawals.