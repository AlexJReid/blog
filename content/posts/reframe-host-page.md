+++ 
draft = false
date = 2021-03-10T19:49:12Z
title = "Bootstrapping a re-frame app with variables from the host page"
slug = "reframe-host-page" 
tags = ['re-frame', 'clojure', 'clojurescript', 'front-end']
categories = []
externalLink = ""
series = []
+++

I have been working on a front end using [ClojureScript and re-frame](https://day8.github.io/re-frame/a-loop/). It has been a fair learning curve, but I'd thoroughly recommend investigating if you already use React and Redux. 

I won't repeat the excellent documentation and tutorials that are readily available, but rather how I solved a fairly trivial problem.

A client-rendered single page application is _mounted_ to an element within a host page. It is often useful for an application to read a configuration object defined on the host page like so:

```html
<script>
var APP_CONFIG = {
    trackingRef: "42",
    somethingElseUseful: true
};
</script>
```

ClojureScript makes the host JavaScript environment available in the `js/` namespace. Within a re-frame application, state is generally held in a single _database_ known as the `app-db`. This is a structure that event handlers receive and return a **new** version of, causing subscribed views to update when necessary.

However, values from the grubby outside world need to find their way into `app-db`. So that my application can access the values defined in the JavaScript object, I needed a way of copying the values into `app-db`.

## Co-effects

A co-effect is re-frame's way of dealing with the outside world, so I registered one called `:load-host-page-config`. As part of the registration, a function should be provided that receives a `cofx` map and returns a new, augmented version of this map.

With the help of `js->clj`, I can retrieve the JavaScript object as a Clojure map, and add it to the context as `:host-page-config`.

```clojure
(re-frame/reg-cofx
 :load-host-page-config
 (fn [cofx _]
   ;; get config object from host page
   (assoc cofx :host-page-config
          (js->clj js/APP_CONFIG :keywordize-keys true))))
```

## Event handler

This co-effect is only useful when an event is dispatched. To start a re-frame application, an _initial event_ is dispatched. In my application, the initial event is `::initialize-db`. 

As I want to both add the configuration object from the host page to the `app-db` **and** dispatch an another event to load some more state from a remote call, I use `reg-event-fx` to register an event handler function. This returns a map of directives - `:db` containing the new `app-db` and `:dispatch` to make a service call.

```clojure
(re-frame/reg-event-fx
 ::initialize-db
 [(re-frame/inject-cofx :load-host-page-config)]
 (fn [{:keys [db host-page-config]} _]
   {:db       (assoc db/default-db :host-page-config host-page-config)
    :dispatch [:load-initial-state]}))
```

The first argument to the event handler function is `cofx` with some destructuring to pull out `db` and `host-page-config`, the latter being made available through `inject-cofx` before the function. This adds the co-effect we registered in the previous section.

As you can see, the configuration from the host page has been added at `:host-page-config`. It would be better practice to be more selective about the permitted keys and maybe also enforce it with a spec.

## Wrap up

This approach might be overkill as the values set in the host page are unlikely to change. Co-effects are commonly used to interface with local storage, service calls, getting the current time, and so on. 

As said previously, re-frame and the entire developer experience when working with ClojureScript is a refreshing change. I've an incredibly low tolerance for slow feedback loops, so seeing changes take effect immediately after saving mad a huge difference. Taking it a step further - connecting emacs to the running application and dispatching events through the REPL.. blew my mind! 

I know I'm more than a few years late to the party. Front end _can_ be fun, never thought I'd say that.
