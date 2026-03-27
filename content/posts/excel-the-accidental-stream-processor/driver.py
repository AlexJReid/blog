import asyncio
import random
import nats

BASE_PRICES = {
    "EURUSD": 1.0820,
    "GBPUSD": 1.2740,
    "USDJPY": 149.50,
}

SPREADS = {
    "EURUSD": 0.0002,
    "GBPUSD": 0.0002,
    "USDJPY": 0.03,
}

async def main():
    nc = await nats.connect("nats://localhost:4222")
    prices = dict(BASE_PRICES)

    while True:
        for pair, mid in prices.items():
            mid = mid * (1 + random.gauss(0, 0.0001))
            prices[pair] = mid
            spread = SPREADS[pair]

            bid = round(mid - spread / 2, 5)
            ask = round(mid + spread / 2, 5)

            await nc.publish(f"fx.raw.{pair}.bid", str(bid).encode())
            await nc.publish(f"fx.raw.{pair}.ask", str(ask).encode())
            await nc.publish(f"fx.raw.{pair}.mid", str(round(mid, 5)).encode())

        await asyncio.sleep(0.2)  # five ticks per second

asyncio.run(main())
