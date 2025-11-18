# MailNames
**Version**: 0.0.34  
**Date**: 18/11/2025  
**SPDX-License-Identifier**: BSL 1.1 - Peng Protocol 2025  
**Solidity Version**: ^0.8.2  

## Overview
`MailNames` is a decentralized domain name system with ERC721 compatibility, enabling free name minting with a 1-year allowance. Time-sensitive logic now uses `_now()` for VM testing via `warp()`/`unWarp()`.

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
  - `queuedTime`: Timestamp at queue (via `_now()`).
  - `waitDuration`: Wait (10min + 6h*queueLen, cap 2w).
- **PendingSettlement**: Stores queued settlement details.
  - `nameHash`: Name to settle.
  - `bidIndex`: Bid index in `MailMarket`.
  - `isETH`: True if ETH bid.
  - `token`: Token address (if ERC20).
  - `queueTime`: Timestamp at queue (via `_now()`).
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
- `currentTime`: uint256 (warp state).
- `checkInCost`: uint256 = 5e17 (0.5 $MAIL, adjustable).
- `isWarped`: bool (warp flag).
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
  - `_now()`: Sets `allowanceEnd`/`graceEnd`.
- **Effects**: Sets `NameRecord`, maps `tokenIdToNameHash`/`nameHashToTokenId`/`ownerOf`/`_balances`, pushes to `allNameHashes`, emits `NameMinted`/`Transfer`.

### queueCheckIn(uint256 _nameHash)
- **Purpose**: Queues checkin post-expiration (locks fixed 0.5 $MAIL in `MailLocker` for 10y).
- **Checks**: Caller=owner, `_now()` > allowanceEnd, transfer succeeds.
- **Internal Calls**:
  - `_processQueueRequirements`: Transfers fixed `checkInCost`, calls `MailLocker.depositLock` (normalized).
  - `_calculateWaitDuration`: 10min + 6h*queueLen, cap 2w.
  - `this.advance`: Processes if ready.
- **Effects**: Pushes `PendingCheckin`, emits `QueueCheckInQueued`.

### advance()
- **Purpose**: Processes one ready checkin.
- **Checks**: Time/user eligibility via `_now()`.
- **Internal Calls**:
  - `_processNextCheckin`: Checks `queuedTime + waitDuration <= _now()`, updates `allowanceEnd`, clears `pendingSettlements`, emits `NameCheckedIn`/`CheckInProcessed`.
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

### warp(uint256 newTimestamp) [onlyOwner]
- **Purpose**: Sets `currentTime`, enables warp.
- **Effects**: `currentTime = newTimestamp`, `isWarped = true`.

### unWarp() [onlyOwner]
- **Purpose**: Disables warp.
- **Effects**: `isWarped = false`.

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
- **Purpose**: Owner-initiated bid acceptance (pre-expiration) or anyone after full grace (post-expiration).
- **Checks**:
  - Pre-expiration (`_now() <= allowanceEnd`): only current owner.
  - Post-expiration (`_now() > graceEnd`): anyone.
- **Internal Calls**:
  - `_settleBid`:
    - Pre-grace → immediate `MailMarket.settleBid`.
    - Post-grace → queues into `pendingSettlements` (processed later via `processSettlement`).
- **Effects**: Immediate or delayed settlement.

### processSettlement(uint256 _index)
- **Purpose**: Anyone can process a queued post-grace settlement after 3 weeks.
- **Checks**: `_index` valid, `_now() >= queueTime + 3 weeks`.
- **Internal Calls**:
  - `_calculateSettlementRequirements` → fixed 0.5 $MAIL.
  - `_validateBidderMAILBalance`: Checks winning bidder still holds ≥ 0.5 $MAIL.
  - If insufficient → `MailMarket.cancelBid` (1% penalty), remove settlement, exit gracefully.
  - Else → `MailMarket.settleBid` → transfer name + funds, lock 0.5 $MAIL from new owner, queue new checkin, reset grace/allowance, emit `SettlementProcessed`.
- **Effects**: Name changes hands or settlement is dropped.

### setCheckInCost(uint256 _cost) [onlyOwner]
- Allows future adjustment of the fixed check-in cost.

### Key Insights
**Ownership**: Unified via `ownerOf`; `acceptMarketBid` ensures owner auth.
- **Grace/Queue**: 7-day primary grace; post-grace bids queue for 3 weeks; renewals clear settlements, preserving bids for later acceptance.
- **Time Logic**: All timestamps use `_now()` → `isWarped ? currentTime : block.timestamp`.
- **Events**: ERC721 (`Transfer`/`Approval`/`ApprovalForAll`) and custom (`SettlementProcessed`); no emits in views.
- **Degradation**: Reverts on critical failures; try/catch for hooks; `advance`/`processSettlement` skip gracefully.

## MailLocker
**Version**: 0.0.2  
**Date**: 07/11/2025  

### Overview
Locks `MailToken` deposits from `MailNames` queues (10y unlock, multi-indexed). Owner-set post-deploy; handles normalized amounts. Time warp added.

### Structs
- **Deposit**: 
  - `amount`: Normalized (no decimals).
  - `unlockTime`: Timestamp (set externally).

### State Variables
- `owner`: Contract owner.
- `mailToken`: IERC20 token.
- `mailNames`: `MailNames` address.
- `userDeposits`: Maps `address` to `Deposit[]`.
- `currentTime`: uint256 (warp state).
- `isWarped`: bool (warp flag).

### External Functions and Call Trees
#### depositLock(uint256 _normalizedAmount, address _user, uint256 _unlockTime) [only MailNames]
- **Purpose**: Locks deposit from `MailNames`.
- **Checks**: Caller=`mailNames`, transfer succeeds.
- **Effects**: Pushes to `userDeposits`, emits `DepositLocked`.

#### withdraw(uint256 _index)
- **Purpose**: Withdraws deposit (swap-pop).
- **Checks**: Valid index, `_now()` >= unlockTime.
- **Internal Calls**:
  - `_now()`: Time check.
- **Effects**: Transfers, emits `DepositWithdrawn`.

#### warp(uint256 newTimestamp) [onlyOwner]
- **Purpose**: Sets `currentTime`, enables warp.
- **Effects**: `currentTime = newTimestamp`, `isWarped = true`.

#### unWarp() [onlyOwner]
- **Purpose**: Disables warp.
- **Effects**: `isWarped = false`.

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
- **Time Checks**: `withdraw` uses `_now()` for unlock.
- **Gas/DoS**: Swap-pop on withdraw, paginated views.
- **Events**: `DepositLocked`/`Withdrawn`.
- **Degradation**: Reverts on invalid transfer/time.

## MailMarket
**Version**: 0.0.7  
**Date**: 07/11/2025  

### Overview
Handles bidding for `MailNames` (ETH/ERC20, auto-settle post-grace via queue). Supports token bids with tax token handling. Owner-set `mailNames`/`mailToken`. Bidders hold $MAIL scaled by their active bids, deterring griefing. Time warp added.

### Structs
- **Bid**: 
  - `bidder`: Bidder address.
  - `amount`: Bid amount (post-fee for tokens).
  - `timestamp`: Bid time (via `_now()`).
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
- `bidderActiveBids`: Maps `address` to `uint256` (bidder’s active bids across all names).
- `currentTime`: uint256 (warp state).
- `isWarped`: bool (warp flag).
- `MAX_BIDS`: 100.

### External Functions and Call Trees
#### placeETHBid(string _name)
- **Purpose**: Places ETH bid, increments `bidderActiveBids`.
- **Checks**: Name exists, `msg.value>0`, sufficient `mailToken` (scaled by `bidderActiveBids`).
- **Internal Calls**:
  - `_validateBidRequirements`: Checks name, amount, `mailToken` balance.
  - `_insertAndSort`: Inserts bid with sorted insertion.
  - `_now()`: Sets `timestamp`.
- **Effects**: Stores bid, emits `BidPlaced`.

#### placeTokenBid(string _name, uint256 _amount, address _token)
- **Purpose**: Places ERC20 bid, increments `bidderActiveBids`.
- **Checks**: Valid token, name, amount, `mailToken` balance (scaled by `bidderActiveBids`).
- **Internal Calls**:
  - `_validateBidRequirements`: Validates inputs.
  - `_handleTokenTransfer`: Computes received amount.
  - `_insertAndSort`: Inserts bid with sorted insertion.
  - `_now()`: Sets `timestamp`.
- **Effects**: Stores bid, emits `BidPlaced`.

#### cancelBid(uint256 _nameHash, uint256 _bidIndex, bool _isETH, address _token) [only MailNames]
- Penalises winning bidder who no longer holds required $MAIL.
- Burns 1%, refunds 99%, removes bid, decrements `bidderActiveBids`.

#### closeBid(uint256 _nameHash, bool _isETH, address _token, uint256 _bidIndex)
- **Purpose**: Refunds/removes bid, decrements `bidderActiveBids`.
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
- **Purpose**: Settles bid (called by `MailNames`), decrements `bidderActiveBids`.
- **Checks**: Caller=`mailNames`, valid bid.
- **Internal Calls**:
  - `_transferBidFunds`: Transfers to old owner.
  - `_removeBidFromArray`: Clears bid.
- **Effects**: Calls `MailNames.transfer`, emits `BidSettled`.

#### checkTopBidder(uint256 _nameHash)
- **Purpose**: Validates top ETH bid’s `mailToken` balance; closes invalid bid, refunds, clears data.
- **Checks**: Sufficient `mailToken` balance against `_calculateMinRequired`.
- **Internal Calls**:
  - `_calculateMinRequired`: Minimum wei (1 * 2^0).
  - `_removeBidFromArray`: Clears invalid bid.
- **Effects**: Refunds ETH, decrements `bidderActiveBids`, emits `BidClosed`/`TopBidInvalidated`.
- **Returns**: (bidder, amount, valid).

#### warp(uint256 newTimestamp) [onlyOwner]
- **Purpose**: Sets `currentTime`, enables warp.
- **Effects**: `currentTime = newTimestamp`, `isWarped = true`.

#### unWarp() [onlyOwner]
- **Purpose**: Disables warp.
- **Effects**: `isWarped = false`.

#### getBidDetails(uint256 _nameHash, uint256 _bidIndex, bool _isETH, address _token) view
- Returns bidder and amount for a specific bid slot (used by `processSettlement`).

#### getNameBids(string _name, bool _isETH, address _token)
- **Purpose**: Retrieves all bids for a name (ETH or ERC20).
- **Internal Calls**:
  - `_stringToHash`: Computes name hash.
- **Returns**: `Bid[100]`.

#### getBidderBids(string _name, address _bidder, bool _isETH, address _token, uint256 _step, uint256 _maxIterations)
- **Purpose**: Retrieves paginated bid indices for a bidder on a name and token ( `_isETH=true` for ETH, `_isETH=false` ignores `_token` address if ETH).
- **Internal Calls**:
  - `_stringToHash`: Computes name hash.
- **Returns**: `uint256[]` (bid indices).

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
- **_validateBidRequirements(string _name, uint256 _bidAmount)**: Checks name, amount, $MAIL scaled by `bidderActiveBids`.
- **_handleTokenTransfer(address _token, uint256 _amount)**: Computes received amount for token bids.
- **_insertAndSort(Bid[100] storage bidsArray, Bid newBid)**: Inserts bid with sorted insertion for gas efficiency.
- **_removeBidFromArray(Bid[100] storage bidsArray, uint256 _bidIndex)**: Clears bid via shift.
- **_transferBidFunds(address _oldOwner, uint256 _amount, bool _isETH, address _token)**: Transfers funds (ETH or token).
- **_calculateMinRequired(uint256 _queueLen)**: 1 * 2^_queueLen wei.
- **_now()**: Returns `isWarped ? currentTime : block.timestamp`.

### Key Insights
- **Bidding**: ETH/ERC20 bids; auto-settle post-grace via `MailNames._settleBid` (queued for 3w); owner-initiated via `acceptBid` -> `MailNames.acceptMarketBid`.
- **Griefing resistance**: Fixed low lock cost + 3-week delay + 1% penalty on insufficient balance makes spamming expensive and ineffective.
- **Graceful degradation**: If the winning bidder disappears or sells their $MAIL, the name simply stays with the original owner.
- **Fee Handling**: `TokenTransferData` ensures accurate token amounts.
- **Time Logic**: Bid timestamps use `_now()`.
- **Gas/DoS**: Fixed 100 bids; optimized `_insertAndSort` with sorted insertion; paginated views (`getNameBids`, `getBidderBids`).
- **Events**: `BidPlaced`/`BidSettled`/`BidClosed`/`TopBidInvalidated`/`OwnershipTransferred`.
- **Access Control**: `settleBid` restricted to `MailNames`; `acceptMarketBid` ensures owner auth.

## Notes
- No `ReentrancyGuard` needed; no recursive calls.
- All on-chain; try/catch for ERC721 hooks.
- **Time Warping**: Unified across `MailNames`, `MailLocker`, `MailMarket` for testing.