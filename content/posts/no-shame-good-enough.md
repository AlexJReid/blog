+++ 
draft = false
date = 2014-11-21T10:00:59Z
title = "There's no shame in code that is simply good enough"
slug = "no-shame-good-enough" 
tags = ['software','greatest-hits']
categories = []
externalLink = ""
series = []
+++

Back in my early teens when I started developing what could loosely be called software, I didn't know what I was doing. If it compiled, ran and produced _mostly_ the expected results, then the job was done.

As a new programmer, I was immensely productive.

Of course, problems came when it was time to fix bugs or extend the software. It was often easier to just start again than to try and understand the rat's nest of poorly structured and unintelligible code.

Fast forward fifteen or so years and I had been fortunate enough to have had exposure to some huge, well architected and complicated systems, not to mention some extremely clever people. As a result I realised I knew nothing back then. In another ten years I'll probably think the same about my current knowledge and ability. But that's the nature of software engineering. You never stop learning and evolving.

I do however miss those naive days of being able to crank out code with such velocity. It was fun back then. Yeah, what I did then might have been inefficient and probably quite flawed. But for the most part, it worked and served a purpose.

Back in those days of youthful ignorance I didn't have the experience to know what could go wrong when I hit the database fifty times to service a request. That was learnt the hard way. I just ploughed ahead, thinking in functional terms about how the application would behave for a user. I didn't worry about code being performant or extensible or even dream of coming up with my own framework. No yak shaving, I just focused on the task in hand. This was perhaps a good mindset to have.

A decade later, I am not suggesting that we should lash things together in this way. It'd be silly to suggest we shun experience, knowledge of patterns and the advanced features of programming languages. Not to mention security. However, I found that as my knowledge increased, a tendency to obsess over tiny details relating to both scope and implementation and not produce anything at all, followed.

> "Will my peers think I am fool for using a TABLE element to display this on-screen calendar?"

> "This web service I am creating isn't really RESTful, but if I make it RESTful it'll be really slow."

> "Hmm. That query on a million records took over 75ms. Slow. <sad face>"

> "This won't scale very well with more than 1000 concurrent requests. <sad face>"

> "Yes, we're creating an online pizza shop but what if we want to support tapas or greek food as well? We may want to the ability to sell mountain bikes and custom coffee mugs using the same software at the some point…."

Would an engineer design a small bridge for a rural village so that it could support the weight of a thousand double decker buses? **No.** So why do we, as software engineers try to do exactly this? Why do we try to future-proof when we don't know constitutes as fit for purpose?

The day where all our hard work on that whizzy-architecture-where-it-is-just-a-small-config-change-to-do-anything will _finally_ pay off, sadly, might never come.

Why expend effort over-engineering software in places that you don't yet know are important? Sure, it'd be nice to get a background task running in one second rather than ten — but if it's a one off nightly scheduled job, does it matter?

**I have come to the conclusion that there is no shame in producing well considered, simple, fit-for-purpose code that is just good enough.**

To paraphrase _The Pragmatic Programmer_: **good enough doesn't imply half-arsed or lashed together.** It should concisely meet the requirements at hand, not what you think the requirements _might_ be next year. It doesn't mean you are naive and haven't considered the big picture, nor are you lazy or stupid. It doesn't mean you are a fool if you don't use wildcard generics and don't have a fetish for multiple inheritance.

I believe all developers should have a _geek valve_ that prevents them from introducing overly-generic, indecipherable black magic to a codebase. In spoken conversation you would look a bit unusual if you insisted on using flowery language to express a point that could be adequately conveyed in more standard terms. Some people may miss your point. The fact that their grasp of English isn't as advanced as yours doesn't make them stupid. It means you aren't communicating efficiently. Why can't the same logic apply to code? **Favour explicit and clear over clever.**

Software evolves over time, in some cases decades. If the architecture is kept as simple as it can be and is easily understood by all, on-going maintenance and evolution is likely to be a hell of a lot less risky. It will be more likely to be undertaken in a reasonable timeframe by anyone on the team. To me, that's true extensibility.

_Originally posted 2012 on my old blog. Unusually I agree with what I said back then. There was_ [_some discussion on Hacker News_](https://news.ycombinator.com/item?id=3412891) _about it at the time where it had briefly made the front page._