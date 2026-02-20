+++
draft = false
date = 2026-02-20
title = "xllify"
description = "xllify builds custom function add-ins for Microsoft Excel from prompts or code."
slug = "xllify-hello"
tags = ["xllify","data","excel","lua","acornsoft","greatest-hits","xll","excel add-in","luau"]
categories = ["projects"]
series = []
+++

**Excel is the original rapid application development tool.** People do unholy things to get the job done with no code, or perhaps with just a smattering of VBA. These solutions can be brilliant in the moment but, long term, tend to end up brittle and hard to extend.

Over the years there have been many approaches for extending Excel beyond formula soup and VBA. There is the excellent [Excel-DNA](https://excel-dna.net/), [PyXLL](https://www.pyxll.com/), Microsoft’s own [Office.js](https://learn.microsoft.com/en-us/office/dev/add-ins/reference/overview/excel-add-ins-reference-overview) and [Python](https://support.microsoft.com/en-gb/office/introduction-to-python-in-excel-55643c2e-ff56-4168-b1ce-9428c8308545) support, among others. Tools like Excel-DNA and PyXLL have made things easier, but they are still layers on top of the Excel C SDK. Office.js has its own quirks. Each comes with trade-offs around performance, platform requirements and developer tooling. Ideally, you want the benefits of the C SDK without ever having to touch it.

### Hello, xllify

> [xllify](https://xllify.com) lets you build custom function add-ins for Microsoft Excel from natural language prompts or code. Describe what you need in plain English, paste in an existing formula or some VBA, and xllify handles the rest.

You describe your functions, xllify compiles and packages them remotely, and you get a ready-to-use add-in (web or XLL) back in seconds.

xllify leans on a verified standard library of native C++ components for performance-critical operations, and the code assistant will only generate new code when it needs to. This means your functions get the benefit of battle-tested implementations wherever possible.

### How it works

xllify offers two flavours of add-in output:

- **Office Add-ins (WASM)** that work across Windows, macOS and Excel for the web. These can be previewed instantly in the browser with no setup at all, which is rather nice.
- **Native XLL builds** for Windows, which run in-process with Excel and support multi-threaded recalculation. These are compact, single-file assemblies with zero dependencies.

Two runtimes (WASM, native) run identical bytecode, so your functions behave the same regardless of which platform they end up on.

Your functions execute in a sandboxed VM with no access to the network or file system. Your data stays local, and there is no risk of add-ins being used as attack vectors. This was a key design goal from the start.

### Why this is good

- Describe what you want in plain English, or bring existing formulas and VBA
- No local tooling, no Windows machine, no Excel installation required to build
- Native performance on Windows through XLL, cross-platform reach through WASM
- Sandboxed execution for security and stability
- Instant preview in Excel for the web
- Compact, single-file add-ins with zero dependencies
- Sell it, share it, or deploy it internally

Now, all you need to do is describe what you want and xllify gives you a super-fast native XLL without ever touching the SDK.

### Pricing

We're still working on pricing — watch this space. There will always be a free tier.

### Give it a go

[xllify](https://xllify.com) is available now. If you have any questions or comments, drop me a line via [email](mailto:alex@xllify.com) or on [LinkedIn](https://www.linkedin.com/in/alexjreid/).
