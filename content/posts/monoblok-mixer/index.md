+++
draft = false
date = 2026-05-01
title = "Plug into monoblok's mixer: when one core isn't enough"
description = "Mixer mode forks one worker monoblok per shard and routes by first subject token. The hot path stays single-threaded; you just have more of them."
slug = "monoblok-mixer"
tags = ["nats","zig","pub-sub","stream-processing","monoblok","patchbay"]
categories = ["projects"]
externalLink = ""
series = []
ShowToc = false
TocOpen = false
+++

[monoblok](/posts/monoblok/) is single-threaded by design. One `xev.Loop` owns the world. No locks, no atomics, no cache lines bouncing between cores. Lovely. Adding a second thread is a slippery slope that utterly betrays the simplicity of the original design, and a single core used well gets you embarrassingly far.

Luckily, NATS subjects are hierarchical, so a lot of the time the natural way to scale isn't _add threads inside one process_ but to identify the hot parts of the tree and give them their own process.

The empty-patchbay benchmarks on a MacBook Air M2 land somewhere between 3M and 11M msg/s depending on the workload, and even with 50 rules loaded the floor is around 5M msg/s. For the kinds of jobs monoblok is aimed at, sensor conditioning, market data demux, fleet telemetry, that's an awful lot of headroom on modest hardware. 

## Mixer mode

_Embarrassingly far_ is actually _good enough_ most of the time (I love these exacting terms.) That said, a few people have asked the obvious question: what happens when one core does run out? The obvious answer would be to pay for a faster core and have done with it. Nothing wrong with that, but it's wasteful.

Anyway, `monoblok 0.0.41` adds an experimental **mixer mode**, an approach that keeps the single-loop model intact.

```edn
(mixer
  :listen "tcp://0.0.0.0:4222"
  :workers
    ((:shard "SENSORS" :patchbay "examples/mixer-sensors.edn")
     (:shard "ORDERS"  :patchbay "examples/mixer-orders.edn")
     (:shard "*"       :patchbay "examples/mixer-default.edn")))
```

`monoblok --mixer cfg.edn` starts a stateless front-end process that spawns N worker processes (each itself a normal monoblok) and forwards each publish to the worker owning its first subject token. Clients connect to one NATS endpoint and never see the partitioning. The mixer is just a router; the workers do all the actual work, each on their own loop, on their own core.

A publish to `SENSORS.temp` lands on the SENSORS worker; `ORDERS.42` lands on the ORDERS worker; anything that doesn't match a named shard hits the catch-all. Workers are independent processes with independent patchbays, independent state, independent LVCs. The only coordination is the mixer choosing which socketpair to forward bytes down.

Subscriptions are coalesced. The mixer keeps one upstream SUB per unique filter no matter how many clients want it, so a hundred dashboards on the same filter look like one to the worker.

## Why not threads?

I am just-about intelligent enough to resist adding threads and start sharing structures with locks or atomics. 

Processes sidestep all of that. Each worker is a normal monoblok with no idea it's part of a fleet. The hot path inside a worker is identical to the hot path inside a standalone monoblok. State, including the LVC and rule state, snapshots and warm-starts per worker, exactly like before.

The cost is that state doesn't cross shards. `$LVC.SENSORS.>` lives on the SENSORS worker; the ORDERS worker has no idea it exists. If you want a rule to react to both sensor and order events, you'd need to put them on the same shard. In practice subject hierarchies usually map cleanly onto this constraint: the things that need to share state already share a prefix.

## Beyond one box

If your subject space is already organised by hierarchy (which it should be, NATS or otherwise) the same first-token discipline scales past one machine. Run independent monobloks on different hosts, each handling a subtree, sized to suit. There's no clustering, no quorum, no replication; if a process dies, systemd brings it back, and the upstream NATS bridge is the system of record for anything that's already been exported.

The same logic applies inside one box (fork more workers) and across boxes (run more monobloks); the partitioning is the same. If you happen to bridge monoblok output to a NATS cluster, your subjects are all reunited anyway.

## Try it

There's a runnable end-to-end demo [in the repo](https://github.com/lexvicacom/monoblok). It starts a mixer with three shards (SENSORS, ORDERS, catch-all), publishes a handful of messages from one client connection, and shows the conditioned output coming back from three separate worker processes through the single endpoint.

```sh
git clone https://github.com/lexvicacom/monoblok
cd monoblok
zig build
python examples/mixer.py
```

Mixer mode is considered experimental; there are rough edges around SUB routing, worker restarts, and observability. There's no exact formula for sizing either. One worker per subtree-that-matters is the right shape, but cramming 96 workers onto an 8-core box is asking for trouble. Every worker is a real process with its own loop, and once they outnumber the cores you're paying context-switch tax on every publish, almost certainly worse than one well-tuned monoblok would have been on its own. Some experimentation needed.

One detail I'm pleased with: the mixer-to-worker hop runs over inherited socketpairs rather than TCP or a unix socket. The fd is open on both sides from fork; no addressing, no lookup, just bytes.

If you've thoughts or want to chat about this sort of thing, [give me a shout](mailto:alex@lexvica.com) or find me on [X](https://x.com/AlexJReid) or [LinkedIn](https://www.linkedin.com/in/alexjreid/).
