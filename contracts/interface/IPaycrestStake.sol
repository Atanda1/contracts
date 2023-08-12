//SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;

/**
 * @author Chef Photons, Vaultka Team serving high quality drinks; drink responsibly.
 * Factory and global config params
 */
interface IPaycrestStake {
    
    function rewardValidators(bytes32 orderId, address token, address[] memory validators, uint256 validatorsReward) external returns(bool);
    
}
