# MailNames
**Version**: 0.0.2  
**Date**: 03/10/2025  
**SPDX-License-Identifier**: BSL 1.1 - Peng Protocol 2025  
**Solidity Version**: ^0.8.2  

## Overview
`MailNames` is a decentralized domain name system inspired by ENS, enabling free name minting with a 1-year allowance and a 30-day grace period for check-ins. Post-grace period, the highest ETH bid or oldest ERC20 bid claims the name if no check-in occurs. Supports subnames with custom records, controlled by parent name retainers, and bidding in ETH or ERC20 tokens with balance checks.
It is the primary name system for Chainmail (link unavailable).  

## Structs
- **NameRecord**: Stores domain details.
  - `name`: String (no spaces).
  - `nameHash`: keccak256 hash of name.
  - `retainer`: Current holder address.
  - `allowanceEnd`: Timestamp when allowance expires.
  - `customRecords`: Array of 5 `CustomRecord` structs.
- **SubnameRecord**: Stores subname details.
  - `parentHash`: Parent name's hash.
  - `subname`: Subname string.
  - `subnameHash`: keccak256 hash of subname.
  - `customRecords`: Array of 5 `CustomRecord` structs.
- **Bid**: Stores bid details.
  - `bidder`: Bidder address.
  - `amount`: Bid amount (ETH or token).
  - `timestamp`: Bid placement time.
  - `isETH`: True if ETH, false for ERC20.
  - `token`: ERC20 token address (if not ETH).
- **CustomRecord**: Stores metadata for names/subnames.
  - `text`: General text (e.g., description).
  - `resolver`: Resolver info.
  - `contentHash`: Content hash (e.g., IPFS).
  - `ttl`: Time-to-live.
  - `targetAddress`: Associated address.

## State Variables
- `nameRecords`: Maps `uint256` (nameHash) to `NameRecord`.
- `subnameRecords`: Maps `uint256` (parentHash) to `SubnameRecord[]`.
- `bids`: Maps `uint256` (nameHash) to `Bid[]`.
- `retainerNames`: Maps `address` to `uint256[]` (nameHashes owned by retainer).
- `bidderBids`: Maps `address` to `mapping(uint256 => uint256[])` (bid indices per nameHash).
- `ALLOWANCE_PERIOD`: 365 days.
- `GRACE_PERIOD`: 30 days.

## External Functions and Call Trees
### mintName(string _name)
- **Purpose**: Mints a name, free, with a 1-year allowance.
- **Checks**: Validates no spaces (`_validateName`), ensures name isn't minted.
- **Internal Calls**:
  - `_stringToHash`: Generates name hash.
  - `_validateName`: Checks for spaces.
- **Effects**: Sets `NameRecord`, adds to `retainerNames`, emits `NameMinted`.

### checkIn(uint256 _nameHash)
- **Purpose**: Extends allowance by 1 year during grace period.
- **Checks**: Verifies caller is retainer, within grace period, after allowance.
- **Effects**: Updates `allowanceEnd`, emits `NameCheckedIn`.

### placeTokenBid(string _name, uint256 _amount, address _token)
- **Purpose**: Places an ERC20 token bid with fee-on-transfer support.
- **Checks**: Ensures name exists, amount > 0, calculates received amount.
- **Internal Calls**:
  - `_stringToHash`: Generates name hash.
  - `_findBestBid`: Selects highest ETH or oldest ERC20 bid.
  - `_settleBid`: Settles bid if grace period expired.
- **Effects**: Transfers tokens, adds bid to `bids` and `bidderBids`, emits `BidPlaced`.

### placeETHBid(string _name)
- **Purpose**: Places an ETH bid.
- **Checks**: Ensures name exists, amount > 0, balance checks pass.
- **Internal Calls**:
  - `_stringToHash`: Generates name hash.
  - `_findBestBid`: Selects highest ETH or oldest ERC20 bid.
  - `_settleBid`: Settles bid if grace period expired.
- **Effects**: Adds bid to `bids` and `bidderBids`, emits `BidPlaced`.

### closeBid(uint256 _nameHash, uint256 _bidIndex)
- **Purpose**: Refunds and removes a bid using swap-and-pop.
- **Checks**: Validates bid index, caller is bidder.
- **Effects**: Refunds ETH/token, updates `bids` and `bidderBids`, emits `BidClosed`.

### acceptBid(uint256 _nameHash, uint256 _bidIndex)
- **Purpose**: Allows retainer to accept a bid during allowance period.
- **Checks**: Verifies caller is retainer, within allowance period.
- **Internal Calls**:
  - `_settleBid`: Transfers ownership and funds.
- **Effects**: Updates `NameRecord`, emits `BidSettled`.

### mintSubname(string _parentName, string _subname)
- **Purpose**: Mints a subname under a parent name.
- **Checks**: Validates subname, caller is parent retainer.
- **Internal Calls**:
  - `_stringToHash`: Generates hashes.
  - `_validateName`: Checks subname for spaces.
- **Effects**: Adds `SubnameRecord`, emits `SubnameMinted`.

### transferName(uint256 _nameHash, address _newRetainer)
- **Purpose**: Transfers name ownership.
- **Checks**: Verifies caller is retainer, valid address.
- **Effects**: Updates `retainerNames` and `NameRecord`, emits `NameTransferred`.

### setCustomRecord(uint256 _nameHash, uint256 _index, CustomRecord _record)
- **Purpose**: Sets a custom record for a name.
- **Checks**: Verifies caller is retainer, valid index (< 5).
- **Effects**: Updates `customRecords[_index]`, emits `RecordsUpdated`.

### setSubnameRecord(uint256 _parentHash, uint256 _subnameIndex, uint256 _recordIndex, CustomRecord _record)
- **Purpose**: Sets a custom record for a subname.
- **Checks**: Verifies caller is parent retainer, valid indices.
- **Effects**: Updates `customRecords[_recordIndex]`, emits `RecordsUpdated`.

### getNameRecords(uint256 step, uint256 maxIterations)
- **Purpose**: Returns name records starting from `step`.
- **Internal Calls**: None.
- **Returns**: Array of `NameRecord`.

### getSubRecords(string _parentName, string _subname)
- **Purpose**: Returns custom records for a subname.
- **Internal Calls**:
  - `_stringToHash`: Generates parent hash.
  - `this.getSubnameID`: Gets subname index.
- **Returns**: Array of 5 `CustomRecord`.

### getSubnames(string _parentName, uint256 step, uint256 maxIterations)
- **Purpose**: Returns subname strings with pagination.
- **Internal Calls**:
  - `_stringToHash`: Generates parent hash.
- **Returns**: Array of subname strings.

### getSubnameID(string _parentName, string _subname)
- **Purpose**: Returns subname index under a parent name.
- **Internal Calls**:
  - `_stringToHash`: Generates hashes.
- **Returns**: Subname index, boolean if found.

### getNameBids(string _name, uint256 maxIterations)
- **Purpose**: Returns bids for a name.
- **Internal Calls**:
  - `_stringToHash`: Generates name hash.
- **Returns**: Array of `Bid`.

### getRetainerNames(address _retainer, uint256 maxIterations)
- **Purpose**: Returns names retained by an address using `retainerNames`.
- **Internal Calls**: None.
- **Returns**: Arrays of `nameHashes` and `NameRecord`.

### getBidderNameBids(address _bidder, string _name)
- **Purpose**: Returns bids by a bidder for a specific name using `bidderBids`.
- **Internal Calls**:
  - `_stringToHash`: Generates name hash.
- **Returns**: Array of `Bid`.

### getBidderBids(address _bidder, uint256 maxIterations)
- **Purpose**: Returns bids placed by an address using `bidderBids`.
- **Internal Calls**: None.
- **Returns**: Arrays of `nameHashes` and `Bid[]`.

## Internal Functions
- **_stringToHash(string _str)**: Generates keccak256 hash. Used by `mintName`, `mintSubname`, `placeTokenBid`, `placeETHBid`, `getSubRecords`, `getNameBids`, `getSubnameID`, `getSubnames`, `getBidderNameBids`.
- **_validateName(string _name)**: Checks for spaces. Used by `mintName`, `mintSubname`.
- **_findBestBid(uint256 _nameHash)**: Finds highest ETH or oldest ERC20 bid. Used by `placeTokenBid`, `placeETHBid`.
- **_settleBid(uint256 _nameHash, uint256 _bidIndex)**: Transfers ownership and funds. Used by `placeTokenBid`, `placeETHBid`, `acceptBid`.

## Key Insights
- **Bidding Safety**: Pre/post balance checks in `placeTokenBid` and `placeETHBid` ensure correct transfers. Fee-on-transfer tokens supported by calculating received amount.
- **DoS Mitigation**: `closeBid` uses swap-and-pop to prevent gas-intensive array shifts.
- **Gas Optimization**: `retainerNames` and `bidderBids` mappings reduce gas for `getRetainerNames`, `getBidderBids`, and `getBidderNameBids`, avoiding unbounded loops.
- **Granular Bidding**: `getBidderNameBids` provides efficient retrieval of a bidder's bids for a specific name.
- **Bid Persistence**: Bids persist after settlement for manual refunds (`closeBid`) or acceptance (`acceptBid`).
- **Subname Control**: Parent name retainers manage subnames via `mintSubname` and `setSubnameRecord`.
- **Grace Period**: Check-ins restricted to 30-day grace period, preventing premature settlements.
- **Custom Records**: Names and subnames support 5 records, set individually (e.g., IPFS hash).
- **Pagination**: `getSubnames`, `getNameRecords`, `getRetainerNames`, `getBidderBids` use `step` and `maxIterations` for efficient queries.
- **ENS Inspiration**: Supports name transfers, subnames, and custom records (text, resolver, contentHash, ttl, targetAddress).

## Notes
- Functions degrade gracefully with descriptive revert messages.
- No off-chain dependencies; all operations on-chain.