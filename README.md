# Isobar

Recurring subscriptions on BOT Chain, billed by the period.

A subscriber funds a balance. The merchant draws **one period at a time**,
never more, and only once that period has actually come round. Run the balance
down and the subscription lapses on its own — no card to decline, no retry
loop, no standing authority over an account.

## Three things a merchant cannot do

- **Cannot draw ahead.** One period, once it is due, and the contract enforces
  the clock.
- **Cannot hold your balance.** `withdrawBalance` works at any moment,
  including mid-term. Pulling your money simply means the next charge lapses
  the subscription.
- **Cannot retry forever.** Out of balance means lapsed, not a queue of
  attempts against your account.

## Charging is permissionless

Anyone can poke a subscription that is due. A merchant can batch their billing
run from any address, and a subscriber can prove the schedule is honest by
running it themselves. `charge(subId, maxPeriods)` catches up to 12 periods at
once, which keeps the loop bounded.

| Call | Who | What it does |
|---|---|---|
| `createPlan(name, price, periodSecs)` | anyone | Period 1–365 days |
| `setPlanOpen(id, bool)` | merchant | Stops newcomers; existing subscriptions keep running |
| `subscribe(planId)` | anyone but the merchant | Must fund at least one period; the first is charged immediately |
| `topUp(subId)` | subscriber | Adds coverage |
| `charge(subId, maxPeriods)` | **anyone** | Draws whatever is due |
| `cancel(subId)` / `withdrawBalance(subId)` | subscriber | Stop, and take the remainder back |
| `merchantWithdraw(planId)` | merchant | Collected periods minus `feeBps` (1.5% default, capped 5%) |

A pause blocks new plans and new subscriptions but never billing, cancelling or
withdrawal. `withdrawFees` is bounded by `accumulatedFees`.

## Build and deploy

```bash
npm install
npx hardhat test          # 17 tests
npm run deploy:testnet    # BOT Chain testnet, chain 968
npm run deploy:mainnet    # BOT Chain mainnet, chain 677
```

Create `.env` from `.env.example` with your `PRIVATE_KEY` first. The deploy
script prints the network name **and** the chain id.

After deploying, paste the address into `CONTRACT_ADDRESS` in
`frontend/index.html`. For mainnet also swap the five network values flagged in
the comment block directly above it, and set `label` to `"MAINNET"`.

## Frontend

Single file, no build step, ethers v6 from cdnjs. **Swiss style**: one grotesque
family, a rigid 12-column grid, flush-left ragged-right setting, hairline rules
and a single red. No ornament, no shadows, no radii, no icons. Plans are a
timetable rather than cards, and each subscription's periods are a row of
hairline ticks — the only graphic the style allows.

The page ends with the BOT Chain ecosystem footer, carrying links to
**botchain.ai** and the **block explorer**. The explorer href is read from the
`NETWORK` config at the top of the file, so the five-value mainnet swap updates
it too. No chain ID is printed anywhere on the page — these sites move from
testnet to mainnet, so a rendered chain ID would be wrong half the time.
