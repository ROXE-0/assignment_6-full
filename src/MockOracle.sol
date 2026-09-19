// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockOracle {
    mapping(address => uint256) public prices;
    mapping(address => uint256) public updatedTimestamps;

    function setPrice(address token, uint256 price, uint256 timestamp) external {
        prices[token] = price;
        updatedTimestamps[token] = timestamp;
    }

    function getPrice(address token) external view returns (uint256 price, uint256 updatedAt) {
        return (prices[token], updatedTimestamps[token]);
    }
}
