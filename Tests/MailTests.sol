// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// File Version: 0.0.2 (08/11/2025)
// Changelog Summary:
// - 08/11/2025: Removed internal deployment of MailNames, MailLocker, MailMarket. Added setMailContracts() to accept pre-deployed instances.
// - 08/11/2025: Ownership transfer now attempted during setMailContracts() via inline interfaces. Fallback comment added if not possible.
// - 08/11/2025: _configureContracts() now only configures mailToken and mockERC20; mail system contracts are assumed configured externally.
// - 08/11/2025: Added require checks for non-zero addresses in setMailContracts().

import "./MockMAILToken.sol";
import "./MockMailTester.sol";

// Inline interfaces to avoid import bloat
interface MailNames {
    function mailToken() external view returns (address);
    function mailLocker() external view returns (address);
    function mailMarket() external view returns (address);
    function setMailToken(address) external;
    function setMailLocker(address) external;
    function setMailMarket(address) external;
    function warp(uint256) external;
    function currentTime() external view returns (uint256);
    function advance() external;
    function totalNames() external view returns (uint256);
    function ownerOf(uint256) external view returns (address);
    function nameHashToTokenId(uint256) external view returns (uint256);
    function getNameRecords(string memory) external view returns (NameRecord memory);
    function pendingCheckins(uint256) external view returns (uint256, address, uint256, uint256);
    function getSubnameID(string memory, string memory) external view returns (uint256, bool);
    function processSettlement(uint256) external;
    function getPendingSettlements(string memory, uint256, uint256) external view returns (PendingSettlement[] memory);
    function getSettlementById(uint256) external view returns (PendingSettlement memory);

    struct NameRecord {
        string name;
        uint256 nameHash;
        uint256 tokenId;
        uint256 allowanceEnd;
        uint256 graceEnd;
        CustomRecord[5] customRecords;
    }

    struct CustomRecord {
        string text;
        string resolver;
        string contentHash;
        uint256 ttl;
        address targetAddress;
    }

    struct PendingSettlement {
        uint256 nameHash;
        uint256 bidIndex;
        bool isETH;
        address token;
        uint256 queueTime;
    }
}

interface MailLocker {
    function mailToken() external view returns (address);
    function mailNames() external view returns (address);
    function setMailToken(address) external;
    function setMailNames(address) external;
    function getUserDeposits(address, uint256, uint256) external view returns (Deposit[] memory);
    function getTotalLocked(address) external view returns (uint256);

    struct Deposit {
        uint256 amount;
        uint256 unlockTime;
    }
}

interface MailMarket {
    function mailToken() external view returns (address);
    function mailNames() external view returns (address);
    function tokenCounts(address) external view returns (uint256);
    function setMailToken(address) external;
    function setMailNames(address) external;
    function addAllowedToken(address) external;
    function getNameBids(string memory, bool, address) external view returns (Bid[100] memory);

    struct Bid {
        address bidder;
        uint256 amount;
        uint256 timestamp;
    }
}
    
contract MailTests {
    MailNames public names;
    MailLocker public locker;
    MailMarket public market;
    MockMAILToken public mailToken;
    MockMAILToken public mockERC20;
    MockMailTester[4] public testers;
    address public tester;

    uint256 public constant ONE_YEAR = 365 days;
    uint256 public constant GRACE = 7 days;
    uint256 public constant THREE_WEEKS = 21 days;
    uint256 public constant TEN_YEARS = 3650 days;

    // --- p1 state ---
    uint256 public p1NameHash;
    uint256 public p1TokenId;

    // --- p2 state ---
    uint256 public p2NameHash;
    uint256 public p2TokenId;

    event MailContractsSet(address names, address locker, address market);
    event OwnershipTransferFailed(address target, string reason);

    constructor() {
        tester = msg.sender;
        _deployMocks();
        _configureMocks();
    }

    // --- Deploy only mocks (MAIL and ERC20) ---
    function _deployMocks() internal {
        mailToken = new MockMAILToken();
        mockERC20 = new MockMAILToken();
    }

    // --- Configure only mock tokens ---
    function _configureMocks() internal {
        mockERC20.setDetails("Mock ERC20", "MERC", 6);
    }

    // --- External setup for pre-deployed mail system contracts ---
    function setMailContracts(
        address _names,
        address _locker,
        address _market
    ) external {
        require(msg.sender == tester, "Not tester");
        require(_names != address(0), "Invalid names");
        require(_locker != address(0), "Invalid locker");
        require(_market != address(0), "Invalid market");

        names = MailNames(_names);
        locker = MailLocker(_locker);
        market = MailMarket(_market);

        // --- Attempt ownership transfer to this test contract ---
        // Using inline interfaces to avoid import bloat
        // If any transfer fails (not implemented, already transferred, etc), emit event and continue
        _tryTransferOwnership(_names, address(this));
        _tryTransferOwnership(_locker, address(this));
        _tryTransferOwnership(_market, address(this));

        // --- Configure dependencies (assumes contracts are pre-initialized) ---
        // Only set mailToken if not already set
        if (address(names.mailToken()) == address(0)) {
            names.setMailToken(address(mailToken));
        }
        if (address(names.mailLocker()) == address(0)) {
            names.setMailLocker(address(locker));
        }
        if (address(names.mailMarket()) == address(0)) {
            names.setMailMarket(address(market));
        }

        if (address(locker.mailToken()) == address(0)) {
            locker.setMailToken(address(mailToken));
        }
        if (address(locker.mailNames()) == address(0)) {
            locker.setMailNames(address(names));
        }

        if (address(market.mailToken()) == address(0)) {
            market.setMailToken(address(mailToken));
        }
        if (address(market.mailNames()) == address(0)) {
            market.setMailNames(address(names));
        }
        if (market.tokenCounts(address(mockERC20)) == 0) {
            market.addAllowedToken(address(mockERC20));
        }

        emit MailContractsSet(_names, _locker, _market);
    }

    // --- Helper: Attempt ownership transfer with try/catch ---
    function _tryTransferOwnership(address _target, address _newOwner) internal {
        (bool success, bytes memory data) = _target.call(
            abi.encodeWithSignature("transferOwnership(address)", _newOwner)
        );
        if (!success) {
            string memory reason = "Unknown";
            if (data.length > 0) {
                assembly { reason := add(data, 0x20) }
            }
            emit OwnershipTransferFailed(_target, reason);
            // Non-critical: continue setup
        }
    }

    function initiateTesters() public payable {
        require(msg.sender == tester, "Not tester");
        require(msg.value == 4 ether, "Send 4 ETH");

        for (uint i = 0; i < 4; i++) {
            MockMailTester t = new MockMailTester(address(this));
            (bool s,) = address(t).call{value: 1 ether}("");
            require(s, "Fund failed");
            testers[i] = t;

            mailToken.mint(address(t), 100 * 1e18);     // 100 MAIL
            mockERC20.mint(address(t), 100 * 1e6);      // 100 MOCK
        }
    }

    function _approveMAIL(uint idx, address spender) internal {
        testers[idx].proxyCall(
            address(mailToken),
            abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max)
        );
    }

    function _approveERC20(uint idx, address spender) internal {
        testers[idx].proxyCall(
            address(mockERC20),
            abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max)
        );
    }

    // --- p1: Basic Lifecycle (Chained) ---
    function p1_1TestMint() public {
        testers[0].proxyCall(address(names), abi.encodeWithSignature("mintName(string)", "alice"));
        p1NameHash = uint256(keccak256(abi.encodePacked("alice")));
        p1TokenId = names.nameHashToTokenId(p1NameHash);
        
        MailNames.NameRecord memory rec = names.getNameRecords("alice");
        uint256 allowanceEnd = rec.allowanceEnd;
        uint256 graceEnd = rec.graceEnd;
        
        assert(names.totalNames() == 1);
        assert(names.ownerOf(p1TokenId) == address(testers[0]));
        assert(allowanceEnd == block.timestamp + ONE_YEAR);
        assert(graceEnd == allowanceEnd + GRACE);
    }

    function p1_2TestSubname() public {
        testers[0].proxyCall(address(names), abi.encodeWithSignature("mintSubname(string,string)", "alice", "mail"));
        (uint256 subIdx, bool found) = names.getSubnameID("alice", "mail");
        assert(found && subIdx == 0);
    }

    function p1_3TestCustomRecord() public {
        MailNames.CustomRecord memory rec = MailNames.CustomRecord("Hello", "ipfs://abc", "Qm123", 3600, address(0));
        testers[0].proxyCall(address(names), abi.encodeWithSignature("setCustomRecord(uint256,uint256,(string,string,string,uint256,address))", 
            p1NameHash, 0, rec));
        string memory text = names.getNameRecords("alice").customRecords[0].text;
        assert(keccak256(bytes(text)) == keccak256(bytes("Hello")));
    }

    function p1_4TestTransfer() public {
        testers[0].proxyCall(address(names), abi.encodeWithSignature("transferName(uint256,address)", p1NameHash, address(testers[1])));
        assert(names.ownerOf(p1TokenId) == address(testers[1]));
    }

    function p1_5WarpToExpiration() public {
        names.warp(block.timestamp + ONE_YEAR + 1);
        MailNames.NameRecord memory rec = names.getNameRecords("alice");
        assert(block.timestamp > rec.allowanceEnd);
    }

    function p1_6TestQueueCheckIn() public {
        _approveMAIL(1, address(names));
        testers[1].proxyCall(address(names), abi.encodeWithSignature("queueCheckIn(uint256)", p1NameHash));
        (uint256 nh, address u, , ) = names.pendingCheckins(0);
        assert(nh == p1NameHash && u == address(testers[1]));
        assert(locker.getTotalLocked(address(testers[1])) > 0);
    }

    function p1_7TestProcessCheckIn() public {
        names.warp(names.currentTime() + 11 minutes);
        names.advance();
        MailNames.NameRecord memory rec = names.getNameRecords("alice");
        assert(rec.allowanceEnd > names.currentTime());
    }

    function p1_8TestLockerView() public {
        (MailLocker.Deposit[] memory deps) = locker.getUserDeposits(address(testers[1]), 0, 10);
        assert(deps.length > 0 && deps[0].unlockTime > block.timestamp);
        assert(locker.getTotalLocked(address(testers[1])) == deps[0].amount);
    }

    // --- p2: Bidding & Settlement (Chained) ---
    function p2_1TestETHBidSetup() public {
        testers[0].proxyCall(address(names), abi.encodeWithSignature("mintName(string)", "bob"));
        p2NameHash = uint256(keccak256(abi.encodePacked("bob")));
        p2TokenId = names.nameHashToTokenId(p2NameHash);
        names.warp(block.timestamp + ONE_YEAR + GRACE + 1);
    }

    function p2_2TestETHBid() public {
        _approveMAIL(2, address(market));
        testers[2].proxyCall{value: 1 ether}(address(market), abi.encodeWithSignature("placeETHBid(string)", "bob"));
        MailMarket.Bid memory bid = market.getNameBids("bob", true, address(0))[0];
        assert(bid.bidder == address(testers[2]) && bid.amount == 1 ether);
    }

    function p2_3TestTokenBid() public {
        _approveERC20(3, address(market));
        testers[3].proxyCall(
            address(market), abi.encodeWithSignature("placeTokenBid(string,uint256,address)", "bob", 100 * 1e6, address(mockERC20))
        );
        MailMarket.Bid memory bid = market.getNameBids("bob", false, address(mockERC20))[0];
        assert(bid.bidder == address(testers[3]));
    }

    function p2_4TestAcceptBid() public {
        testers[0].proxyCall(address(market), abi.encodeWithSignature("acceptBid(uint256,bool,address,uint256)", p2NameHash, true, address(0), 0));
        assert(names.ownerOf(p2TokenId) == address(testers[2]));

        // Reset for next test
        testers[0].proxyCall(address(names), abi.encodeWithSignature("mintName(string)", "charlie"));
        uint256 charlieHash = uint256(keccak256(abi.encodePacked("charlie")));
        uint256 charlieTokenId = names.nameHashToTokenId(charlieHash);
        assert(charlieTokenId != 0);
        names.warp(names.currentTime() + ONE_YEAR + GRACE + 1);
    }

    function p2_5TestPostGraceBidSetup() public {
        _approveMAIL(1, address(market));
        testers[1].proxyCall{value: 2 ether}(address(market), abi.encodeWithSignature("placeETHBid(string)", "charlie"));
    }

    function p2_6TestQueueSettlement() public {
        MailNames.PendingSettlement[] memory pending = names.getPendingSettlements("charlie", 0, 10);
        assert(pending.length > 0 && pending[0].queueTime > 0);
    }

    function p2_7TestPostGraceSettlement() public {
        names.warp(names.currentTime() + THREE_WEEKS + 1);
        MailNames.PendingSettlement[] memory pending = names.getPendingSettlements("charlie", 0, 10);
        require(pending.length > 0, "No pending settlements");
        
        uint256 settlementIndex = 0;
        uint256 charlieHash = uint256(keccak256(abi.encodePacked("charlie")));
        bool found = false;
        
        for (uint256 i = 0; i < 100; i++) {
            try names.getSettlementById(i) returns (MailNames.PendingSettlement memory s) {
                if (s.nameHash == charlieHash) {
                    settlementIndex = i;
                    found = true;
                    break;
                }
            } catch {
                break;
            }
        }
        
        require(found, "Settlement not found");
        names.processSettlement(settlementIndex);
        uint256 tokenId = names.nameHashToTokenId(charlieHash);
        assert(names.ownerOf(tokenId) == address(testers[1]));
    }

    // --- s: Sad Paths (Independent) ---
    function s1_MintDuplicateName() public {
        testers[0].proxyCall(address(names), abi.encodeWithSignature("mintName(string)", "duplicate"));
        try testers[0].proxyCall(address(names), abi.encodeWithSignature("mintName(string)", "duplicate"))
        { revert("Did not revert"); } catch {}
    }

    function s2_MintInvalidName() public {
        try testers[0].proxyCall(address(names), abi.encodeWithSignature("mintName(string)", "a b"))
        { revert("Did not revert"); } catch {}
        try testers[0].proxyCall(address(names), abi.encodeWithSignature("mintName(string)", string(new bytes(25))))
        { revert("Did not revert"); } catch {}
    }

    function s3_NonOwnerTransfer() public {
        testers[0].proxyCall(address(names), abi.encodeWithSignature("mintName(string)", "transfertest"));
        uint256 hash = uint256(keccak256(abi.encodePacked("transfertest")));
        try testers[1].proxyCall(address(names), abi.encodeWithSignature("transferName(uint256,address)", hash, address(testers[2])))
        { revert("Did not revert"); } catch {}
    }

    function s4_CheckInBeforeExpiration() public {
        testers[0].proxyCall(address(names), abi.encodeWithSignature("mintName(string)", "earlycheck"));
        uint256 hash = uint256(keccak256(abi.encodePacked("earlycheck")));
        _approveMAIL(0, address(names));
        try testers[0].proxyCall(address(names), abi.encodeWithSignature("queueCheckIn(uint256)", hash))
        { revert("Did not revert"); } catch {}
    }

    function s5_BidWithoutMAIL() public {
        testers[0].proxyCall(address(names), abi.encodeWithSignature("mintName(string)", "nomail"));
        names.warp(block.timestamp + ONE_YEAR + GRACE + 1);
        try testers[3].proxyCall{value: 1 ether}(
            address(market), abi.encodeWithSignature("placeETHBid(string)", "nomail")
        ) { revert("Did not revert"); } catch {}
    }

    function s6_AcceptBidNotOwner() public {
        testers[0].proxyCall(address(names), abi.encodeWithSignature("mintName(string)", "notowner"));
        names.warp(block.timestamp + ONE_YEAR + GRACE + 1);
        _approveMAIL(2, address(market));
        testers[2].proxyCall{value: 1 ether}(address(market), abi.encodeWithSignature("placeETHBid(string)", "notowner"));
        uint256 hash = uint256(keccak256(abi.encodePacked("notowner")));
        try testers[1].proxyCall(address(market), abi.encodeWithSignature("acceptBid(uint256,bool,address,uint256)", hash, true, address(0), 0))
        { revert("Did not revert"); } catch {}
    }

    function s7_ProcessSettlementEarly() public {
        testers[0].proxyCall(address(names), abi.encodeWithSignature("mintName(string)", "earlysettle"));
        names.warp(block.timestamp + ONE_YEAR + GRACE + 1);
        _approveMAIL(1, address(market));
        testers[1].proxyCall{value: 1 ether}(address(market), abi.encodeWithSignature("placeETHBid(string)", "earlysettle"));
        
        uint256 earlysettleHash = uint256(keccak256(abi.encodePacked("earlysettle")));
        uint256 settlementIndex = 0;
        bool found = false;
        
        for (uint256 i = 0; i < 100; i++) {
            try names.getSettlementById(i) returns (MailNames.PendingSettlement memory s) {
                if (s.nameHash == earlysettleHash) {
                    settlementIndex = i;
                    found = true;
                    break;
                }
            } catch {
                break;
            }
        }
        
        require(found, "Settlement not found for s7");
        try names.processSettlement(settlementIndex) { revert("Did not revert"); } catch {}
    }

    function s8_DoubleCheckIn() public {
        testers[0].proxyCall(address(names), abi.encodeWithSignature("mintName(string)", "doublecheck"));
        names.warp(block.timestamp + ONE_YEAR + 1);
        _approveMAIL(0, address(names));
        testers[0].proxyCall(address(names), abi.encodeWithSignature("queueCheckIn(uint256)", uint256(keccak256(abi.encodePacked("doublecheck")))));
        try testers[0].proxyCall(address(names), abi.encodeWithSignature("queueCheckIn(uint256)", uint256(keccak256(abi.encodePacked("doublecheck")))))
        { revert("Did not revert"); } catch {}
    }

    function s9_WithdrawLockedMAIL() public {
        try testers[1].proxyCall(address(locker), abi.encodeWithSignature("withdraw(uint256)", 0))
        { revert("Did not revert"); } catch {}
    }

    function s10_PlaceBidDisallowedToken() public {
        testers[0].proxyCall(address(names), abi.encodeWithSignature("mintName(string)", "badtoken"));
        names.warp(block.timestamp + ONE_YEAR + GRACE + 1);
        try testers[2].proxyCall(
            address(market), abi.encodeWithSignature("placeTokenBid(string,uint256,address)", "badtoken", 100 * 1e18, address(mailToken))
        ) { revert("Did not revert"); } catch {}
    }

    function s11_SubnameNonOwner() public {
        testers[0].proxyCall(address(names), abi.encodeWithSignature("mintName(string)", "subparent"));
        try testers[1].proxyCall(address(names), abi.encodeWithSignature("mintSubname(string,string)", "subparent", "sub"))
        { revert("Did not revert"); } catch {}
    }

    function s12_SetRecordNonOwner() public {
        MailNames.CustomRecord memory rec = MailNames.CustomRecord("X", "", "", 0, address(0));
        try testers[1].proxyCall(address(names), abi.encodeWithSignature("setCustomRecord(uint256,uint256,(string,string,string,uint256,address))", 
            uint256(keccak256(abi.encodePacked("subparent"))), 0, rec))
        { revert("Did not revert"); } catch {}
    }
}