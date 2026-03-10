+++
draft = false
date = 2026-03-10
title = "zigxll: building Excel XLL add-ins in Zig"
description = "An open source framework for writing native Excel add-ins in Zig, and the foundation that xllify is built on."
slug = "zigxll"
tags = ["zig","xll","excel","excel add-in","xllify","nats","open-source","greatest-hits"]
categories = ["projects"]
externalLink = ""
series = []
+++

The [Excel C SDK](https://learn.microsoft.com/en-us/office/client-developer/excel/welcome-to-the-excel-software-development-kit) dates from the early 1990s. Memory management is manual, the type system is painful, and there's almost no tooling. Despite all of this, it remains the only way to build add-ins that run truly in-process with Excel, supporting multi-threaded recalculation and the full breadth of what the host application can do. If you want the best possible performance, you need an XLL. But it's a foot gun. One false move and you've corrupted memory and crashed Excel.

Enter [zigxll](https://github.com/AlexJReid/zigxll).

### What

zigxll is a Zig framework for building native Excel XLL add-ins. It wraps the C SDK so you never have to touch it directly. You define your functions in Zig, zigxll handles registration, type conversions, memory management and all the ceremony that the raw SDK demands.

A function definition looks something like this:

```zig
pub const MyFunction = ExcelFunction(.{
    .name = "MY.FUNCTION",
    .description = "Does something useful",
    .args = &.{
        .{ .name = "input", .description = "The input value" },
    },
    .handler = myHandler,
});
```

`zig build` produces a `.xll` file. Drop it into Excel and your functions are there.

### Why

I started building xllify and needed a solid foundation for the native XLL runtime. The existing options were C++ (painful), C# with Excel-DNA (great, but brings the CLR), or Python with PyXLL (similar trade-off). I wanted something that could produce small, self-contained binaries with no runtime dependencies, and that could cross-compile from macOS or Linux to Windows.

Wrapping the C SDK in C++ was the first attempt. It worked but was slow to build, hard to test, and every change felt like pulling teeth. I'd been curious about Zig for a while and it turned out to be an excellent fit.

### Why Zig

Zig can consume C headers directly. No bindings, no FFI layer, no code generation step. You just point it at the SDK headers and call the functions. This alone eliminated a huge amount of glue code.

Beyond that:

- **Comptime** lets you generate the boilerplate that the SDK demands (registration, type marshalling) at compile time from your function definitions. What would be macros or code generation in other languages is just normal Zig code that runs during compilation.
- **Cross-compilation works out of the box.** I develop on a Mac. `zig build` targets `x86_64-windows-msvc` and produces a working `.xll`. No Windows machine, no Visual Studio, no CI gymnastics required. The [xwin](https://github.com/Jake-Shadle/xwin) tool provides the Windows SDK and CRT libraries.
- **Allocator model** gives explicit control over memory. Arena allocators are used heavily, particularly in hot paths where per-call allocations would be wasteful.
- **Small binaries, no runtime.** The output is a compact DLL with zero dependencies beyond what Windows and Excel already provide.
- **Testing without Windows.** Unit tests for function logic run natively on whatever platform you're developing on. You don't need Excel or even Windows to validate your code.

### How it works, briefly

The SDK communicates through `XLOPER12`, a tagged union type that represents every value Excel can pass to or receive from an add-in. zigxll provides type-safe conversions between Zig types and `XLOPER12`, handling the UTF-8 to UTF-16 conversion that Excel requires.

When Excel loads the XLL, zigxll registers your functions with the host using metadata derived at comptime from your function definitions. When Excel calls a function, zigxll unmarshals the arguments, calls your handler, and marshals the return value back.

For async operations, a thread pool executes work off the main Excel thread. Results are cached and Excel is notified to recalculate. There's also support for building COM RTD servers in pure Zig for pushing live data into cells.

### Beyond demos: zigxll-nats

To prove zigxll could do something real, I built [zigxll-nats](https://github.com/AlexJReid/zigxll-nats), a NATS connector for Excel.

I've [written about NATS before](../nats-as-a-backend/) and I've had cause to play around with this kind of thing in Excel professionally. I know where it can break. Here's a tweet from 2023:

{{< rawhtml >}}
<blockquote class="twitter-tweet"><p lang="en" dir="ltr">Excel ❤️ <a href="https://twitter.com/nats_io?ref_src=twsrc%5Etfw">@nats_io</a> <br><br>(Excel is boring, of course. Boring tech is good. More of the world runs on it than we&#39;d admit sometimes!) <a href="https://t.co/v10nXMsf3B">pic.twitter.com/v10nXMsf3B</a></p>&mdash; Alex Reid (@AlexJReid) <a href="https://twitter.com/AlexJReid/status/1663161123108007938?ref_src=twsrc%5Etfw">May 29, 2023</a></blockquote> <script async src="https://platform.twitter.com/widgets.js" charset="utf-8"></script>
{{< /rawhtml >}}

That used Office.js and nats.ws which is a bit quirky, but straightforward enough. In simple scenarios not a bad shout, but in sheets with thousands of moving prices, it does not work at all. The only way to really do this properly is natively.

zigxll-nats lets you subscribe to NATS subjects and stream data directly into Excel cells:

```
=NATS.SUB("prices.AAPL")
```

An RTD server manages subscriptions and pushes updates as messages arrive. The result is a ~370KB binary with no dependencies on .NET, VSTO, or any COM infrastructure beyond what zigxll itself provides. It auto-registers on load without needing admin privileges.

The interesting bit from an implementation perspective is how memory is managed on the hot path. Arena allocators handle UTF-16 conversions during refresh cycles, so there are no per-message allocations on the critical rendering path. The handoff between nats.c's thread pool and Excel's RTD polling mechanism is lock-free.

This is still a proof of concept (hardcoded localhost, no auth, no TLS) but it demonstrates that zigxll can underpin something genuinely useful.

### Problems solved

Building this taught me a few things worth sharing:

- **The Excel C SDK is a hostile antique.** Microsoft's own documentation [states](https://learn.microsoft.com/en-us/office/client-developer/excel/programming-with-the-c-api-in-excel) that "the investment in time to obtain the understanding and skills that are required to write XLLs make this a technology impractical for most users." Behaviours differ between Excel versions, documentation is sparse. zigxll absorbs this pain so you don't have to.
- **COM in Zig is possible.** Implementing a COM RTD server without C++ or .NET sounded mad. It is mad. Claude wrote most of the code from my C++ implementation as a reference. But when you think about it, ATL and friends are a similar black box and, magic values aside, the Zig version is very readable. Zig's comptime is powerful enough to generate vtables and IUnknown implementations from interface definitions.
- **Cross-compilation changes the workflow.** Being able to develop, test, and build on a Mac and then copy the `.xll` to a Windows machine for integration testing is a huge quality of life improvement. CI is cheap too, as Linux runners handle the cross-compile.
- **Thread safety needs thought.** Excel's recalculation engine is multi-threaded. Getting the concurrency model right, particularly around async functions and RTD servers, required careful design. Zig's explicit approach to memory and lack of hidden control flow made this easier to reason about than it would have been in C++.

### What's next

zigxll is going to become the foundation of xllify's native runtime. If you're building Excel add-ins and are comfortable with Zig, this might save you from a lot of pain.

For zigxll-nats, the roadmap includes authentication, TLS, configurable server addresses, JetStream integration, message transformation, and publish support. If you have data flowing through NATS and people who live in Excel, this could be a useful bridge between the two worlds.

Both projects are MIT licensed.

- [zigxll on GitHub](https://github.com/AlexJReid/zigxll)
- [zigxll-nats on GitHub](https://github.com/AlexJReid/zigxll-nats)
- [xllify](https://xllify.com)

If you've any questions, [give me a shout](mailto:alex@xllify.com) or find me on [X](https://x.com/xllify) or LinkedIn.
