# mybranch.dev

My personal [blog](https://blog.mybranch.dev), managed with `hugo`. It's basically an `nginx` image hosted on Google Cloud Run, which contains the generated site. Google Cloud Build is used to build and deploy.

## Workflow
Add markdown files to the posts directory and edit. Manage changes with git.

## Deploy steps
When a change is pushed to master, the site is rebuilt and deployed by Google Cloud Build.
- Clone git submodules (hugo theme, in this case)
- Run `hugo` via a custom builder (a Docker image containing the `hugo` binary)
- Copy the built site to an `nginx` image and push it to a registry
- Deploy the serving image to Cloud Run

See [cloudbuild.yaml](cloudbuild.yaml) to see how it all fits together.

## Why Cloud Run?
I don't believe you can believe anything written on a blog that isn't hosted by k8s. But as I'm not clever enough for that, Cloud Run is a fair substitute. ;)

Seriously though, I really liked using Cloud Run for another project and it seemed a simple way of getting off Medium. It has nice monitoring and dead simple support for custom domains. Which reminds me, I really couldn't be arsed with CloudFront.

There may be better approaches but it seems to work.
