// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";

import "../exchange/DepositHandler.sol";
import "../exchange/WithdrawalHandler.sol";
import "../exchange/OrderHandler.sol";

import "./Router.sol";

// for functions which require token transfers from the user
contract ExchangeRouter is ReentrancyGuard, Multicall, RoleModule {
    using SafeERC20 for IERC20;
    using Order for Order.Props;

    Router public immutable router;
    DataStore public immutable dataStore;
    EventEmitter public immutable eventEmitter;
    DepositHandler public immutable depositHandler;
    WithdrawalHandler public immutable withdrawalHandler;
    OrderHandler public immutable orderHandler;
    DepositStore public immutable depositStore;
    WithdrawalStore public immutable withdrawalStore;
    OrderStore public immutable orderStore;
    IReferralStorage public immutable referralStorage;

    constructor(
        Router _router,
        RoleStore _roleStore,
        DataStore _dataStore,
        EventEmitter _eventEmitter,
        DepositHandler _depositHandler,
        WithdrawalHandler _withdrawalHandler,
        OrderHandler _orderHandler,
        DepositStore _depositStore,
        WithdrawalStore _withdrawalStore,
        OrderStore _orderStore,
        IReferralStorage _referralStorage
    ) RoleModule(_roleStore) {
        router = _router;
        dataStore = _dataStore;
        eventEmitter = _eventEmitter;

        depositHandler = _depositHandler;
        withdrawalHandler = _withdrawalHandler;
        orderHandler = _orderHandler;

        depositStore = _depositStore;
        withdrawalStore = _withdrawalStore;
        orderStore = _orderStore;

        referralStorage = _referralStorage;
    }

    function createDeposit(
        address longToken,
        address shortToken,
        uint256 longTokenAmount,
        uint256 shortTokenAmount,
        DepositUtils.CreateDepositParams calldata params
    ) external nonReentrant payable returns (bytes32) {
        address account = msg.sender;
        address _depositStore = address(depositStore);

        WrapUtils.sendWnt(dataStore, _depositStore);

        if (longTokenAmount > 0) {
            router.pluginTransfer(longToken, account, _depositStore, longTokenAmount);
        }
        if (shortTokenAmount > 0) {
            router.pluginTransfer(shortToken, account, _depositStore, shortTokenAmount);
        }

        return depositHandler.createDeposit(
            account,
            params
        );
    }

    function createWithdrawal(
        WithdrawalUtils.CreateWithdrawalParams calldata params
    ) external nonReentrant payable returns (bytes32) {
        address account = msg.sender;

        WrapUtils.sendWnt(dataStore, address(withdrawalStore));

        return withdrawalHandler.createWithdrawal(
            account,
            params
        );
    }

    function createOrder(
        uint256 amountIn,
        OrderBaseUtils.CreateOrderParams calldata params,
        bytes32 referralCode
    ) external nonReentrant payable returns (bytes32) {
        require(params.orderType != Order.OrderType.Liquidation, "ExchangeRouter: invalid order type");

        address account = msg.sender;

        ReferralUtils.setTraderReferralCode(referralStorage, account, referralCode);

        WrapUtils.sendWnt(dataStore, address(orderStore));

        if (amountIn > 0) {
            router.pluginTransfer(params.initialCollateralToken, account, address(orderStore), amountIn);
        }

        return orderHandler.createOrder(
            account,
            params
        );
    }

    function updateOrder(
        bytes32 key,
        uint256 sizeDeltaUsd,
        uint256 triggerPrice,
        uint256 acceptablePrice
    ) external payable nonReentrant {
        OrderStore _orderStore = orderStore;
        Order.Props memory order = _orderStore.get(key);

        FeatureUtils.validateFeature(dataStore, Keys.updateOrderFeatureKey(address(this), uint256(order.orderType())));

        require(order.account() == msg.sender, "ExchangeRouter: forbidden");

        if (OrderBaseUtils.isMarketOrder(order.orderType())) {
            revert("ExchangeRouter: invalid orderType");
        }

        order.setSizeDeltaUsd(sizeDeltaUsd);
        order.setTriggerPrice(triggerPrice);
        order.setAcceptablePrice(acceptablePrice);
        order.setIsFrozen(false);

        // allow topping up of executionFee as partially filled or frozen orders
        //  will have their executionFee reduced
        uint256 receivedWnt = WrapUtils.sendWnt(dataStore, address(_orderStore));
        order.setExecutionFee(order.executionFee() + receivedWnt);

        uint256 estimatedGasLimit = GasUtils.estimateExecuteOrderGasLimit(dataStore, order);
        GasUtils.validateExecutionFee(dataStore, estimatedGasLimit, order.executionFee());

        order.touch();
        _orderStore.set(key, order);

        eventEmitter.emitOrderUpdated(key, sizeDeltaUsd, triggerPrice, acceptablePrice);
    }

    function cancelOrder(bytes32 key) external nonReentrant {
        uint256 startingGas = gasleft();

        OrderStore _orderStore = orderStore;
        Order.Props memory order = _orderStore.get(key);

        FeatureUtils.validateFeature(dataStore, Keys.cancelOrderFeatureKey(address(this), uint256(order.orderType())));

        require(order.account() == msg.sender, "ExchangeRouter: forbidden");

        if (OrderBaseUtils.isMarketOrder(order.orderType())) {
            revert("ExchangeRouter: invalid orderType");
        }

        OrderUtils.cancelOrder(
            dataStore,
            eventEmitter,
            orderStore,
            key,
            msg.sender,
            startingGas,
            "USER_INITIATED_CANCEL"
        );
    }

    function claimFundingFees(address[] memory markets, address[] memory tokens, address receiver) external nonReentrant {
        if (markets.length != tokens.length) {
            revert("Invalid input");
        }

        address account = msg.sender;

        for (uint256 i = 0; i < markets.length; i++) {
            MarketUtils.claimFundingFees(
                dataStore,
                eventEmitter,
                markets[i],
                tokens[i],
                account,
                receiver
            );
        }
    }

    function claimAffiliateRewards(address[] memory markets, address[] memory tokens, address receiver) external nonReentrant {
        if (markets.length != tokens.length) {
            revert("Invalid input");
        }

        address account = msg.sender;

        for (uint256 i = 0; i < markets.length; i++) {
            ReferralUtils.claimAffiliateReward(
                dataStore,
                eventEmitter,
                markets[i],
                tokens[i],
                account,
                receiver
            );
        }
    }
}
