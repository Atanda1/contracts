//SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.18;
import "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {PaycrestSettingManager} from "./PaycrestSettingManager.sol";
import {IPaycrestStake} from "./interface/IPaycrestStake.sol";
import {IPaycrest, IERC20} from "./interface/IPaycrest.sol";
contract Paycrest is IPaycrest, PaycrestSettingManager { 
    using SafeERC20Upgradeable for IERC20;
    using ECDSAUpgradeable for bytes32;
    struct fee {
        uint256 protocolFee;
        uint256 liquidityProviderAmount;
        uint256 primaryValidatorReward;
        uint256 secondaryValidatorsReward;
    }
    mapping(bytes32 => Order) private order;
    mapping(address => uint256) private _nonce;
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _usdc) external initializer {    
        _isTokenSupported[_usdc] = true;   
        MAX_BPS = 100_000; 
        protocolFeePercent = 5000; // 5%
        primaryValidatorFeePercent = 500; // 0.5%
        secondaryValidatorFeePercent = 500; // 0.5%
        __Ownable_init();
    }
    // constructor(address _usdc) {
    //     _isTokenSupported[_usdc] = true;
    // }

    modifier onlyAggregator {
        if(msg.sender != _liquidityAggregator) revert OnlyAggregator();
        _;
    }
    
    /* ##################################################################
                                USER CALLS
    ################################################################## */
    /** @dev See {createOrder-IPaycrest}. */
    function createOrder(
        address _token, 
        uint256 _amount, 
        bytes32 _institutionCode,
        uint96 _rate, 
        address _senderFeeRecipient,
        uint256 _senderFee,
        address _refundAddress, 
        string calldata messageHash
    )  external returns(bytes32 orderId) {
        // sender must be a whitelisted address
        // if(!_isWhitelisted[msg.sender]) revert NotWhitelisted();
        // checks that are required
        _handler(_token, _amount, _refundAddress, _senderFeeRecipient, _institutionCode);
        // first transfer token from msg.sender
        IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        // increase users nonce to avoid replay attacks
        _nonce[msg.sender] ++;
        // generate transaction id for the transaction
        orderId = keccak256(abi.encode(msg.sender, _nonce[msg.sender]));
        // update transaction
        order[orderId] = Order({
            seller: msg.sender,
            token: _token,
            senderFeeRecipient: _senderFeeRecipient,
            senderFee: _senderFee,
            rate: _rate,
            isFulfilled: false,
            refundAddress: _refundAddress,
            currentBPS: uint96(MAX_BPS),
            amount: _amount
        });
        // emit deposit event
        emit Deposit(orderId, _amount, _rate, _institutionCode, messageHash);
    }

    function _handler(address _token, uint256 _amount, address _refundAddress, address _senderFeeRecipient, bytes32 _institutionCode) internal view {
        if(!_isTokenSupported[_token]) revert TokenNotSupported();
        if(_amount == 0) revert AmountIsZero();
        if(_refundAddress == address(0)) revert ThrowZeroAddress();
        if(_senderFeeRecipient == address(0)) revert ThrowZeroAddress();
        if(supportedInstitutionsByCode[_institutionCode].name == bytes32(0)) revert InvalidInstitutionCode();
    }

    /* ##################################################################
                                AGGREGATOR FUNCTIONS
    ################################################################## */
    /** @dev See {settle-IPaycrest}. */
    function settle(
        bytes32 _orderId, 
        address _primaryValidator, 
        address[] calldata _secondaryValidators, 
        address _liquidityProvider, 
        uint96 _settlePercent
        )  external onlyAggregator() returns(bool) {
        // ensure the transaction has not been fulfilled
        if(order[_orderId].isFulfilled) revert OrderFulfilled();
        // load the token into memory
        address token = order[_orderId].token;
        // substract sum of amount based on the input _settlePercent
        order[_orderId].currentBPS -= _settlePercent;
        // if transaction amount is zero
        if(order[_orderId].currentBPS == 0) {
            // update the transaction to be fulfilled
            order[_orderId].isFulfilled = true;
        }

        // load the fees and transfer associated protocol fees to protocol fee recipient
        ( fee memory _feeParams  ) = _calculateFees(_orderId, _settlePercent);
        uint256 _fee = order[_orderId].senderFee;
        if (_fee > 0) {
            // transfer sender fee
            transferSenderFee(_orderId);
        }
        // transfer protocol fee
        IERC20(token).transfer(feeRecipient, _feeParams.protocolFee);
        // // transfer to liquidity provider 
        IERC20(token).transfer(_liquidityProvider, _feeParams.liquidityProviderAmount);
        IERC20(token).transfer(address(PaycrestStakingContract), (_feeParams.primaryValidatorReward + _feeParams.secondaryValidatorsReward));
        // // distribute rewards
        bool status = IPaycrestStake(PaycrestStakingContract).rewardValidators(
            _orderId,
            token,
            _primaryValidator, 
            _secondaryValidators, 
            _feeParams.primaryValidatorReward, 
            _feeParams.secondaryValidatorsReward
        );
        if(!status) revert UnableToProcessRewards();
        // emit event
        emit Settled(_orderId, _liquidityProvider, _settlePercent);
        return true;
    }

    function transferSenderFee(bytes32 _orderId) internal {
        address recipient = order[_orderId].senderFeeRecipient;
        uint256 _fee = order[_orderId].senderFee;
        // transfer sender fee
        IERC20(order[_orderId].token).transfer(recipient, _fee);
        // emmit event
        emit TransferSenderFee(recipient, _fee);
    }

    /** @dev See {refund-IPaycrest}. */
    function refund(bytes32 _orderId)  external onlyAggregator() returns(bool) {
        // ensure the transaction has not been fulfilled
        if(order[_orderId].isFulfilled) revert OrderFulfilled();
        // reser state values
        order[_orderId].isFulfilled = true;
        order[_orderId].currentBPS = 0;
        // transfer to seller 
        IERC20(order[_orderId].token).transfer(order[_orderId].refundAddress, order[_orderId].amount);
        // emit
        emit Refunded(_orderId);
        return true;
    }

    function _calculateFees(bytes32 _orderId, uint96 _settlePercent) private view returns(fee memory _feeParams ) {
        // get the total amount associated with the orderId
        uint256 amount = order[_orderId].amount;
        // get sender fee from amount
        amount = amount - order[_orderId].senderFee;
        // get the settled percent that is scheduled for this amount
        _feeParams.liquidityProviderAmount = (amount * _settlePercent) / MAX_BPS;
        // deduct protocol fees from the new total amount
        _feeParams.protocolFee = (_feeParams.liquidityProviderAmount * protocolFeePercent) / MAX_BPS; 
        // substract total fees from the new amount after getting the scheduled amount
        _feeParams.liquidityProviderAmount = (_feeParams.liquidityProviderAmount - _feeParams.protocolFee);
        // get primary validators fees primaryValidatorsReward
        _feeParams.primaryValidatorReward = (_feeParams.protocolFee * primaryValidatorFeePercent) / MAX_BPS;
        // get primary validators fees secondaryValidatorsReward
        _feeParams.secondaryValidatorsReward = (_feeParams.protocolFee * secondaryValidatorFeePercent) / MAX_BPS;
        // update new protocol fee
        _feeParams.protocolFee = _feeParams.protocolFee - (_feeParams.primaryValidatorReward + _feeParams.secondaryValidatorsReward);
    }
    
    /* ##################################################################
                                VIEW CALLS
    ################################################################## */
    /** @dev See {getOrderInfo-IPaycrest}. */
    function getOrderInfo(bytes32 _orderId) external view returns(Order memory) {
        return order[_orderId];
    }

    /** @dev See {isTokenSupported-IPaycrest}. */
    function isTokenSupported(address _token) external view returns(bool) {
        return _isTokenSupported[_token];
    }

    /** @dev See {getSupportedInstitutionName-IPaycrest}. */
    function getSupportedInstitutionName(bytes32 code) external view returns (InstitutionByCode memory) {
        return supportedInstitutionsByCode[code];
    }

    function getSupportedInstitutions(bytes32 currency) external view returns (Institution[] memory) {
        Institution[] memory institutions = supportedInstitutions[currency];
        uint256 length = institutions.length;
        Institution[] memory result = new Institution[](length);
        
        for (uint256 i = 0; i < length; ) {
            result[i] = institutions[i];
            unchecked {
                i++;
            }
        }
        
        return result;
    }

    /** @dev See {getFeeDetails-IPaycrest}. */
    function getFeeDetails() external view returns(
        uint64, 
        uint64, 
        uint64,
        uint256
    ) {
        return(protocolFeePercent, primaryValidatorFeePercent, secondaryValidatorFeePercent, MAX_BPS);
    }

    /** @dev See {getLiquidityAggregator-IPaycrest}. */
    function getLiquidityAggregator() external view returns(address) {
        return _liquidityAggregator;
    }

    /** @dev See {getWhitelistedStatus-IPaycrest}. */
    function getWhitelistedStatus(address sender) external view returns(bool) {
        return _isWhitelisted[sender];
    }

}
