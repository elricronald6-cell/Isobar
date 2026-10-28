// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Isobar
 * @notice Recurring subscriptions on BOT Chain, billed by the period.
 *
 * A subscriber funds a balance. The merchant draws **one period at a time**,
 * never more, and only once that period has actually come round. Run the
 * balance down and the subscription lapses on its own — no card to decline,
 * no retry loop, no standing authority over an account.
 *
 * Charging is permissionless. Anyone can poke a subscription that is due,
 * which lets a merchant batch their billing run from any address, and lets a
 * subscriber prove the schedule is honest by running it themselves.
 *
 * The balance belongs to the subscriber throughout. `withdrawBalance` works at
 * any moment, including mid-term: pulling your money simply means the next
 * charge lapses the subscription. Nothing is held to ransom.
 */
contract Isobar is Ownable, Pausable, ReentrancyGuard {
    struct Plan {
        address merchant;
        uint256 pricePerPeriod;
        uint64 periodSecs;
        bool open;
        uint32 subscribers;
        uint256 collected;
        string name;
    }

    struct Sub {
        uint64 planId;
        address subscriber;
        uint256 balance;
        uint64 nextChargeAt;
        uint32 periodsPaid;
        bool active;
    }

    uint64 public constant MIN_PERIOD = 1 days;
    uint64 public constant MAX_PERIOD = 365 days;
    uint32 public constant MAX_CATCHUP = 12;
    uint256 public constant MAX_NAME = 56;
    uint16 public constant MAX_FEE_BPS = 500;

    /// @notice Taken from each period charged.
    uint16 public feeBps = 150;

    uint256 public accumulatedFees;
    /// @notice Subscriber balances plus merchant proceeds not yet drawn.
    uint256 public lockedTotal;

    Plan[] private _plans;
    Sub[] private _subs;
    mapping(uint256 => uint256[]) private _planSubs;
    mapping(address => uint256[]) private _subsBySubscriber;
    mapping(address => uint256[]) private _plansByMerchant;

    event PlanCreated(uint256 indexed planId, address indexed merchant, string name, uint256 price, uint64 periodSecs);
    event PlanOpenSet(uint256 indexed planId, bool open);
    event Subscribed(uint256 indexed subId, uint256 indexed planId, address indexed subscriber, uint256 funded);
    event ToppedUp(uint256 indexed subId, uint256 amount, uint256 balance);
    event Charged(uint256 indexed subId, address indexed by, uint32 periods, uint256 amount, uint256 fee, uint64 nextChargeAt);
    event Lapsed(uint256 indexed subId, uint256 remainingBalance);
    event Cancelled(uint256 indexed subId, uint256 remainingBalance);
    event BalanceWithdrawn(uint256 indexed subId, address indexed subscriber, uint256 amount);
    event MerchantWithdrew(uint256 indexed planId, address indexed merchant, uint256 amount);
    event FeeUpdated(uint16 feeBps);
    event FeesWithdrawn(address indexed to, uint256 amount);

    constructor() Ownable(msg.sender) {}

    // --------------------------------------------------------------- plans

    function createPlan(string calldata name, uint256 pricePerPeriod, uint64 periodSecs)
        external
        whenNotPaused
        returns (uint256 planId)
    {
        require(bytes(name).length > 0 && bytes(name).length <= MAX_NAME, "bad name");
        require(pricePerPeriod > 0, "price zero");
        require(periodSecs >= MIN_PERIOD && periodSecs <= MAX_PERIOD, "bad period");

        planId = _plans.length;
        _plans.push(
            Plan({
                merchant: msg.sender,
                pricePerPeriod: pricePerPeriod,
                periodSecs: periodSecs,
                open: true,
                subscribers: 0,
                collected: 0,
                name: name
            })
        );
        _plansByMerchant[msg.sender].push(planId);
        emit PlanCreated(planId, msg.sender, name, pricePerPeriod, periodSecs);
    }

    /// @dev Closing a plan stops new subscribers. Existing ones keep running.
    function setPlanOpen(uint256 planId, bool open) external {
        Plan storage p = _plan(planId);
        require(p.merchant == msg.sender, "not merchant");
        p.open = open;
        emit PlanOpenSet(planId, open);
    }

    // ------------------------------------------------------- subscriptions

    /// @notice Fund a subscription. The first period is charged immediately.
    function subscribe(uint256 planId) external payable whenNotPaused nonReentrant returns (uint256 subId) {
        Plan storage p = _plan(planId);
        require(p.open, "plan closed");
        require(msg.sender != p.merchant, "merchant cannot subscribe");
        require(msg.value >= p.pricePerPeriod, "fund at least one period");

        subId = _subs.length;
        _subs.push(
            Sub({
                planId: uint64(planId),
                subscriber: msg.sender,
                balance: msg.value,
                nextChargeAt: uint64(block.timestamp),
                periodsPaid: 0,
                active: true
            })
        );
        _planSubs[planId].push(subId);
        _subsBySubscriber[msg.sender].push(subId);
        unchecked {
            p.subscribers += 1;
        }
        lockedTotal += msg.value;
        emit Subscribed(subId, planId, msg.sender, msg.value);

        _charge(subId, 1);
    }

    function topUp(uint256 subId) external payable {
        Sub storage s = _sub(subId);
        require(s.subscriber == msg.sender, "not your subscription");
        require(s.active, "not active");
        require(msg.value > 0, "nothing sent");
        s.balance += msg.value;
        lockedTotal += msg.value;
        emit ToppedUp(subId, msg.value, s.balance);
    }

    /**
     * @notice Draw whatever periods are due, up to `maxPeriods`.
     * @dev Anyone may call this. The cap keeps the loop bounded, so a long-dormant
     *      subscription is caught up over a few calls rather than one huge one.
     */
    function charge(uint256 subId, uint32 maxPeriods) external {
        require(maxPeriods >= 1 && maxPeriods <= MAX_CATCHUP, "bad period count");
        Sub storage s = _sub(subId);
        require(s.active, "not active");
        require(block.timestamp >= s.nextChargeAt, "not due yet");
        _charge(subId, maxPeriods);
    }

    function _charge(uint256 subId, uint32 maxPeriods) private {
        Sub storage s = _subs[subId];
        Plan storage p = _plans[s.planId];

        uint256 price = p.pricePerPeriod;
        uint32 charged;
        uint256 total;

        while (charged < maxPeriods && block.timestamp >= s.nextChargeAt) {
            if (s.balance < price) break;
            s.balance -= price;
            total += price;
            s.nextChargeAt += p.periodSecs;
            unchecked {
                charged += 1;
                s.periodsPaid += 1;
            }
        }

        if (charged > 0) {
            uint256 fee = (total * feeBps) / 10_000;
            p.collected += total - fee;
            accumulatedFees += fee;
            lockedTotal -= fee;
            emit Charged(subId, msg.sender, charged, total, fee, s.nextChargeAt);
        }

        // Out of money with a period already due: the subscription lapses.
        if (s.balance < price && block.timestamp >= s.nextChargeAt) {
            s.active = false;
            unchecked {
                p.subscribers -= 1;
            }
            emit Lapsed(subId, s.balance);
        }
    }

    function cancel(uint256 subId) external {
        Sub storage s = _sub(subId);
        require(s.subscriber == msg.sender, "not your subscription");
        require(s.active, "not active");
        s.active = false;
        unchecked {
            _plans[s.planId].subscribers -= 1;
        }
        emit Cancelled(subId, s.balance);
    }

    /// @dev Works at any time, paused or not. The balance is the subscriber's.
    function withdrawBalance(uint256 subId) external nonReentrant {
        Sub storage s = _sub(subId);
        require(s.subscriber == msg.sender, "not your subscription");
        uint256 amount = s.balance;
        require(amount > 0, "nothing to withdraw");

        s.balance = 0;
        lockedTotal -= amount;
        emit BalanceWithdrawn(subId, msg.sender, amount);

        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "withdraw failed");
    }

    function merchantWithdraw(uint256 planId) external nonReentrant {
        Plan storage p = _plan(planId);
        require(p.merchant == msg.sender, "not merchant");
        uint256 amount = p.collected;
        require(amount > 0, "nothing collected");

        p.collected = 0;
        lockedTotal -= amount;
        emit MerchantWithdrew(planId, msg.sender, amount);

        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "withdraw failed");
    }

    // --------------------------------------------------------------- views

    function planCount() external view returns (uint256) {
        return _plans.length;
    }

    function subCount() external view returns (uint256) {
        return _subs.length;
    }

    function getPlan(uint256 planId) external view returns (Plan memory) {
        return _plan(planId);
    }

    function getSub(uint256 subId) external view returns (Sub memory) {
        return _sub(subId);
    }

    /// @notice Whole periods the current balance still covers.
    function periodsCovered(uint256 subId) external view returns (uint256) {
        Sub storage s = _sub(subId);
        uint256 price = _plans[s.planId].pricePerPeriod;
        return price == 0 ? 0 : s.balance / price;
    }

    /// @notice Seconds until the next charge is due. Zero when it is due now.
    function dueIn(uint256 subId) external view returns (uint256) {
        Sub storage s = _sub(subId);
        return block.timestamp >= s.nextChargeAt ? 0 : s.nextChargeAt - block.timestamp;
    }

    /// @notice How many periods could be drawn right now.
    function periodsDue(uint256 subId) external view returns (uint32 due) {
        Sub storage s = _sub(subId);
        if (!s.active || block.timestamp < s.nextChargeAt) return 0;
        Plan storage p = _plans[s.planId];
        uint256 elapsed = block.timestamp - s.nextChargeAt;
        uint256 byTime = (elapsed / p.periodSecs) + 1;
        uint256 byMoney = s.balance / p.pricePerPeriod;
        uint256 n = byTime < byMoney ? byTime : byMoney;
        return n > MAX_CATCHUP ? MAX_CATCHUP : uint32(n);
    }

    function getPlanSubs(uint256 planId) external view returns (uint256[] memory) {
        return _planSubs[planId];
    }

    function getSubsBySubscriber(address who) external view returns (uint256[] memory) {
        return _subsBySubscriber[who];
    }

    function getPlansByMerchant(address who) external view returns (uint256[] memory) {
        return _plansByMerchant[who];
    }

    /// @notice Newest-first page of plan ids.
    function getRecentPlans(uint256 limit) external view returns (uint256[] memory ids) {
        uint256 n = _plans.length;
        if (limit > n) limit = n;
        ids = new uint256[](limit);
        for (uint256 i = 0; i < limit; i++) {
            ids[i] = n - 1 - i;
        }
    }

    // --------------------------------------------------------------- admin

    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        require(newFeeBps <= MAX_FEE_BPS, "fee too high");
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Bounded by `accumulatedFees`. Balances and proceeds are unreachable.
    function withdrawFees(address payable to) external onlyOwner nonReentrant {
        require(to != address(0), "bad recipient");
        uint256 amount = accumulatedFees;
        require(amount > 0, "nothing to withdraw");
        accumulatedFees = 0;
        emit FeesWithdrawn(to, amount);
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    // ------------------------------------------------------------ internal

    function _plan(uint256 id) private view returns (Plan storage) {
        require(id < _plans.length, "no such plan");
        return _plans[id];
    }

    function _sub(uint256 id) private view returns (Sub storage) {
        require(id < _subs.length, "no such subscription");
        return _subs[id];
    }

    receive() external payable {
        accumulatedFees += msg.value;
    }
}
