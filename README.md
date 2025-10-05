# MailNames
**Version**: 0.0.6
**Date**: 05/10/2025  
**SPDX-License-Identifier**: BSL 1.1 - Peng Protocol 2025  
**Solidity Version**: ^0.8.2  

## Overview
`MailNames` is a decentralized domain name system inspired by ENS with ERC721 compatibility, enabling free name minting (indexed by tokenId from 0 upward) with a 1-year allowance and 30-day grace period for queued check-ins via MailLocker token locks (exponential min deposit, 10y lock, dynamic wait 10min-2w). Post-grace, highest ETH bid or oldest ERC20 bid claims via auto-settlement. Supports subnames (implicitly transferred with parents) with custom records (strings <=1024 chars), controlled by parent owners. Bidding in ETH/ERC20 with fee-on-transfer handling. Names limited to 24 chars. Primary for Chainmail (link unavailable). Ownership unified under ERC721 `ownerOf`; transferred names inherit allowance. Safe transfers enforce ERC721Receiver hooks for contract recipients.

## Structs
- **NameRecord**: Stores domain details.
  - `name`: String (no spaces, <=24 chars).
  - `nameHash`: keccak256 hash of name.
  - `tokenId`: ERC721 token ID (auto-incremented on mint).
  - `allowanceEnd`: Timestamp when allowance expires (set on mint/processed queue only).
  - `customRecords`: Array of 5 `CustomRecord` structs.
- **SubnameRecord**: Stores subname details (transfers with parent).
  - `parentHash`: Parent name's hash.
  - `subname`: Subname string (<=24 chars).
  - `subnameHash`: keccak256 hash of subname.
  - `customRecords`: Array of 5 `CustomRecord` structs.
- **Bid**: Stores bid details.
  - `bidder`: Bidder address.
  - `amount`: Bid amount (ETH or token, post-fee for ERC20).
  - `timestamp`: Bid placement time.
  - `isETH`: True if ETH, false for ERC20.
  - `token`: ERC20 token address (if not ETH).
- **PendingCheckin**: Stores queued checkin details.
  - `nameHash`: Name to check in.
  - `user`: Owner address.
  - `queuedTime`: Block timestamp at queue.
  - `waitDuration`: Calculated wait (10min + 6h*queueLen, cap 2w).
- **CustomRecord**: Stores metadata (all strings <=1024 chars).
  - `text`: General text (e.g., description).
  - `resolver`: Resolver info.
  - `contentHash`: Content hash (e.g., IPFS).
  - `ttl`: Time-to-live.
  - `targetAddress`: Associated address.

## State Variables
- `nameRecords`: Maps `uint256` (nameHash) to `NameRecord`.
- `subnameRecords`: Maps `uint256` (parentHash) to `SubnameRecord[]` (pagination via step/maxIterations).
- `bids`: Maps `uint256` (nameHash) to `Bid[]`.
- `allNameHashes`: Array of `uint256` (all minted nameHashes; enables paginated enumeration in getNameRecords).
- `bidderNameHashes`: Maps `address` (bidder) to `uint256[]` (nameHashes with active bids; tracks for getBidderBids).
- `bidderBids`: Maps `address` to `mapping(uint256 => uint256[])` (bid indices per nameHash; enables granular retrieval).
- `totalNames`: uint256 (starts 0, ++ per mint).
- `tokenIdToNameHash`: Maps `uint256` (tokenId) to `uint256` (nameHash).
- `nameHashToTokenId`: Maps `uint256` (nameHash) to `uint256` (tokenId; quick ownerOf lookup).
- `_balances`: Maps `address` to `uint256` (owner => total token count; O(1) ERC721 balance).
- `ownerOf`: Maps `uint256` (tokenId) to `address` (owner).
- `getApproved`: Maps `uint256` (tokenId) to `address` (spender).
- `isApprovedForAll`: Maps `address` to `mapping(address => bool)` (owner => operator => approved).
- `pendingCheckins`: Array of `PendingCheckin` (queue; processed via nextProcessIndex).
- `nextProcessIndex`: uint256 (tracks processed queue position).
- `owner`: address (MailNames owner; setters/transferOwnership).
- `mailToken`: address (ERC20 token addr; owner-set).
- `mailLocker`: address (MailLocker contract addr; owner-set).
- `ALLOWANCE_PERIOD`: 365 days.
- `GRACE_PERIOD`: 30 days.
- `MAX_NAME_LENGTH`: 24.
- `MAX_STRING_LENGTH`: 1024.

## External Functions and Call Trees
### mintName(string _name)
- **Purpose**: Mints ERC721-compatible name (tokenId auto-assigned), free, with 1-year allowance.
- **Params/Interactions**: _name <=24 chars, no spaces; interacts with totalNames for unique ID.
- **Checks**: _validateName (spaces/length), name not minted (nameHash==0).
- **Internal Calls**:
  - `_stringToHash`: Generates nameHash for storage/lookup.
  - `_validateName`: Validates format/length.
- **Effects**: Initializes NameRecord (incl. tokenId/allowanceEnd), maps tokenIdToNameHash/nameHashToTokenId/ownerOf/_balances (increment), pushes to allNameHashes, emits NameMinted/Transfer(address(0), msg.sender, tokenId).

### queueCheckIn(uint256 _nameHash)
- **Purpose**: Queues checkin during grace (locks min token in MailLocker for 10y; dynamic min/wait based on current queue len).
- **Params/Interactions**: _nameHash to tokenId; transfers min wei from caller to MailNames, then full to MailLocker via depositLock (normalized amt, user, unlock=now+10y); assumes 18dec—adjust if not.
- **Checks**: Caller=owner (ownerOf[tokenId]), in grace (post-allowanceEnd, pre+grace); transfer succeeds.
- **Internal Calls**:
  - `_calculateMinRequired`: 1 * 2^queueLen (wei; escalates spam cost exponentially).
  - `_calculateWaitDuration`: 10min + 6h*queueLen, cap 2w (adds uncertainty for auctions).
  - `IERC20.transferFrom`: Pulls min from user to MailNames.
  - `MailLocker.depositLock`: Locks normalized (min/10^decimals) for user/10y (overrides prior timers).
  - Pushes PendingCheckin (hash, user, now, wait).
  - `this.advance`: Attempts process (skips if time not met).
- **Effects**: Emits QueueCheckInQueued (hash, user, minWei, wait); queue grows, min/wait rise for next—deters hording via capital lockup.

### advance()
- **Purpose**: Processes one ready checkin (external, gas-safe; callable anytime for decentralization).
- **Params/Interactions**: None; loops nothing—O(1) check/process.
- **Checks**: nextProcessIndex < len && time >= queued+wait; still owner (ownerOf[tokenId]==user).
- **Internal Calls**:
  - `_processNextCheckin`: Updates allowanceEnd=+ALLOWANCE_PERIOD if ready/eligible; emits NameCheckedIn/CheckInProcessed; ++index (depopulates queue).
- **Effects**: Advances queue; no revert on skip (graceful—retry later); invoked post-queue for immediate attempt.

### placeTokenBid(string _name, uint256 _amount, address _token)
- **Purpose**: Places ERC20 bid; auto-settles best if post-grace.
- **Params/Interactions**: _amount in token units; pre/post balance calc handles fees (receivedAmount = (after - before)/decimals); updates bidderNameHashes if new name.
- **Checks**: Name exists (tokenId!=0), _amount>0, transfer succeeds, received>0.
- **Internal Calls**:
  - `_stringToHash`: nameHash for bids/retrieval.
  - `_findBestBid`: Scans bids[] for highest ETH/oldest ERC20 (returns index/found; invoked post-grace for auto-select).
  - `_settleBid` (if expired): Triggers on bestIndex; transfers funds to old owner, calls _transfer (updates ownerOf/_balances, emits Transfer), emits BidSettled.
- **Effects**: Stores Bid in bids/bidderBids (with index), emits BidPlaced; settlement via _transfer ensures ERC721 sync without allowance reset.

### placeETHBid(string _name)
- **Purpose**: Places ETH bid; auto-settles best if post-grace (similar to token bid).
- **Params/Interactions**: msg.value as amount; updates bidderNameHashes if new.
- **Checks**: Name exists, msg.value>0.
- **Internal Calls**:
  - `_stringToHash`: nameHash.
  - `_findBestBid`: Selects best.
  - `_settleBid` (if expired): Transfers ETH to old owner, calls _transfer (updates ownerOf/_balances, emits Transfer), emits BidSettled.
- **Effects**: Stores Bid (isETH=true), emits BidPlaced; ERC721 sync on settle.

### closeBid(uint256 _nameHash, uint256 _bidIndex)
- **Purpose**: Refunds/removes bidder's bid (swap-and-pop for gas); cleans bidderNameHashes if last bid.
- **Params/Interactions**: _bidIndex from bidderBids query; updates indices post-pop.
- **Checks**: Index valid, caller=bidder.
- **Effects**: Transfers refund (ETH or token*decimals), removes from bids/bidderBids, emits BidClosed (no ERC721 impact).

### acceptBid(uint256 _nameHash, uint256 _bidIndex)
- **Purpose**: Manual settle during allowance (owner choice).
- **Params/Interactions**: _bidIndex specifies bid; bypasses best-bid logic.
- **Checks**: Caller=owner (ownerOf[tokenId]), within allowance.
- **Internal Calls**:
  - `_settleBid`: Transfers to old owner, calls _transfer (updates ownerOf/_balances, emits Transfer), emits BidSettled.
- **Effects**: Ownership transfer with ERC721 compliance, no allowance reset.

### mintSubname(string _parentName, string _subname)
- **Purpose**: Mints subname under parent (no separate tokenId; transfers with parent).
- **Params/Interactions**: _subname <=24 chars; parent via hash.
- **Checks**: _validateName (subname), caller=parent owner (ownerOf[tokenId]).
- **Internal Calls**:
  - `_stringToHash`: parentHash/subnameHash.
  - `_validateName`: Subname format/length.
- **Effects**: Pushes SubnameRecord to subnameRecords[parentHash], initializes records, emits SubnameMinted.

### transferName(uint256 _nameHash, address _newOwner)
- **Purpose**: Convenience transfer (inherits allowance/queue eligibility; subnames implicit).
- **Params/Interactions**: _nameHash resolved to tokenId.
- **Checks**: Name exists (tokenId!=0); auth via _transfer.
- **Internal Calls**:
  - `_transfer`: Verifies caller (owner/approved/operator), updates ownerOf/_balances (decrement old/increment new), clears getApproved, emits Transfer.
- **Effects**: Routes to _transfer for ERC721 compliance; pending checkins validate user on process (transfers don't cancel queue).

### transferFrom(address _from, address _to, uint256 _tokenId)
- **Purpose**: ERC721 transfer (verifies _from==ownerOf; subnames implicit).
- **Params/Interactions**: _tokenId (0+); clears getApproved.
- **Checks**: _from==ownerOf[_tokenId], _to!=0; auth via _transfer.
- **Internal Calls**:
  - `_transfer`: Updates ownerOf/_balances, emits Transfer.
- **Effects**: Standard ERC721 transfer, inherits allowance.

### approve(address _to, uint256 _tokenId)
- **Purpose**: Approves spender for token transfer.
- **Params/Interactions**: _tokenId specific; resolves nameHash for validity.
- **Checks**: Caller=owner (ownerOf) or operator (isApprovedForAll), tokenId valid (nameHash!=0).
- **Effects**: Sets getApproved[_tokenId]=_to, emits Approval.

### setApprovalForAll(address _operator, bool _approved)
- **Purpose**: Batch approval for operator.
- **Params/Interactions**: Global for caller’s tokens.
- **Effects**: Updates isApprovedForAll[msg.sender][_operator], emits ApprovalForAll.

### safeTransferFrom(address _from, address _to, uint256 _tokenId, bytes memory _data)
- **Purpose**: Safe ERC721 transfer (verifies _from==ownerOf; supports _data for hooks).
- **Params/Interactions**: _tokenId (0+); checks if _to is contract via _isContract (assembly extcodesize>0), calls onERC721Received if so (try/catch reverts on failure/mismatch).
- **Checks**: _from==ownerOf[_tokenId], tokenId valid (nameHash!=0), receiver hook succeeds.
- **Internal Calls**:
  - `_transfer`: Updates ownerOf/_balances, emits Transfer (pre-hook).
  - `_checkOnERC721Received`: Invokes IERC721Receiver(_to).onERC721Received(msg.sender, _from, _tokenId, _data) post-transfer; reverts if non-compliant (ensures atomicity—transfer only if hook ok).
  - `_isContract`: Determines if _to needs hook (size>0).
- **Effects**: Full ERC721 safe transfer with receiver verification; subnames implicit, inherits allowance.

### balanceOf(address _owner)
- **Purpose**: Returns owner's name count (ERC721).
- **Params/Interactions**: O(1) via _balances counter.
- **Checks**: _owner !=0.
- **Returns**: uint256 count.

### setCustomRecord(uint256 _nameHash, uint256 _index, CustomRecord _record)
- **Purpose**: Sets name record (index 0-4).
- **Params/Interactions**: _record strings <=1024 chars via _validateRecord; _nameHash to tokenId.
- **Checks**: Caller=owner (ownerOf[tokenId]), _index<5, tokenId!=0.
- **Internal Calls**:
  - `_validateRecord`: Length checks on text/resolver/contentHash.
- **Effects**: Updates customRecords[_index], emits RecordsUpdated.

### setSubnameRecord(uint256 _parentHash, uint256 _subnameIndex, uint256 _recordIndex, CustomRecord _record)
- **Purpose**: Sets subname record (under parent).
- **Params/Interactions**: Indices for array access; _record validated; parentHash to tokenId.
- **Checks**: Caller=parent owner (ownerOf[tokenId]), valid indices, _record lengths, tokenId!=0.
- **Internal Calls**:
  - `_validateRecord`: String limits.
- **Effects**: Updates subnameRecords[parentHash][subnameIndex].customRecords[_recordIndex], emits RecordsUpdated.

### setMailToken(address _mailToken) [onlyOwner]
- **Purpose**: Sets ERC20 token for checkin locks.
- **Effects**: Updates mailToken; call post-deploy.

### setMailLocker(address _mailLocker) [onlyOwner]
- **Purpose**: Sets MailLocker contract addr.
- **Effects**: Updates mailLocker; call post-deploy.

### transferOwnership(address _newOwner) [onlyOwner]
- **Purpose**: Transfers ownership to new addr.
- **Checks**: _newOwner !=0.
- **Effects**: Sets owner, emits OwnershipTransferred.

### getNameRecords(uint256 step, uint256 maxIterations)
- **Purpose**: Paginated name query (top-down via allNameHashes/step).
- **Returns**: NameRecord[] (sliced from allNameHashes).

### getSubnameID(string _parentName, string _subname)
- **Purpose**: Finds subname index.
- **Internal Calls**:
  - `_stringToHash`: Hashes for match.
- **Returns**: (index, found).

### getSubRecords(string _parentName, string _subname)
- **Purpose**: Retrieves subname records.
- **Internal Calls**:
  - `_stringToHash`: Parent hash.
  - `this.getSubnameID`: Index lookup (external call for view).
- **Returns**: CustomRecord[5]; reverts if not found.

### getSubnames(string _parentName, uint256 step, uint256 maxIterations)
- **Purpose**: Paginated subname strings.
- **Internal Calls**:
  - `_stringToHash`: Parent hash.
- **Returns**: string[] (sliced via step/end).

### getNameBids(string _name, uint256 maxIterations)
- **Purpose**: Bids for name (capped).
- **Internal Calls**:
  - `_stringToHash`: nameHash.
- **Returns**: Bid[] (limited length).

### getBidderNameBids(address _bidder, string _name)
- **Purpose**: Bidder's bids for specific name (via bidderBids indices).
- **Internal Calls**:
  - `_stringToHash`: nameHash.
- **Returns**: Bid[].

### getBidderBids(address _bidder, uint256 maxIterations)
- **Purpose**: All bidder's bids across names (capped by bidderNameHashes).
- **Returns**: (uint256[] nameHashes, Bid[][]); iterates bidderNameHashes for actual keys.

### ownerOf(uint256 _tokenId) [public mapping]
- **Purpose**: ERC721 owner query.
- **Returns**: address.

## Internal Functions
- **_stringToHash(string _str)**: keccak256(abi.encodePacked(_str)); supports mintName/mintSubname/place*Bid/get* views by enabling hash-based storage/retrieval without string gas.
- **_validateName(string _name)**: Checks bytes.length <=24 && no spaces && >0; gates mintName/mintSubname for format enforcement.
- **_findBestBid(uint256 _nameHash)**: Loops bids[_nameHash] for max ETH amount (tracks highest/index) or min timestamp ERC20 (tracks oldest/index), prefers ETH if tied (returns best index/found); invoked by place*Bid post-grace for auto-select in _settleBid, ensuring fair settlement without external oracles.
- **_settleBid(uint256 _nameHash, uint256 _bidIndex)**: Resolves bid from bids[], transfers to old owner (ETH direct/token*decimals), calls _transfer (updates ownerOf/_balances, emits Transfer); called by place*Bid (auto via _findBestBid) or acceptBid (manual)—syncs ERC721 on all ownership changes, no allowance reset.
- **_transfer(uint256 _tokenId, address _to)**: Central auth/update for transfers (verifies caller/owner/approved/operator, updates ownerOf/_balances, clears getApproved, emits Transfer); invoked by transferName/transferFrom/safeTransferFrom/acceptBid (via _settleBid)/place*Bid (via _settleBid) for consistent ERC721 handling.
- **_validateRecord(CustomRecord _record)**: bytes.length <=1024 for text/resolver/contentHash; used by set*Record to prevent gas bombs in storage.
- **_checkOnERC721Received(address _to, address _from, uint256 _tokenId, bytes memory _data)**: Called by safeTransferFrom post-_transfer; uses try/catch to invoke IERC721Receiver hook on contract _to, reverts on failure/non-match (ensures safe atomicity; graceful revert only on hook error, not full tx rollback).
- **_isContract(address _account)**: Assembly extcodesize>0 check; supports _checkOnERC721Received by identifying contract recipients needing hooks, avoiding unnecessary calls to EOAs.
- **_calculateMinRequired(uint256 _queueLen)**: 1 * 2^_queueLen (wei; fixed per queue, exponential anti-spam).
- **_calculateWaitDuration(uint256 _queueLen)**: 10min + 6h*_queueLen, min(2w) (fixed per queue, adds auction tension).
- **_processNextCheckin()**: If ready (time/user check), updates allowanceEnd, emits; ++nextProcessIndex (O(1), depopulates via index).

## Key Insights
- **ERC721 Integration**: tokenId enables standard transfers/approvals; _balances O(1) counter avoids loops; nameHashToTokenId speeds owner checks. Subnames bundle with parents—no separate tokens, reducing complexity/gas. SafeTransferFrom now atomic with hooks via _checkOnERC721Received/_isContract, preventing stuck transfers to non-compliant contracts.
- **Queue Mechanics**: queueCheckIn locks via MailLocker (deposit flows through MailNames; multi-deposits indexed); advance processes one O(1)—decentralized, no DoS (anyone calls); transfers don't cancel pending (validates user on process); min/wait fixed at queue (fluctuates for new based on len, not retroactive).
- **Settlement Dual-Use**: _settleBid handles manual (acceptBid, during allowance) vs. auto (place*Bid post-grace via _findBestBid); routes through _transfer for uniform ERC721 events/fund xfers, inherits allowance to enforce queue mechanics.
- **Fee Handling**: placeTokenBid computes receivedAmount via balance delta/decimals, storing accurate bid.amount for refunds/settles—robust for tax tokens.
- **DoS/Gas Mitigations**: Swap-and-pop in closeBid; paginated views (step/maxIterations) for arrays; allNameHashes/bidderNameHashes enable efficient enumeration without hash scans; no fixed loops; _isContract assembly for cheap contract detection; queue advance O(1).
- **Ownership Sync**: Single source via ownerOf[tokenId]; all functions resolve via nameHashToTokenId for quick auth, transfers via _transfer prevent inconsistencies.
- **String Limits**: Enforced at mint/set (24/1024 chars) to cap gas; keccak256 on short names cheap.
- **Bid Granularity**: bidderBids indices + bidderNameHashes enable O(1) retrieval in getBidderNameBids/getBidderBids without full scans; auto-clean on closeBid.
- **Grace/Queue-Settle**: Prevents premature claims; _findBestBid prioritizes ETH value > ERC20 age for auction fairness; no renewal on transfer/settle avoids spam; queue adds 10y lock cost for commitment.
- **Events**: Standard ERC721 (Transfer/Approval/ApprovalForAll) + custom for bids/records/queue; no emits in views.
- **Degradation**: Reverts only on critical (e.g., invalid auth/transfer fail); descriptive strings; safeTransferFrom uses try/catch for hook failures without broader impact; advance skips gracefully.

## Notes
- No ReentrancyGuard needed (no recursive calls); transfers post-state updates.
- All on-chain; graceful via checks, try/catch in hooks.
- Ownership: transferOwnership for handoff; MailLocker mirrors.

## MailLocker
**Version**: 0.0.2  
**Date**: 05/10/2025  

### Overview
Separate locker for MailToken (ERC20) deposits from MailNames queues (10y unlock per deposit; multi-indexed for users). Owner-set post-deploy; handles normalized amts (no dec in storage).

### Structs
- **Deposit**: 
  - `amount`: uint256 (normalized, no dec).
  - `unlockTime`: uint256 (timestamp).

### State Variables
- `owner`: address (setter/transferOwnership).
- `mailToken`: IERC20 (owner-set).
- `mailNames`: address (owner-set; only caller).
- `userDeposits`: Maps `address` (user) to `Deposit[]` (indexed array).

### External Functions and Call Trees
#### depositLock(uint256 _normalizedAmount, address _user, uint256 _unlockTime) [only MailNames]
- **Purpose**: Locks new deposit (pulls full from MailNames).
- **Params/Interactions**: Normalized amt (MailNames sends full=amt*10^dec); pushes to userDeposits[_user].
- **Checks**: msg.sender=mailNames; transfer succeeds.
- **Effects**: Emits DepositLocked (user, index, amt, unlock); overrides prior timers? No—separate entries.

#### withdraw(uint256 _index)
- **Purpose**: Withdraws specific deposit (swap-pop for gas).
- **Params/Interactions**: _index in user's array; transfers full=amt*10^dec.
- **Checks**: _index valid, time >= unlockTime.
- **Effects**: Swap/pops array, emits DepositWithdrawn (user, index, amt); resets nothing global.

#### setMailToken(address _mailToken) [onlyOwner]
- **Purpose**: Sets token.
- **Effects**: Updates mailToken.

#### setMailNames(address _mailNames) [onlyOwner]
- **Purpose**: Sets MailNames.
- **Effects**: Updates mailNames.

#### transferOwnership(address _newOwner) [onlyOwner]
- **Purpose**: Transfers ownership.
- **Checks**: _newOwner !=0.
- **Effects**: Sets owner, emits OwnershipTransferred.

#### getUserDeposits(address _user, uint256 _step, uint256 _maxIterations)
- **Purpose**: Paginated deposits view.
- **Returns**: Deposit[] (sliced from userDeposits[_user]).

#### getTotalLocked(address _user)
- **Purpose**: Sums user's locked amts.
- **Returns**: uint256 total (loops array—gas ok for views).

### Internal Functions
None.

### Key Insights
- **Multi-Deposits**: Array per user enables separate 10y locks (no override); withdraw by index for precision.
- **Normalization**: Storage/returns sans dec (cheap); transfers use dec for full wei.
- **Gas/DoS**: Swap-pop on withdraw; paginated views; only MailNames deposits.
- **Events**: DepositLocked/Withdrawn for tracking.
- **Degradation**: Reverts on invalid transfer/time; no try/catch needed.
