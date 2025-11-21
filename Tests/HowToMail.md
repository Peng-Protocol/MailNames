# Running MailNames Tests in Remix

## Prerequisites
- Ensure `MailNames.sol`, `MailLocker.sol`, `MailMarket.sol`, `MockMAILToken.sol`, `MockMailTester.sol`, and `MailTests.sol` are in your Remix workspace.
- Place core contracts in main directory.
- Place mocks and `MailTests.sol` in `./Tests`.

## Steps
1. Open Remix [https://remix.ethereum.org](https://remix.ethereum.org).
2. Upload all contracts to the specified directories.
3. In "Solidity Compiler", select `^0.8.2` and compile all.
4. In "Deploy & Run Transactions", select **Remix VM**.
5. Ensure default account has 100 ETH.
6. **Deploy the mail system contracts first** (in any order):
   - Deploy `MailNames`
   - Deploy `MailLocker`
   - Deploy `MailMarket`
7. Deploy `MailTests` using the default account.
8. Call `setMailContracts(namesAddr, lockerAddr, marketAddr)`:
   - Paste the **exact addresses** of the deployed `MailNames`, `MailLocker`, `MailMarket` contracts.
   - This will:
     - Assign the instances to `MailTests`
     - Configure token and cross-references
   - Ownership transfer is **not** attempted; manually transfer ownership of subject contracts (`MailNames`, `MailLocker`, `MailMarket`) to `MailTests` **before** calling this function.
9. Call `initiateTesters()` with **20 ETH** (value field).
10. **Path 1 – Basic Lifecycle**:
    - `p1_1TestMint()`
    - `p1_2TestSubname()`
    - `p1_3TestCustomRecord()`
    - `p1_4TestTransfer()`
    - `p1_5WarpToExpiration()`
    - `p1_6TestQueueCheckIn()`
    - `p1_7TestProcessCheckIn()`
    - `p1_8TestLockerView()`
11. **Path 2a – Bidding & Settlement (Pre-Expiration)**:
    - `p2a_1TestPreExpirationBidSetup()`
    - `p2a_2TestPreExpirationTokenBid()`
    - `p2a_3TestAcceptTokenBidPreExpiration()`
12. **Path 2b – Bidding & Settlement (Post-Expiration)**:
    - `p2b_1TestPostExpirationSetup()`
    - `p2b_2TestPostExpirationETHBid()`
    - `p2b_3TestQueueSettlement()`
    - `p2b_4TestPostGraceSettlement()`
13. **Sad Path Tests** (Requires redeployment of subject contracts and `MailTests`):
    - `s1_MintDuplicateName()`
    - `s2_MintInvalidName()`
    - `s3_NonOwnerTransfer()`
    - `s4_CheckInSecondBeforeExpiration()`
    - `s5_BidWithoutMAIL()`
    - `s6_BidAcceptNotOwner()`
    - `s7_ProcessSettlementEarly()`
    - `s8_DoubleCheckIn()`
    - `s9_WithdrawLockedMAIL()`
    - `s10_PlaceBidDisallowedToken()`
    - `s11_SubnameNonOwner()`
    - `s12_SetRecordNonOwner()`

---

## Objectives (Happy Paths)

### 7. `initiateTesters()`
- **Purpose**: Deploy 4 proxy tester contracts to simulate real users. 
- **Action**: Each tester receives:
  - 4 ETH (for gas/bids)
  - **100 MAIL** (18 decimals)
  - **100 MOCK** (6 decimals)
- **Expected Outcome**:
  - 4 `testers[i]` deployed successfully
  - `mailToken.balanceOf(testers[i]) == 100e18`
  - `mockERC20.balanceOf(testers[i]) == 100e6`
- **Why It Matters**: Limited tokens force precise math and prevent overflow assumptions.

---

### 8. **Path 1 – Name Lifecycle (State is Chained)**
Each step builds on the previous one using shared state (`p1NameHash`, `p1TokenId`).

- **`p1_1TestMint()`**
  - **Action**: tester[0] mints "alice" (free, 1-year allowance)
  - **Expected**:
    - `totalNames == 1`
    - `ownerOf(tokenId) == tester[0]`
    - `allowanceEnd = block.timestamp + 365 days`
    - `graceEnd = allowanceEnd + 7 days`

- **`p1_2TestSubname()`**
  - **Action**: Mint subname "mail" under "alice"
  - **Expected**: `getSubnameID("alice", "mail")` returns valid index

- **`p1_3TestCustomRecord()`**
  - **Action**: Set record[0]: `"Hello"`, IPFS, content hash, TTL
  - **Expected**: `getNameRecords("alice").customRecords[0].text == "Hello"`

- **`p1_4TestTransfer()`**
  - **Action**: Transfer "alice" to tester[1]
  - **Expected**: `ownerOf(tokenId) == tester[1]`

- **`p1_5WarpToExpiration()`**
  - **Action**: `names.warp()` past allowance
  - **Expected**: `block.timestamp > allowanceEnd`

- **`p1_6TestQueueCheckIn()`**
  - **Action**: tester[1] queues renewal (requires MAIL)
  - **Expected**:
    - `pendingCheckins[0]` contains correct nameHash and user
    - `locker.getTotalLocked(tester[1]) > 0`

- **`p1_7TestProcessCheckIn()`**
  - **Action**: Warp 11 minutes → call `advance()`
  - **Expected**: `allowanceEnd` extended by 1 year

- **`p1_8TestLockerView()`**
  - **Action**: Inspect locked deposit
  - **Expected**:
    - `getUserDeposits(tester[1], ...)` shows 10-year lock
    - `getTotalLocked(tester[1])` matches deposit

---

### 9. **Path 2a – Bidding & Settlement (Pre-Expiration, State is Chained)**
Builds on new name "bob".

- **`p2a_1TestPreExpirationBidSetup()`**
  - **Action**: Mint "bob", warp to just before expiration
  - **Expected**: Name active, ready for pre-expiration bids

- **`p2a_2TestPreExpirationTokenBid()`**
  - **Action**: tester[3] bids **10 MOCK** (10% balance, 6 decimals)
  - **Expected**: Bid stored under `mockERC20`

- **`p2a_3TestAcceptTokenBidPreExpiration()`**
  - **Action**: Owner accepts token bid via `acceptMarketBid`
  - **Expected**: Ownership → bidder, funds to old owner

---

### 10. **Path 2b – Bidding & Settlement (Post-Expiration, State is Chained)**
Builds on new name "charlie".

- **`p2b_1TestPostExpirationSetup()`**
  - **Action**: Mint "charlie", warp past grace
  - **Expected**: Name expired, ready for takeover

- **`p2b_2TestPostExpirationETHBid()`**
  - **Action**: Place 2 ETH bid post-grace
  - **Expected**: Bid queued for settlement

- **`p2b_3TestQueueSettlement()`**
  - **Action**:  Checks bid state.
  - **Expected**: Active bids queued

- **`p2b_4TestPostGraceSettlement()`**
  - **Action**: Warp 3 weeks → `processSettlement(index)`
  - **Expected**: Ownership transferred to highest bidder
  
### 11. **Sad Paths**
Attempts to call various functions incorrectly, expecting them to fail. 

---

## Notes & Tips
- All calls use default account. 
- **Time Control**:
  - All contracts use `_now()` → `names.warp()` affects **all** timing.
  - Check-ins: **10 min min, 2 weeks max** based on queue length.
  - Settlements: **3 weeks** post-grace.

- **Set gas limit ≥ 10M**
- **View functions**:
  - `getNameRecords(name)`
  - `getPendingSettlements(name, step, max)`
  - `getUserDeposits(user, step, max)`
  - `getNameBids(name, isETH, token)`

- **Ownership Transfer**:
  - `setMailContracts()` **does not** transfer ownership of `MailNames`, `MailLocker`, `MailMarket` to `MailTests`.
  - Perform manually before calling.
