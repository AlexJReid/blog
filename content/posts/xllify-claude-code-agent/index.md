+++ 
draft = false
date = 2026-02-17
title = "From prompt to Excel custom function in 30 seconds"
description = "Thanks to xllify + Claude Code agent"
slug = "xllify-claude-code-agent"
tags = ["data","excel","lua","greatest-hits","xll","excel add-in","luau","python","xllify","claude","ai"]
categories = []
externalLink = ""
series = []
+++

> [xllify](https://xllify.com) is a platform I've released for creating custom Excel functions by describing what you need or pasting some existing formulas or VBA. 

The resulting functions get packaged into a ready-to-deploy Office Add-in for all versions of Excel, as well as an optional-extra [native XLL build for Windows](https://xllify.com/xll-need-to-know).

Right now you can write your prompt for your functions in a [browser](https://xllify.com/web?web=1) or Excel add-in to iterate, debug and even manually code. A local dev experience seemed a good idea, so I experimented.

Anyway. The UNIX philosophy of Claude Code means that existing command line tools from xllify can be called to exercise the code that Claude has dreamed up, and even build a ready-to-go .xll as the final step.

We start with a frivolous prompt which gets picked up by the xllify agent.

![enter prompt](./1.png)

After burning some tokens, some [code](./victorian_compliment.luau) pops out.

![some code](./2.png)

Accept. #yolo. Now the agent uses existing tooling to check its work.

![testing](./3.png)

As a final step, the agent will ask whether to build it for Excel. Go!

![build xll](./4.png)

Loading the .xll into Excel, sure enough, I have a custom function. =VictorianCompliment

![function appears in excel](./5.png)

Which works!

![function in use](./6.png)

An Excel custom function from scratch with no code in 30 seconds. This was fun segue for an otherwise rainy and cold Tuesday morning!

This is all very frivlous.

> We're in an age where a bit of duct tape programming can do something that was unfathomable not so long ago. Take a step back and think about how this single prompt has enhanced existing incumbent software, conceived long before Claude was born (BC).

Integration of existing tools (pipes, again, the UNIX philosophy) and eliminating technical barriers so more people can get stuff done absolutely is progress.

But perhaps due to what is possible with low effort, we are in an era where random stuff gets thrown out, because AI. Most of it won't stick. We ought to question this "just because we can..." mentality but I suppose that's how we learn. Maturity will come with time. Meanwhile, it is fun to play.

Right now you can write your prompt for your functions ia [browser](https://xllify.com/web?web=1) or Excel add-in to iterate, debug and even manually code. A local dev experience using some of the ideas discussed in this post are coming soon.

If you've any questions about xllify [give me a shout](mailto:alex@xllify.com) or find me on [X](https://x.com/xllify) or Linked In.
