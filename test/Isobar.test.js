const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const DAY = 86400;
const E = (n) => ethers.parseEther(String(n));

describe("Isobar", function () {
  let ib, owner, merchant, sub, other;

  beforeEach(async () => {
    [owner, merchant, sub, other] = await ethers.getSigners();
    const F = await ethers.getContractFactory("Isobar");
    ib = await F.deploy();
    await ib.waitForDeployment();
  });

  // 1 BOT every 30 days.
  async function newPlan(price = "1", period = 30 * DAY) {
    await ib.connect(merchant).createPlan("Station readings, monthly", E(price), period);
    return (await ib.planCount()) - 1n;
  }
  async function subscribeTo(planId, fund = "3", who = sub) {
    await ib.connect(who).subscribe(planId, { value: E(fund) });
    return (await ib.subCount()) - 1n;
  }

  it("creates a plan with a price and a period", async () => {
    const id = await newPlan();
    const p = await ib.getPlan(id);
    expect(p.merchant).to.equal(merchant.address);
    expect(p.pricePerPeriod).to.equal(E(1));
    expect(p.periodSecs).to.equal(30 * DAY);
    expect(p.open).to.equal(true);
  });

  it("rejects a zero price and a silly period", async () => {
    await expect(ib.connect(merchant).createPlan("x", 0, 30 * DAY)).to.be.revertedWith("price zero");
    await expect(ib.connect(merchant).createPlan("x", E(1), 600)).to.be.revertedWith("bad period");
    await expect(ib.connect(merchant).createPlan("x", E(1), 400 * DAY)).to.be.revertedWith("bad period");
    await expect(ib.connect(merchant).createPlan("", E(1), 30 * DAY)).to.be.revertedWith("bad name");
  });

  it("charges the first period on subscribing and banks the rest", async () => {
    const plan = await newPlan();
    const id = await subscribeTo(plan, "3");

    const s = await ib.getSub(id);
    expect(s.balance).to.equal(E(2));       // 3 funded, 1 charged
    expect(s.periodsPaid).to.equal(1);
    expect(s.active).to.equal(true);
    expect(await ib.periodsCovered(id)).to.equal(2);

    // 1.5% of 1 BOT
    expect(await ib.accumulatedFees()).to.equal(E("0.015"));
    expect((await ib.getPlan(plan)).collected).to.equal(E("0.985"));
  });

  it("will not start a subscription without a full period of funding", async () => {
    const plan = await newPlan();
    await expect(ib.connect(sub).subscribe(plan, { value: E("0.5") })).to.be.revertedWith(
      "fund at least one period"
    );
    await expect(ib.connect(merchant).subscribe(plan, { value: E(2) })).to.be.revertedWith(
      "merchant cannot subscribe"
    );
  });

  it("draws one period at a time, and only once it is due", async () => {
    const plan = await newPlan();
    const id = await subscribeTo(plan, "3");

    await expect(ib.connect(merchant).charge(id, 1)).to.be.revertedWith("not due yet");
    expect(await ib.dueIn(id)).to.be.greaterThan(0);

    await time.increase(30 * DAY + 60);
    expect(await ib.periodsDue(id)).to.equal(1);
    await ib.connect(merchant).charge(id, 1);

    const s = await ib.getSub(id);
    expect(s.balance).to.equal(E(1));
    expect(s.periodsPaid).to.equal(2);
  });

  it("lets anyone poke a subscription that is due", async () => {
    const plan = await newPlan();
    const id = await subscribeTo(plan, "3");
    await time.increase(30 * DAY + 60);
    await ib.connect(other).charge(id, 1); // not the merchant, not the subscriber
    expect((await ib.getSub(id)).periodsPaid).to.equal(2);
  });

  it("catches up several periods at once, bounded", async () => {
    const plan = await newPlan();
    const id = await subscribeTo(plan, "5");
    await time.increase(95 * DAY);

    // Periods fell due at day 30, 60 and 90 — day 120 has not arrived.
    expect(await ib.periodsDue(id)).to.equal(3);
    await expect(ib.connect(merchant).charge(id, 20)).to.be.revertedWith("bad period count");

    await ib.connect(merchant).charge(id, 12);
    const s = await ib.getSub(id);
    expect(s.periodsPaid).to.equal(4);   // 1 at subscribe + 3 caught up
    expect(s.balance).to.equal(E(1));
  });

  it("lapses on its own when the money runs out", async () => {
    const plan = await newPlan();
    const id = await subscribeTo(plan, "2");

    await time.increase(30 * DAY + 60);
    await ib.connect(merchant).charge(id, 1); // balance now 0

    await time.increase(30 * DAY + 60);
    await ib.connect(merchant).charge(id, 1); // nothing to take
    const s = await ib.getSub(id);
    expect(s.active).to.equal(false);
    expect(s.periodsPaid).to.equal(2);
    expect((await ib.getPlan(plan)).subscribers).to.equal(0);

    await expect(ib.connect(merchant).charge(id, 1)).to.be.revertedWith("not active");
  });

  it("keeps a lapsed subscription's remainder for the subscriber", async () => {
    const plan = await newPlan();
    const id = await subscribeTo(plan, "1.4"); // 1 charged, 0.4 left — not a full period

    await time.increase(30 * DAY + 60);
    await ib.connect(merchant).charge(id, 1);
    expect((await ib.getSub(id)).active).to.equal(false);

    await expect(ib.connect(sub).withdrawBalance(id)).to.changeEtherBalance(sub, E("0.4"));
    await expect(ib.connect(sub).withdrawBalance(id)).to.be.revertedWith("nothing to withdraw");
  });

  it("tops up an active subscription", async () => {
    const plan = await newPlan();
    const id = await subscribeTo(plan, "1");
    expect(await ib.periodsCovered(id)).to.equal(0);
    await ib.connect(sub).topUp(id, { value: E(2) });
    expect(await ib.periodsCovered(id)).to.equal(2);
    await expect(ib.connect(other).topUp(id, { value: E(1) })).to.be.revertedWith("not your subscription");
  });

  it("cancels on the subscriber's word and leaves the balance theirs", async () => {
    const plan = await newPlan();
    const id = await subscribeTo(plan, "3");

    await expect(ib.connect(other).cancel(id)).to.be.revertedWith("not your subscription");
    await ib.connect(sub).cancel(id);
    expect((await ib.getSub(id)).active).to.equal(false);
    await expect(ib.connect(sub).withdrawBalance(id)).to.changeEtherBalance(sub, E(2));
    await expect(ib.connect(sub).cancel(id)).to.be.revertedWith("not active");
  });

  it("lets a subscriber pull their balance mid-term, which simply lapses the plan", async () => {
    const plan = await newPlan();
    const id = await subscribeTo(plan, "3");
    await ib.connect(sub).withdrawBalance(id);

    await time.increase(30 * DAY + 60);
    await ib.connect(merchant).charge(id, 1);
    expect((await ib.getSub(id)).active).to.equal(false);
  });

  it("pays the merchant what was charged, minus the fee", async () => {
    const plan = await newPlan();
    const id = await subscribeTo(plan, "3");
    await time.increase(30 * DAY + 60);
    await ib.connect(merchant).charge(id, 1);

    // Two periods at 1 BOT, 1.5% each.
    await expect(ib.connect(other).merchantWithdraw(plan)).to.be.revertedWith("not merchant");
    await expect(ib.connect(merchant).merchantWithdraw(plan)).to.changeEtherBalance(merchant, E("1.97"));
    await expect(ib.connect(merchant).merchantWithdraw(plan)).to.be.revertedWith("nothing collected");
    expect(await ib.accumulatedFees()).to.equal(E("0.03"));
    expect(await ib.getSub(id)).to.not.equal(undefined);
  });

  it("closes a plan to newcomers without touching the people already on it", async () => {
    const plan = await newPlan();
    const id = await subscribeTo(plan, "3");
    await ib.connect(merchant).setPlanOpen(plan, false);

    await expect(ib.connect(other).subscribe(plan, { value: E(3) })).to.be.revertedWith("plan closed");
    await time.increase(30 * DAY + 60);
    await ib.connect(merchant).charge(id, 1);
    expect((await ib.getSub(id)).periodsPaid).to.equal(2);
    await expect(ib.connect(other).setPlanOpen(plan, true)).to.be.revertedWith("not merchant");
  });

  it("pauses new plans and new subscriptions but never billing or withdrawal", async () => {
    const plan = await newPlan();
    const id = await subscribeTo(plan, "3");
    await ib.connect(owner).pause();

    await expect(ib.connect(other).subscribe(plan, { value: E(3) })).to.be.revertedWithCustomError(
      ib,
      "EnforcedPause"
    );
    await expect(ib.connect(merchant).createPlan("x", E(1), 30 * DAY)).to.be.revertedWithCustomError(
      ib,
      "EnforcedPause"
    );

    await time.increase(30 * DAY + 60);
    await ib.connect(merchant).charge(id, 1);
    await ib.connect(sub).cancel(id);
    await ib.connect(sub).withdrawBalance(id);
    await ib.connect(merchant).merchantWithdraw(plan);
  });

  it("caps the fee and withdraws only fees, leaving the contract square", async () => {
    await expect(ib.connect(owner).setFeeBps(900)).to.be.revertedWith("fee too high");

    const plan = await newPlan();
    const id = await subscribeTo(plan, "3");
    await ib.connect(sub).cancel(id);
    await ib.connect(sub).withdrawBalance(id);
    await ib.connect(merchant).merchantWithdraw(plan);

    await expect(ib.connect(sub).withdrawFees(sub.address)).to.be.revertedWithCustomError(
      ib,
      "OwnableUnauthorizedAccount"
    );
    await expect(ib.connect(owner).withdrawFees(owner.address)).to.changeEtherBalance(owner, E("0.015"));
    expect(await ib.lockedTotal()).to.equal(0);
    expect(await ethers.provider.getBalance(await ib.getAddress())).to.equal(0);
  });

  it("indexes plans and subscriptions both ways", async () => {
    const plan = await newPlan();
    const a = await subscribeTo(plan, "3", sub);
    const b = await subscribeTo(plan, "3", other);
    await newPlan("2");

    expect((await ib.getPlanSubs(plan)).map(Number)).to.deep.equal([Number(a), Number(b)]);
    expect((await ib.getSubsBySubscriber(sub.address)).map(Number)).to.deep.equal([Number(a)]);
    expect((await ib.getPlansByMerchant(merchant.address)).length).to.equal(2);
    expect((await ib.getRecentPlans(2)).map(Number)).to.deep.equal([1, 0]);
  });
});
