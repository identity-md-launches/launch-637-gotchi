// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBaazaarBuyer, MockBaazaar} from "../../src/MockBaazaar.sol";
import {FeeSink} from "../../src/FeeSink.sol";

/// @notice A contract buyer that pays exactly what the Baazaar asks.
contract CallbackBuyer is IBaazaarBuyer {
    MockBaazaar public immutable BAAZAAR;
    uint256 public lastListingId;
    uint256 public lastAmount;

    constructor(MockBaazaar baazaar) {
        BAAZAAR = baazaar;
    }

    receive() external payable {}

    function buy(address recipient, uint256 maxPrice) external returns (uint256, uint256, uint256) {
        return BAAZAAR.buyCheapest(recipient, maxPrice);
    }

    function payForListing(uint256 listingId, uint256 amount) external override {
        require(msg.sender == address(BAAZAAR), "not baazaar");
        lastListingId = listingId;
        lastAmount = amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "pay failed");
    }
}

/// @notice A contract buyer that never pays.
contract StingyBuyer is IBaazaarBuyer {
    MockBaazaar public immutable BAAZAAR;

    constructor(MockBaazaar baazaar) {
        BAAZAAR = baazaar;
    }

    function buy(address recipient, uint256 maxPrice) external returns (uint256, uint256, uint256) {
        return BAAZAAR.buyCheapest(recipient, maxPrice);
    }

    function payForListing(uint256, uint256) external override {}
}

/// @notice A seller that refuses ETH; pull payments must make it harmless.
contract RevertingReceiver {
    receive() external payable {
        revert("no thanks");
    }
}

/// @notice Stands in for the Baazaar from the FeeSink's point of view and attacks it from inside the
/// payment callback: re-enters `triggerBuy`, asks to be paid twice, and reports what happened.
contract MaliciousBaazaar {
    uint256 public price;
    uint256 public tokenId;
    FeeSink public sink;

    bool public reenterTriggerBuyReverted;
    bool public secondPaymentReverted;
    uint256 public paidTotal;

    receive() external payable {
        paidTotal += msg.value;
    }

    function arm(FeeSink sink_, uint256 price_, uint256 tokenId_) external {
        sink = sink_;
        price = price_;
        tokenId = tokenId_;
    }

    function cheapest() external view returns (bool, uint256, uint256, uint256, address) {
        return (true, 1, tokenId, price, address(this));
    }

    function buyCheapest(address, uint256) external returns (uint256, uint256, uint256) {
        // Legitimate payment first.
        sink.payForListing(1, price);
        // Attack 1: re-enter the crank while it is running.
        try sink.triggerBuy() {
            reenterTriggerBuyReverted = false;
        } catch {
            reenterTriggerBuyReverted = true;
        }
        // Attack 2: ask for the same payment again.
        try sink.payForListing(1, price) {
            secondPaymentReverted = false;
        } catch {
            secondPaymentReverted = true;
        }
        return (1, tokenId, price);
    }
}
