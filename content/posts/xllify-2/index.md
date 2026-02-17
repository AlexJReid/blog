+++ 
draft = false
date = 2027-11-18
title = "xllify is out"
description = "... with a few pivots along the way"
slug = "xllify-released"
tags = ["data","excel","lua","python","greatest-hits","xll","excel add-in","luau","python","xllify"]
categories = []
externalLink = ""
series = []
+++

Back in August, I [introduced xllify](../xllify-hello/). This was a project I started when in-between contracts.

I've since distilled my definition of xllify to:

> [xllify](https://xllify.com) is a packaging tool and runtime that allows functions written in Luau and Python to be used as high-performance custom functions in your Microsoft Excel workbooks.

[Go have a look!](https://xllify.com)

Things have _evolved_. As with all projects, I try to ruthlessly simplify and make things faster.

In no particular order, here's what changed:

- CMake is no longer used to build end user XLLs. Instead a single 3MB executable manipulates a cached template DLL to stamp the user's code into it. This takes under a second.

- There's no need to do a C++ build for each user XLL. A lot of tricks to make the C++ build as fast as possible (maybe 1 minute) were discarded. Encapsulating the C++ build was a huge selling point of the GitHub Action approach, now somewhat irrelevant thanks to the simplicity of the `xllify` tool and 1-sec builds. GHA remains (and the action even has the same interface) but is now a much simpler affair.

- Async support was added for Luau. This is quite neat in that we can leverage Luau's coroutines. Users do not need to do anything special to use non-blocking functions. When a non blocking function is called, the user's Luau code yields its thread back to the worker pool. The original Luau state is locked and owned by the user's Luau code until the async operation completes. Upon completion, the Luau state is resumed, potentially on a different worker thread so that it can carry on. When the function completes, the Luau state is released back into the pool. Controlling the worker and state pool sizes gives control over resource usage.

- Python support was introduced. Maybe this was premature, but there is no escaping the noise and ecosystem around Python. Although Lua(u) is a cool language, people might connect better with Python. I didn't want being Luau to be a barrier to adoption.

- Python functions run as external processes. Other languages can adopt the same protocol. It uses named pipes and shared memory for IPC, so it is still fast. Running external processes is great because we can startup n Python processes and load balance between them, using more than one core.

- External process communication is through [ZeroMQ](https://zeromq.org/) - an old but tried and tested networking library/abstraction. Old but works.

- For both Luau async and external processes, an RTD server is used to manage the completion of an async operation. The pattern is: new function generates a new topic (cache miss), RTD server awaits feedback from the process to say it is complete. Before signalling completion, the process writes to a cache within the Excel process. When the RTD server notifies Excel it has new data, this triggers a recalculation causing a cache hit. The cell becomes a plain, old "value" cell and not an RTD function call. This has the happy side effect of cleaning up the RTD topic.

- An RTD server was implemented in C++ to achieve the above! This was **tricky**.

- A Python SDK was implemented to converse with the XLL and RTD server. This paves the way for other SDKs to be written easily such as C++, Go and Rust.

- Python add-ins extract their embedded code and have their processes started by Excel. On first run, a virtual environment is created and any dependencies installed, if a requirements.txt was included in the build.

- xllify-lua was implemented as a test harness and runner to exercise Luau scripts.

- Support for streaming data, the idea behind [rtd.pub](../rtdpub-hello) lives on and will be implemented next probably

- Mac support was considered and is in theory achieveable, but is on hold.

I'm sure there's more on the list. It has been a journey! Whether or not adoption will come, who knows - but it feels good to put out a solo LP for the first time in years.

If you've any questions about xllify [give me a shout](mailto:alex@xllify.com) or on [X](https://x.com/xllify).
