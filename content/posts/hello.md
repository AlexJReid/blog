+++ 
draft = false
date = 2020-01-19T21:05:54Z
title = "Hello, Goodbye (Medium)"
description = "Exciting blog migration story"
slug = "hello" 
tags = ['meta', 'gcp', 'cloud run', 'cloud build', 'medium']
categories = []
externalLink = ""
series = []
+++

# Hello, Goodbye (Medium)

I've been meaning to get off Medium for a while so decided to self-host my personal site. Things have changed quite a lot since the last time I did this, which is probably approaching twenty years ago.

At some point we decided to publish our thoughts via megacorps and VC-backed lunatics as it saved messing around with Apache configurations. We might look back upon this as being a Bad Thing.

I do appreciate the irony of that statement as I'm using the (free! thanks G! hopefully free...? better check that) cloud offering of a megacorp to get this content to you. At least I have a little bit more control.

Anyway, to be a bit meta, here's some info about the new setup.

The page you're seeing is coming from `nginx` image hosted on Google Cloud Run, which contains the generated site. Google Cloud Build is used to build and deploy.

## Workflow
Add markdown files to the posts directory and edit with any editor or online through Github. Manage changes with git. Couldn't be much simpler.

## Deploy steps
When a change is pushed to master, the site is rebuilt and deployed by Google Cloud Build.
- Clone git submodules (hugo theme, in this case)
- Run `hugo` via a custom Cloud Build builder (basically just a [Docker image](https://github.com/AlexJReid/blog/blob/master/_hugo-cloudbuilder) containing the `hugo` binary)
- Copy the built site to an `nginx` image and push it to a registry
- Deploy the serving image to Cloud Run

See [cloudbuild.yaml](https://github.com/AlexJReid/blog/blob/master/cloudbuild.yaml) to see how it all fits together. The code for this entire (one page!) site is in that repo.

## Why Cloud Run?
I really liked using Cloud Run for another project and it seemed a simple way of getting off Medium. It has nice monitoring and dead simple support for custom domains. Which reminds me, I really couldn't be arsed with CloudFront.

Getting it setup was easy enough. Cloud Shell is excellent, AWS should have similar.

There may be better approaches but it seems to work. I've very little clue about how hugo works as I only downloaded it a few hours ago. There's a tool to convert Medium articles to Markdown so I'll be trying that out next.
