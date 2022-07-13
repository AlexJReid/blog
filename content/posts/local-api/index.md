+++ 
draft = false
date = 2022-07-12T00:03:12Z
title = "Patching in a development service"
description = "It is not always feasible to run an entire system composed from microservices locally. This post introduces an experimental approach for patching a local implementation into a remote test environment for development purposes."
slug = "patching-in-a-development-service" 
tags = ['api', 'service mesh', 'envoy', 'consul', 'http', 'microservices', 'dev environment']
categories = []
author = "Alex Reid"
externalLink = ""
series = []
+++

![Patch cables - John Barkiple](john-barkiple-l090uFWoPaI-unsplash.jpg)

Microservices have been commonplace for several years now. While this is not a post about them being better or worse than a well-structured monolith (as usual, it depends), it is absolutely the case that they can introduce complexity, particularly when running them locally. 

Suppose the system you are working on consists of hundreds of discrete services with a spider web of dependencies. If you are unlucky and need to get a complete environment running to try out your proposed changes, you might be faced with the task of spinning _everything_ up locally or within a new cloud provider account. This is costly and probably too much work, so you might be inclined to simply YOLO and deploy to a test or staging environment, potentially breaking things for other users. You will likely suffer from a slow feedback loop with every single change requiring a build and deployment.

An alternative idea is to _patch in_ a new implementation of your service from your local environment into a full fat test environment. I have had some ideas on how this might work. Note that it is just an experiment. Your mileage may vary.

My approach is based on a service mesh: a way of connecting services together to build a secure, observable and malleable system. A service mesh consists of a control plane that accepts configuration changes and dynamically applies generated configurations to a data plane. The data plane actually does the work of serving the requests. In this example Consul is the control plane and Envoy Proxy is the data plane. [HashiCorp introduces the concepts more fully in this video](https://www.consul.io/docs/connect).

Consul has a [set of configuration entries](https://www.consul.io/docs/connect/l7-traffic) that can be used to control where a request is sent. It allows us to form subsets of services based on deployment attributes and then route to them, based on the attributes of an incoming HTTP request.

## A contrived scenario
Imagine that we have a service with the resource `/message` that returns `Hello world!!!`. It also implements subresources `/message/lower` and `/message/upper` which return lower and uppercase representations of the same string. 

```
$ curl http://some-service.test-env-1.mycompany.com/message
Hello world!!!
$ curl http://some-service.test-env-1.mycompany.com/message/lower 
hello world!!!
$ curl http://some-service.test-env-1.mycompany.com/message/upper
HELLO WORLD!!!
```

Unfortunately, as our former selves had a shameful history of being microservice astronauts, the case transformation happens in another service instead of being a local function call. To make matters worse, the transformation service runs on a Windows EC2 instance and cannot be run locally. As our team does not own this service, we cannot rewrite it. The team that owns it have warned us that it incorrectly interprets certain extended characters and a _correct_ implementation would actually cause huge problems to other services that have worked around it. Let's let sleeping dogs lie.

Anyway, our stakeholders have decided that three exclamations after `Hello world` is excessive, so we are tasked to create a new version of the service with only one. We want to make the changes in my **local** environment and have those changes visible in the **remote test** environment. A locally running service should be able to interact with any dependencies (for instance, the transformation service) as if it were deployed. It should also be able to receive ingress from any services that call it.

## Approach
_The rest of this post assumes some degree of experience with HTTP, networking and Consul and Envoy itself._

The test environment is running within a cloud provider. My local development machine, `whitby`, is on the same network, thanks to a [Tailscale](https://tailscale.net) VPN. 

![Tailscale machine list](tailscale-machines.png)

We can see the test environment has a single node in Consul where all of the services are running.

![Consul nodes](consul-nodes.png)

For this example scenario, we are running services called `message` and `transform`. `message` makes calls to the `transform` service.

![Service topology](service-topology.png)

Services within the mesh are accessed from the outside via an _ingress gateway_ also shown here. This is where the above `curl` commands are issued. It is the entry point into the environment.

The test environment uses Nomad to schedule the services running as Docker containers, but this is irrelevant really. The same would apply if it were AWS ECS, Kubernetes or VMs.

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

The configuration also references the `transform` service. As the transformation service is within the mesh with no external ingress configured, a non-mesh client cannot just connect to it directly as mTLS is used between services. _Connecting in this way means the service can do a dumb HTTP request to localhost, hiding any complexity and respecting any security constraints or limitations defined within the service mesh._

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

Note the `TRANSFORM_SERVICE_URL` environment variable. This is the URL that the local process can address a remote version of the `transform` service, via Envoy.

The big moment. **We get traffic to both the deployed and locally running service.**

```bash
$ curl http://some-service.test-env-1.mycompany.com/message # local
Hello world!
$ curl http://some-service.test-env-1.mycompany.com/message # live
Hello world!!!
$ curl http://some-service.test-env-1.mycompany.com/message/upper # local
HELLO WORLD!
```

## L7 configuration entries to the rescue
This is great, but it would be better to guard the local version so that it only receives traffic when a certain condition is met, such as an HTTP header being present and containing a certain value. This can be achieved with a service resolver and service router.

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
$ curl -H "x-debug: 1" http://some-service.test-env-1.mycompany.com/message # local
Hello world!
$ curl http://some-service.test-env-1.mycompany.com/message # live
Hello world!!!
```

We can change the local service by restarting it with a different environment variable value for message and see the results instantly, as can **anyone else who has access to the environment and knows the pass the `x-debug: 1` header.**

```bash
$ PORT=5001 MESSAGE="Local hello world" TRANSFORM_SERVICE_URL=http://localhost:4001 ./routing-demo 
$ curl -H "x-debug: 1" http://some-service.test-env-1.mycompany.com/message/upper
LOCAL HELLO WORLD
```

The L7 routing constructs in Consul are very flexible. Perhaps we do not want to pass a header around to use the local version. Maybe we want to capture all requests made to the `/message/upper` subresource and send all other traffic to the `live` deployed version. This is a minor change to the service router.

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
$ curl http://some-service.test-env-1.mycompany.com/message
Hello world!!!
$ curl http://some-service.test-env-1.mycompany.com/message/upper
LOCAL HELLO WORLD
```

This is a great example of using resolvers and routers to to _patch_ a service at the resource level. We can apply the _strangler pattern_ to older services, by gradually overriding resources and pointing them to a new implementation, while sending _everything else_ to the old implementation. 

These mechanics can be applied to a blue-green or canary deploy, where traffic is routed between different deployed versions of a service. This arrangement could be for a few minutes during a deployment, or for several months during a longer migration project.


## Drawbacks
Astute readers will have noticed I have not mentioned ACLs or certificates. These are an essential ingredient to ensuring that only trusted services can join the mesh.

This pattern would be a bad idea to attempt on a production environment, unless you have a clickbait blog post planned: _I accidentally put my laptop into production and here's what happened!_

Perhaps the biggest flaw in this approach is running a Consul agent locally over a potentially slow connection. Consul agents are designed to run within the same data center with a low latency (< 10ms). An alternative approach would be to provision a remote Consul agent on-demand (or make a pool available to developers), but continue to run Envoy locally. This would require some additional configuration but is likely to work.

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


## Links
- Image credit: photo by [John Barkiple](https://unsplash.com/@barkiple?utm_source=unsplash&utm_medium=referral&utm_content=creditCopyText) on [Unsplash](https://unsplash.com/photos/xWiXi6wRLGo?utm_source=unsplash&utm_medium=referral&utm_content=creditCopyText)
- [Consul L7 Traffic Management](https://www.consul.io/docs/connect/l7-traffic) describes service resolvers, routers and splitters in more detail.
