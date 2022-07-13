+++ 
draft = false
date = 2022-07-12T00:03:12Z
title = "Patching in a development service"
description = "It is not always feasible to run an entire system composed from microservices locally. This post discusses using a service mesh to 'patch' a locally running service into a remote test environment, for development purposes."
slug = "patching-in-a-development-service" 
tags = ['api', 'service mesh', 'envoy', 'consul', 'http', 'microservices', 'dev environment', 'local dev', 'tailscale']
categories = []
author = "Alex Reid"
externalLink = ""
series = []
+++

![Patch cables](cover.jpg)

Microservices have been commonplace for several years now. They provide many benefits but also some drawbacks, one of which is increased complexity when attempting to run a system of composed of them locally when developing.

Suppose the system you are working on consists of hundreds of discrete services that all potentially make requests to one and other. If you are unlucky you might be faced with the task of spinning _everything_ up locally or within a new cloud provider account. 

This is costly and probably too much work, so you might be inclined to blindly deploy to a test or staging environment, with a high probability of breaking things for other users. You are also likely to suffer a long feedback loop with every single change requiring a build and deployment.

An alternative idea is to _patch in_ a new implementation of your service from a local environment into a full fat test environment.

## A contrived scenario
Imagine that we have a service with the resource `/message` that returns `Hello world!!!`. It also provides the subresources `/message/lower` and `/message/upper` which return lower and uppercase representations of the same string. 

```
$ curl https://some-service.test-env-1.mycompany.com/message
Hello world!!!
$ curl https://some-service.test-env-1.mycompany.com/message/lower 
hello world!!!
$ curl https://some-service.test-env-1.mycompany.com/message/upper
HELLO WORLD!!!
```

Unfortunately, as our former selves had a shameful past of being microservice astronauts, the case transformation happens in another service instead of being a local function call. To make matters worse, the transformation service runs on a Windows EC2 instance and cannot be run locally. As our team does not own this service, we cannot rewrite it. The team that owns it have warned us that it incorrectly interprets certain extended characters and a _correct_ implementation would actually cause huge problems to other services that have worked around it. Let's let sleeping dogs lie.

Anyway, our stakeholders have decided that three exclamations after `Hello world` is excessive and a waste of bandwidth, so we have been tasked to create a new version of the service with only one.

As we are risk averse, we want to make the changes in a **local** environment and have those changes visible in the **remote test** environment. A locally running service should be able to interact with the service it ordinarily calls.

**We are patching the local service into the environment so that it appears the same as a deployed service.**

## Approach
A service mesh is a way of connecting services together to build a secure, observable and malleable system. [HashiCorp introduces the concepts more fully in this video](https://www.consul.io/docs/connect). Consul and Envoy Proxy are used to form this example service mesh.

The test environment is running within a cloud provider. My local development machine, `whitby`, is on the same network, thanks to a [Tailscale](https://tailscale.net) VPN. 

![Tailscale machine list](tailscale-machines.png)

We can see the test environment has a single node in Consul where all of the services are running.

![Consul nodes](consul-nodes.png)

For this example scenario, we are running services called `message` and `transform`. `message` makes calls to the `transform` service.

![Service topology](service-topology.png)

Services within the mesh are accessed from the outside via an _ingress gateway_ also shown here. This is where the above `curl` commands are issued. It is the entry point into the environment. The ingress gateway is configured to accept ingress into the `message` service, but not `transform`. Requests to `transform` can only originate within the mesh.

The test environment uses Nomad to schedule the services running as Docker containers, but this is irrelevant really. The service instances would look the same if they were running on AWS ECS, Kubernetes, VMs... or a development machine, as we will soon see.

![Consul services](consul-services.png)

To patch in to the test environment, I start a Consul agent on my local machine, ensuring the Tailscale IP is used and enabling gRPC, which is how the Envoy communicates with it as a control plane.

```bash
$ consul agent -retry-join mesh...tailscale.net \
    --advertise $(tailscale ip -4) \
    --data-dir /tmp/consul \
    -hcl 'ports { grpc = 8502 }'
```

![Consul nodes with local addition showing](consul-local-node.png)

As we need to make changes to the `message` service, it is registered with this local Consul agent. The configuration is largely the same as a deployed version of the service, only with different metadata. This is important as it means that we can isolate this instance of the service later on.

The configuration also references the `transform` service. As the `transform` service is within the mesh with no external ingress configured, a non-mesh client cannot just connect to it directly as mTLS is used between services. This means that the `message` service can do a dumb HTTP request to localhost, offloading  mTLS to Envoy, thus respecting any constraints configured in the service mesh.

```hcl
service {
    id = "ajr-local-fix"
    name = "message"
    port = 5001
    meta {
        version = "local"
    }
    connect {
        sidecar_service {
            proxy {
                upstreams {
                    destination_name = "transform"
                    local_bind_port  = 4001
                }
            }
        }
    }
}
```

```bash
$ consul services register message-service.hcl
Registered service: message
```

To receive traffic, Envoy is started. Consul configures it for us.

```bash
$ consul connect envoy -sidecar-for ajr-local-fix
```

The service appears as an instance alongside the _real_ deployed instance. 

![Service instance](service-instance.png)

Finally, the service itself can be started. 

```bash
$ PORT=5001 MESSAGE="Hello world!" TRANSFORM_SERVICE_URL=http://localhost:4001 \
    ./routing-demo
```

Note the `TRANSFORM_SERVICE_URL` environment variable. This is the URL that the local process can address a remote version of the `transform` service, via Envoy. The port was defined in the above service registration.

The big moment. **We get traffic to both the deployed and locally running service.**


```bash
$ curl https://some-service.test-env-1.mycompany.com/message # local
Hello world!
$ curl https://some-service.test-env-1.mycompany.com/message # live
Hello world!!!
$ curl https://some-service.test-env-1.mycompany.com/message/upper # local
HELLO WORLD!
```

## L7 configuration entries to the rescue
This is great, but both service instances are receiving requests in a round robin. It would be better to guard the local version so that it only receives traffic when a certain condition is met, such as an HTTP header being present and containing a certain value. This can be achieved with a service resolver and service router.

Firstly we define the resolver which uses service metadata to form _subsets_ of the service instances. Using metadata specified when the service is registered in Consul, the sets can be defined with a simple expression.

```hcl
Kind = "service-resolver"
Name = "message"
DefaultSubset = "live"

Subsets {
    live {
        Filter = "Service.Meta.version == v1"
    }
    local {
        Filter = "Service.Meta.version == local"
    }
}
```

A router allows us to direct traffic to those subsets with some simple rules. Note that if none of the rules defined below match, the default subset, `live` is used.

```hcl
Kind = "service-router"
Name = "message"

Routes = [
    {
        Match {
            HTTP {
                Header = [
                    {
                        Name  = "x-debug"
                        Exact = "1"
                    }
                ]
            }
        }
        Destination {
            ServiceSubset = "local"
        }
    }
]
```

Applying these entries causes the routing logic to be reflected within a few seconds.

```bash
$ consul config write resolver.hcl 
Config entry written: service-resolver/message
$ consul config write router.hcl 
Config entry written: service-router/message
```

![Consul routing](consul-routing.png)

```bash
$ curl -H "x-debug: 1" https://some-service.test-env-1.mycompany.com/message # local
Hello world!
$ curl https://some-service.test-env-1.mycompany.com/message # live
Hello world!!!
```

The output from the local `message` service instance can be changed by restarting it with a different environment variable. The change is immediately available to **anyone who has access to the environment and knows the pass the `x-debug: 1` header.** There was no need for a redeploy.

```bash
$ PORT=5001 MESSAGE="Local hello world" TRANSFORM_SERVICE_URL=http://localhost:4001 \
    ./routing-demo

$ curl -H "x-debug: 1" https://some-service.test-env-1.mycompany.com/message/upper
LOCAL HELLO WORLD
```

The L7 routing constructs in Consul are very flexible. Perhaps we do not want to pass a header around to use the local version and instead we want to capture all requests made to the `/message/upper` subresource and send all other traffic to the `live` deployed version. This is a minor change to the service router.

```hcl
Kind = "service-router"
Name = "message"

Routes = [
    {
        Match {
            HTTP {
                PathExact = "/message/upper"
            }
        }
        Destination {
            ServiceSubset = "local"
        }
    }
]
```

![Consul routing 2](consul-routing-2.png)

Notice that as the routing logic is now different, the `x-debug: 1` header no longer needs to be sent as part of the request.

```bash
$ curl https://some-service.test-env-1.mycompany.com/message
Hello world!!!
$ curl https://some-service.test-env-1.mycompany.com/message/upper
LOCAL HELLO WORLD
```

**This is a great example of using resolvers and routers to to _patch_ a service at the resource level.** We can apply the _strangler pattern_ to older services, by gradually overriding resources and pointing them to a new implementation, while sending _everything else_ to the old implementation. 

These mechanics can be applied to a blue-green or canary deploy, where traffic is routed between different deployed versions of a service. This arrangement could be for a few minutes during a deployment, or for several months as part of a longer running migration project.

## Drawbacks and TODOs
Astute readers will have noticed I have not mentioned security, namely ACLs and certificates. These are an essential ingredient to ensuring that only trusted services can join the mesh.

It is likely that this approach is only appropriate for test environments. It would be a bad idea to attempt on a production environment, unless you have a clickbait blog post cued up: _I accidentally put my laptop into production and here's what happened!_

Perhaps the biggest technical flaw is running a Consul agent locally. Consul agents are designed to run within the same data center with a low latency (< 10ms). An alternative approach would be to provision a remote Consul agent on-demand (or make a pool available to developers), but continue to run Envoy locally. This would require some additional configuration but is likely to work. 

Along the same lines, this latency problem goes away if the exact development setup detailed here happened to be on a remote VM on the same network as the rest of the Consul agents. [Remote development](https://code.visualstudio.com/docs/remote/vscode-server) is a very interesting topic.

There is a lot going on here but the ideas presented could be abstracted by some scripts to automate and simplify the process so that it is almost invisible to developers.

## Conclusion
In the example scenario we have:

- started a local version of the service
- patched it into a real test environment
- seen requests to the environment be routed to the local service as dictated by matching rules
- seen the local service call out to the transformation service **through the service mesh**
- seen how the local service can be called by other mesh services to test integrations
- made changes to the local service and seen the changes immediately without redeploying

**I only needed to run the service I was working on locally.**

What I particularly like about it is the rapid feedback loop. I was able to patch a local implementation of the `message` service into a real environment and make changes to it without redeploying. I could potentially attach a debugger or REPL to the running process for even more insight into the running of my development service.

_As usual, I'd love to know what you think. Comments and corrections are always welcome._

[Discuss on Twitter](https://twitter.com/search?q=https%3A%2F%2Falexjreid.dev%2Fposts%2Fpatching-in-a-development-service%2F&src=typed_query&f=top)


## Links
- Image credit: photo by [John Barkiple](https://unsplash.com/@barkiple?utm_source=unsplash&utm_medium=referral&utm_content=creditCopyText) on [Unsplash](https://unsplash.com/photos/xWiXi6wRLGo?utm_source=unsplash&utm_medium=referral&utm_content=creditCopyText)
- [Consul L7 Traffic Management](https://www.consul.io/docs/connect/l7-traffic) describes service resolvers, routers and splitters in more detail.
