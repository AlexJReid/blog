+++
draft = false
date = 2026-04-21
title = "Monoblok: a tiny NATS-ish pub/sub server that conditions noisy feeds before they fan out"
description = "An experimental, partially NATS-compatible pub/sub daemon with last-value streams and an S-expression signal-routing and conditioning DSL, all in a single binary."
slug = "monoblok"
tags = ["nats","zig","pub-sub","stream-processing","monoblok","patchbay"]
categories = ["projects"]
externalLink = ""
series = []
+++

I've been tinkering with [monoblok](https://github.com/lexvicacom/monoblok), a small partially NATS-compatible pub/sub daemon written in Zig. Two things make it interesting: a last-value cache on every subject, and a routing DSL called **patchbay** that lets you filter, smooth and re-publish messages at the broker, before any subscriber sees them.

![monoblok](./monoblok.png)

It is firmly an experimental toy at this point but the ideas are nice and the surface area is small enough to actually understand in an afternoon.

## What's in the box

A single-threaded event loop sat on top of the excellent [libxev](https://github.com/mitchellh/libxev), so you get kqueue, io_uring, epoll or IOCP depending on where you run it. No threads, no locks, zero-copy fan-out. It speaks enough of the NATS wire protocol that an off-the-shelf NATS client can connect, `SUB` and `PUB`, which is rather convenient because it means you can drop it in alongside existing tooling without writing a client library first.

The two features worth talking about:

**The last-value cache (LVC).** Every subject has an implicit cache of its most recent value. Subscribe to `$LVC.foo.bar` and you immediately receive the cached value (if any), then the live stream of subsequent publishes. Wildcards work too. It's on by default and costs a couple of percent overhead.

**Patchbay.** A small S-expression DSL that runs at the broker, per message. You write rules of the shape `(on SUBJECT-FILTER BODY)` and the body gets evaluated when an incoming subject matches. The vocabulary borrows heavily from electronics: `squelch` to suppress duplicates, `deadband` to ignore small wobbles, `quantize` to snap to a grid, plus a family of O(1) windowed aggregates (`moving-avg`, `moving-max` and friends).

Here's the canonical example from the readme:

```clojure
(on "sensors.*"
  (-> payload-float
      (round 1)
      (squelch)
      (publish-to (subject-append "stable"))))
```

Round to 1 decimal place, drop it if it hasn't changed, republish to `sensors.<whatever>.stable`. That's the lot.

## A real-ish scenario

Let's wire something up that actually shows off both features together. Pretend we're running a small fleet of temperature sensors in an office building. Each sensor publishes a reading every few seconds on `temp.<floor>.<room>`. The raw stream is noisy: sensors jitter, the value wobbles by a tenth of a degree constantly, and most readings are functionally identical to the previous one. It turns out the facilities team has been buying their sensors from Temu.

What we want:

1. A clean "stable" stream that downstream dashboards can render without flickering.
2. A separate alert subject when the temperature in a room climbs above a threshold (in Celsius) sustained over a window, not just a single spike from someone leaning on the sensor.
3. Anyone opening a dashboard at any time should see the current reading immediately, without waiting for the next publish.

That last requirement is the one that usually causes pain. With a vanilla pub/sub broker you end up bolting on a key-value store, or a "snapshot on connect" service, or asking the publisher to also write to a database. Before you know it you have a Rube Goldberg contraption involving Redis, a K8s cluster, load balancers and a partridge in a pear tree. With monoblok it's a subscription pattern.

### The patchbay rules

```clojure
;; Round to 1dp, ignore wobbles under 0.3°C, republish for dashboards
(on "temp.*.*"
  (-> payload-float
      (round 1)
      (deadband 0.3)
      (publish-to (subject-append "stable"))))

;; Sustained heat alert: 60-sample moving average above 28°C
(on "temp.*.*"
  (when (> (moving-avg 60 payload-float) 28.0)
    (publish (subject-append "alert") payload)))
```

Two rules. The first turns a chatty sensor feed into a change-only stream. The second uses a windowed aggregate to avoid alerting on a single spike. State is per rule, per subject, so floor 3 meeting room 2 has its own ring buffer that doesn't interfere with the kitchen on floor 1.

A subscriber wanting clean data subscribes to `temp.>.stable`. A subscriber that only cares about alerts subscribes to `temp.>.alert`. Neither needs to know anything about how the conditioning happens.

### Where the LVC earns its keep

Now imagine the dashboard. It's a browser tab. Someone opens it at 14:32 and wants to see the current temperature for every room, immediately, then live updates as new readings come in.

Without an LVC you've got a chicken-and-egg situation. You can subscribe to `temp.>.stable` but you'll only see values as they change. If the kitchen has been quiet for ten minutes, the dashboard shows nothing for the kitchen until the next publish. So you build a snapshot endpoint, or a key-value bucket, or you nag the publisher to send a heartbeat.

With monoblok, the dashboard subscribes to `$LVC.temp.>.stable`. The broker delivers the most recent cached value for every matching subject right away, then transitions to live streaming. One subscription, no race condition, no separate snapshot service. Open the tab, see the current state, watch it update.

The same trick works for the alerts subject. A new on-call engineer joining mid-shift can subscribe to `$LVC.temp.>.alert` and immediately see whatever the last alert was, rather than waiting for the next one to fire.

It's quite nice how the conditioning rules and the LVC compose naturally. Rule-generated publishes participate in caching just like any other publish. The `temp.3.kitchen.stable` subject has its own LVC entry, populated by the patchbay rule, available to any late-joining subscriber. You didn't have to think about it; it just works.

## Benchmarks

Because monoblok speaks the NATS wire protocol, it was nice to benchmark it using the existing `nats bench` commands.

Obvious caveat: `nats-server` is a mature Go codebase with a decade of production history behind it, and I ran these with an empty patchbay so they measure raw broker work only. With that out of the way, on an M2 Air monoblok keeps up on single-publisher throughput (6.12M vs 6.18M msg/s for 64B payloads) and pulls ahead on fan-out as subscriber count grows (8.01M vs 6.70M msg/s at 50 subscribers). On a small 2-core Linux VM with the io_uring backend it's a similar story: behind on the single-subscriber fan-out case, ahead at 50 subscribers (4.51M vs 3.28M msg/s). Throughput will drop from these figures in proportion to how much your rules do, but it's a respectable starting point. NATS is still the thing you'd want in production.

## Sitting in front of a real NATS cluster

Attaching monoblok to a real NATS cluster is on the cards. The idea is that monoblok would sit out at the edge as a front-end to NATS, doing all the conditioning, deduplication and windowed aggregation work close to the publishers, then forwarding the cleaned-up streams into the main cluster for durability, replication and everything else NATS already does well. You get the patchbay primitives where they're useful without having to give up the production-grade broker behind them. Of course, if you're only experimenting, SUBscribing directly to monoblok subjects is fine.

## Why I find this interesting

The conventional split is "broker moves bytes, application does logic." That's fine and largely correct, but there's a category of logic, signal conditioning, that you could argue belongs at the broker. It's stateless from the application's point of view, it's the same boring code reimplemented in every consumer, and it benefits enormously from being applied once, centrally, before fan-out.

Putting a small DSL at the broker for this kind of work is a nice middle ground. It's not trying to be Flink, Beam or Kafka Streams. It's just a few primitives, declared once, that turn raw sensor noise into something useful before it ever leaves the broker. The LVC then makes late-joining subscribers a non-event, which is the other thing every realtime app ends up reinventing.

It's just a toy but the applications are endless. Swap office temperature sensors for market data ticks where you want to deadband out the noise and only emit on meaningful moves, fleet telemetry from a few thousand vehicles where most of the GPS jitter is uninteresting, IoT estates with flaky sensors that need smoothing before anyone trusts the readings, gaming or trading dashboards where late-joining clients shouldn't have to wait for the next event to see current state. **Same primitives, different domain.**

There are a few loose ends to tidy up: a TTL on last-value cache entries so stale state doesn't linger forever or grow unbounded, proper structured logging, the leaf-node path mentioned earlier (potentially as an actual NATS leaf rather than a bespoke bridge) so it can plug into a real cluster cleanly, and a resilience story for when the process inevitably falls over.

The code lives at [github.com/lexvicacom/monoblok](https://github.com/lexvicacom/monoblok) and there are both x86 and ARM Linux builds ready to go on the [releases page](https://github.com/lexvicacom/monoblok/releases) if you want to skip the build step and give it a spin.

If you've thoughts or want to chat about this sort of thing, [give me a shout](mailto:alxsti3@gmail.com) or find me on [X](https://x.com/AlexJReid) or [LinkedIn](https://www.linkedin.com/in/alexjreid/).
