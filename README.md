# MailNames
**Version**: 0.0.4
**Date**: 04/10/2025  
**SPDX-License-Identifier**: BSL 1.1 - Peng Protocol 2025  
**Solidity Version**: ^0.8.2  

## Overview
`MailNames` is a decentralized domain name system inspired by ENS with ERC721 compatibility, enabling free name minting (indexed by tokenId from 0 upward) with a 1-year allowance and 30-day grace period for check-ins. Post-grace, highest ETH bid or oldest ERC20 bid claims via auto-settlement. Supports subnames (implicitly transferred with parents) with custom records (strings <=1024 chars), controlled by parent owners. Bidding in ETH/ERC20 with fee-on-transfer handling. Names limited to 24 chars. Primary for Chainmail (link unavailable). Ownership unified under ERC721 `ownerOf`; transferred names inherit allowance.

## Structs
- **NameRecord**: Stores domain details.
  - `name`: String (no spaces, <=24 chars).
  - `nameHash`: keccak256 hash of name.
  - `tokenId`: ERC721 token ID (auto-incremented on mint).
  - `allowanceEnd`: Timestamp when allowance expires (set on mint/checkIn only).
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

### checkIn(uint256 _nameHash)
- **Purpose**: Extends allowance by 1 year during grace period (no ERC721 impact).
- **Params/Interactions**: _nameHash resolved to tokenId via nameHashToTokenId.
- **Checks**: Caller is owner (ownerOf[tokenId]), within/after grace.
- **Effects**: Updates allowanceEnd, emits NameCheckedIn.

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
- **Purpose**: Convenience transfer (inherits allowance; subnames implicit).
- **Params/Interactions**: _nameHash resolved to tokenId.
- **Checks**: Name exists (tokenId!=0); auth via _transfer.
- **Internal Calls**:
  - `_transfer`: Verifies caller (owner/approved/operator), updates ownerOf/_balances (decrement old/increment new), clears getApproved, emits Transfer.
- **Effects**: Routes to _transfer for ERC721 compliance.

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

### safeTransferFrom(address _from, address _to, uint256 _tokenId, bytes memory /*_data*/)
- **Purpose**: Safe ERC721 transfer (stubs _data; verifies _from==ownerOf).
- **Params/Interactions**: Delegates to _transfer.
- **Checks**: _from==ownerOf[_tokenId], tokenId valid.
- **Internal Calls**:
  - `_transfer`: Updates ownerOf/_balances, emits Transfer.
- **Effects**: Standard safe transfer; future: add ERC721Receiver check.

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

## Key Insights
- **ERC721 Integration**: tokenId enables standard transfers/approvals; _balances O(1) counter avoids loops; nameHashToTokenId speeds owner checks. Subnames bundle with parents—no separate tokens, reducing complexity/gas.
- **Settlement Dual-Use**: _settleBid handles manual (acceptBid, during allowance) vs. auto (place*Bid post-grace via _findBestBid); routes through _transfer for uniform ERC721 events/fund xfers, inherits allowance to enforce checkIn mechanics.
- **Fee Handling**: placeTokenBid computes receivedAmount via balance delta/decimals, storing accurate bid.amount for refunds/settles—robust for tax tokens.
- **DoS/Gas Mitigations**: Swap-and-pop in closeBid; paginated views (step/maxIterations) for arrays; allNameHashes/bidderNameHashes enable efficient enumeration without hash scans; no fixed loops.
- **Ownership Sync**: Single source via ownerOf[tokenId]; all functions resolve via nameHashToTokenId for quick auth, transfers via _transfer prevent inconsistencies.
- **String Limits**: Enforced at mint/set (24/1024 chars) to cap gas; keccak256 on short names cheap.
- **Bid Granularity**: bidderBids indices + bidderNameHashes enable O(1) retrieval in getBidderNameBids/getBidderBids without full scans; auto-clean on closeBid.
- **Grace/Auto-Settle**: Prevents premature claims; _findBestBid prioritizes ETH value > ERC20 age for auction fairness; no renewal on transfer/settle avoids spam.
- **Events**: Standard ERC721 (Transfer/Approval/ApprovalForAll) + custom for bids/records; no emits in views.
- **Degradation**: Reverts only on critical (e.g., invalid auth/transfer fail); descriptive strings.

## Notes
- No ReentrancyGuard needed (no recursive calls); transfers post-state updates.
- All on-chain; graceful via checks, no try/catch.
- Removed retainerNames/getRetainerNames for gas; use Transfer events for off-chain owner lists.