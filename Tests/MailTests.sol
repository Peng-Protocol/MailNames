// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// File Version: 0.0.1 (07/11/2025)
// Changelog:
// - 07/11/2025: Initial implementation.

import "../MailNames.sol";
import "../MailLocker.sol";
import "../MailMarket.sol";
import "./MockMAILToken.sol";
import "./MockMailTester.sol";

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

    constructor() {
        tester = msg.sender;
        _deployContracts();
        _configureContracts();
    }

    function _deployContracts() internal {
        mailToken = new MockMAILToken();
        mockERC20 = new MockMAILToken();
        locker = new MailLocker();
        names = new MailNames();
        market = new MailMarket();
    }

    function _configureContracts() internal {
        names.setMailToken(address(mailToken));
        names.setMailLocker(address(locker));
        names.setMailMarket(address(market));

        locker.setMailToken(address(mailToken));
        locker.setMailNames(address(names));

        market.setMailToken(address(mailToken));
        market.setMailNames(address(names));
        market.addAllowedToken(address(mockERC20));

        mockERC20.setDetails("Mock ERC20", "MERC", 6);
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
    }

    function p2_5TestPostGraceBidSetup() public {
        testers[0].proxyCall(address(names), abi.encodeWithSignature("mintName(string)", "charlie"));
        uint256 nameHash = uint256(keccak256(abi.encodePacked("charlie")));
        uint256 tokenId = names.nameHashToTokenId(nameHash);
    assert(tokenId != 0); // Verify name was minted successfully
    names.warp(names.currentTime() + ONE_YEAR + GRACE + 1);
    _approveMAIL(1, address(market));
    testers[1].proxyCall{value: 2 ether}(address(market), abi.encodeWithSignature("placeETHBid(string)", "charlie"));
}

    function p2_6TestQueueSettlement() public {
        MailNames.PendingSettlement[] memory pending = names.getPendingSettlements("charlie", 0, 10);
        assert(pending.length > 0 && pending[0].queueTime > 0);
    }

    function p2_7TestPostGraceSettlement() public {
        names.warp(names.currentTime() + THREE_WEEKS + 1);
        // Get the settlement index for charlie before processing
        MailNames.PendingSettlement[] memory pending = names.getPendingSettlements("charlie", 0, 10);
        require(pending.length > 0, "No pending settlements");
        
        // Find the actual index in the global pendingSettlements array
        uint256 settlementIndex = 0;
        uint256 charlieHash = uint256(keccak256(abi.encodePacked("charlie")));
        bool found = false;
        
        // Search through global settlements to find charlie's settlement
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
        
        // Find the settlement index
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
        
        // Try to process before 3 weeks - should revert
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