+++ 
draft = false
date = 2025-08-27
title = "Fast and easy Excel custom functions with xllify and Lua"
description = "When extending Excel with custom functions, the ancient Excel C SDK is notoriously hard to use and should be generally avoided. However..."
slug = "xllify-hello"
tags = ["data","excel","lua","acornsoft","greatest-hits","xll","excel add-in","luau"]
categories = []
externalLink = ""
series = []
+++

**Excel is the original rapid application development tool.** Developers can do unholy things to get the job done with no code, or perhaps with just a smattering of VBA. Long term, these solutions can end up brittle and hard to extend.

Over the years there have been many approaches for extending Excel beyond formula soup and VBA. There is the excellent [Excel-DNA](https://excel-dna.net/), [PyXLL](https://www.pyxll.com/), Microsoft's own [Office.js](https://learn.microsoft.com/en-us/office/dev/add-ins/reference/overview/excel-add-ins-reference-overview) and [Python](https://support.microsoft.com/en-gb/office/introduction-to-python-in-excel-55643c2e-ff56-4168-b1ce-9428c8308545) support, among others.

These technologies are far simpler and feature rich than the [Excel C Development Kit](https://docs.microsoft.com/en-us/office/client-developer/excel/welcome-to-the-excel-software-development-kit) and are actually well documented and supported. Lack of documentation, safety and ancient history complaints aside, we cannot escape the fact that in certain scenarios, the C API still takes the crown for absolute efficiency and performance. JavaScript interop performance (not the language itself) can be poor, and Microsoft’s own Python support involves a network call: enough said. Excel-DNA performance is great, but requires .NET skills and a Windows development environment.

### XLL hell?

When using the C API (or technologies like Excel-DNA that build upon it) an XLL is the built assembly, containing your code, destined for Excel. You load it into Excel by double clicking it, Application.RegisterXLL it with VBA... or install it so that loads when Excel does.

An XLL is just a DLL that exports key functions that enable its code to be loaded, unsafely, into Excel. A degree in technical archeology is recommended, or failing that an appreciation of all things 1990s. Pop some Nirvana (or Spice Girls) into your Sony MiniDisc player and delve in.

The C API brings with it bonus features such as dumping garbage into cells, crashing Excel and generally causing chaos. When used directly, one must exercise plenty of caution.

What if there was an easy way of leveraging the speed of the C API, safely exposed through a fast, yet simple scripting language, with no dependency hell or unfamiliar tooling?

### Hello, xllify

> [xllify](https://xllify.com) is remote build API that takes provided Lua functions and emits a signed, ready to go XLL to load into Excel.

Developers download a simple interpreter (for Mac, Windows, Linux) to develop and test their functions locally, ahead of submitting them to be compiled into an XLL.

A trivial example would be:

```lua
xllify.ExcelFunction(
    {
        name = "acme.ADD",
        description = "Adds two numbers",
        category = "Math",
    },
    function(a: number, b: number): number
        return a + b
    end
)

xllify.ExcelFunction(
    {
        name = "acme.RANDO",
        description = "Gives you a random number, you rando",
        category = "Math",
        volatile = true,
    },
    function(): number
        return math.random()
    end
)
```

This exposes `acme.ADD` and `acme.RANDO` to Excel, complete with inline documentation.

After compiling and installing the XLL (double click it), the above functions will be available as `=acme.ADD` and `=acme.RANDO`. That's it.

Developers can test their Lua implemented functions on any platform. No Windows machine, IDE, Office installation or anything like that is required - just the `xllify` CLI to run and validate their work locally. This is effectively a Lua interpreter preloaded with some libraries.

xllify embeds the Roblox implementation of Lua, [Luau](https://luau.org/library). Luau was used for [sandboxing](https://luau.org/sandbox) reasons so that potentially harmful Lua code cannot be run in the Excel process space. It also has a gradual typing system to provide useful type hints to the conversion process, and also help developers catch bugs early on.

### Works with GitHub Actions

Developers offer up their Lua code to xllify through the provided GitHub Action.

```yaml
jobs:
  runs-on: ubuntu-latest
  steps:
    xllify:
      - name: Build Excel add-in with xllify
        uses: acornsoftuk/xllify@v1
        with:
          XLLIFY_SECRET: ${{ secrets.XLLIFY_SECRET }}
          BUILD_ASSEMBLY_NAME: acme_addin.xll
          TARGET: Release-x64
          LUA:
            - acme.luau
```

Firstly, Lua code is compiled to bytecode, encrypted and signed. If the code compiles, it is then submitted to the xllify API, which will will remotely build and sign the XLL on Windows, using the necessary MSVC toolchain.

The developer does not incur Windows runner costs as the build happens elsewhere. Upon a successful build (within about 10-15 seconds), the built XLL assembly is downloaded back to the workflow's workspace. From there, the developer can add further steps to publish a release of their XLL for fun and profit.

### Why this is good

<style>
 .image-float-left {
    float: right;
    padding-right:15px;
    max-width: 40%;
    height: auto;
 }
  .clearfix::after {
     content: "";
     display: table;
     clear: both;
 }
</style>

<div class="clearfix">
<img src="./mincer.png" class="image-float-left" alt="Luau in, xll out">
<ul>
<li>Speed of development
<li>Speed of execution
<li>Simple <code>fn(x) => y</code> value in-value out scenarios require no Excel API knowledge
<li>Batteries included XLL with many handy functions exposed to the Lua environment already
<li>Tiny (~300KB) XLL with zero dependencies
<li>Built-in logging
<li>Develop, unit test and profile outside of Excel
<li>Developers do not need Windows
<li>Leverage existing Lua and C code
<li>Luau's sandbox for security and stability
</ul>
</div>

Developer quality of life almost always trumps raw performance. There is a certain contradiction in extolling the virtues of the speed of C and then diminishing that by coupling it to a scripting language. However, initial tests show that a careful and efficient stitching together of the two worlds can yield a happy balance between performance, safety and productivity.

### How does it work?

Really not much to see here. An XLL build is orchestrated with CMake; Luau and XLCALL32 are linked to form an XLL. There’s standard C++ glue to expose relevant aspects of the Excel SDK and marshal between XLOPER12 and friends, carefully managing memory and abstracting quirks - wide Pascal strings, memory ownership rules and other such fun. The Lua code is introspected and C wrappers generated so that the Lua functions are (indirectly) exported by the XLL.

The submitted Luau bytecode is packed into the assembly as a resource, which is loaded into the Lua environment when the add-in is loaded.

Customer builds run on segregated GitHub Actions Windows runners. Customer code is somewhat obfuscated through its compilation to bytecode, but a self-run solution to this is in the works, should code privacy be a concern.

Macros are a far more complex area but are also on the roadmap. There are also AI plans - it wouldn't be 2025 without them. More on this later.

### Availability

[xllify](https://xllify.com) will be available in September 2025, for free. You can register to be notified of general availability using your GitHub account. If you've any questions or comments, drop me a line via [email](mailto:alex@acornsoft.uk) or on [LinkedIn](https://www.linkedin.com/in/alexjreid/).
