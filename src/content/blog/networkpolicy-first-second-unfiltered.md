---
title: "My NetworkPolicy worked. Just not for the first second of every Pod"
description: "I locked down egress for untrusted CI code with a NetworkPolicy and proved it from inside a Pod. Then I ran the same probe without a sleep: for about a second, every new Pod could reach Postgres and the API server, and a connection opened in that second stayed open."
pubDate: 2026-12-16
tags: ['Kubernetes', 'Security', 'CI']
---

I'm building a small CI system that checks code written by AI agents. Each
check runs as a Kubernetes Job: a worker clones the commit and runs
`go build`, `go vet` and `go test`. The code under test is untrusted by
definition, so most of the work is deciding what it can reach.
[An earlier post](/blog/create-jobs-means-read-secrets/) was about secrets.
This one is about the network.

That earlier post ended with a list of things still open, and the first one
was the network: the code under test could connect anywhere. I also wrote
that kind's default network plugin doesn't enforce NetworkPolicy, so it
would need Calico or Cilium first. **That was wrong.** kind's own plugin,
kindnet, has enforced NetworkPolicy since kind v0.24. I found out when I
wrote the policy, probed it, and it worked.

Then I ran the same probe without a `sleep` at the start, and for about a
second it didn't.

Everything below is from kind v0.33.0, Kubernetes v1.37.0 and
`kindnetd:v20260820-69b56db7`, on a single node on Docker Desktop.

## The policy

The checks run in their own namespace, `agentic-ci-runs`, which holds nothing
else. A check needs three things from the network: DNS, the control plane (to
report its result) and HTTPS to the internet (`git clone` from GitHub, the Go
module proxy). The policy allows exactly that:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: checks
  namespace: agentic-ci-runs
spec:
  podSelector: {}            # every Pod: the namespace holds only checks
  policyTypes: [Ingress, Egress]
  egress:
    - to:                    # DNS
        - namespaceSelector:
            matchLabels: {kubernetes.io/metadata.name: kube-system}
          podSelector:
            matchLabels: {k8s-app: kube-dns}
      ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
    - to:                    # the control plane, for the report
        - namespaceSelector:
            matchLabels: {kubernetes.io/metadata.name: agentic-ci}
          podSelector:
            matchLabels: {app.kubernetes.io/name: agentic-ci-control-plane}
      ports: [{protocol: TCP, port: 8080}]
    - to:                    # the internet on 443, but nothing private
        - ipBlock:
            cidr: 0.0.0.0/0
            except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16]
      ports: [{protocol: TCP, port: 443}]
```

No ingress rules, so nothing can connect to a check. The `except` list keeps
the private networks out of the 443 rule: the cluster's Services and Pods,
the node, the LAN, and `169.254.169.254`, where clouds serve instance
credentials. Postgres and the Kubernetes API server should both be out of
reach.

## Proving it works

I ran a Pod in `agentic-ci-runs` on the worker image, with the same
ServiceAccount and security settings as a real check. It tries a few
destinations with `curl`. I gave it a five-second `sleep` first so the
network would have time to come up:

```
control plane svc        : open
github 443               : open
kube API svc 10.96.0.1   : blocked (28)
kube API node :6443      : blocked (28)
postgres svc 5432        : blocked (28)
example.com 80           : blocked (28)
```

Exit code 28 is curl's timeout: the packets are dropped, not refused. That
was exactly what I wanted to see.

## The same probe without the sleep

Then I removed the `sleep`, mainly to stop waiting five seconds per run:

```
control plane svc        : open
github 443               : open
kube API svc 10.96.0.1   : open
kube API node :6443      : open
postgres svc 5432        : open
example.com 80           : blocked (28)
```

Postgres and the API server were open. Port 80 to the internet was blocked,
but only because it came last: by the time the probe got to it, filtering
had started.

My first theory was "that's just how NetworkPolicy works, it's eventually
consistent." The Kubernetes documentation has a
[section on exactly this](https://kubernetes.io/docs/concepts/services-networking/network-policies/#pod-lifecycle),
and it says the opposite. It allows a gap when the *policy* is new. If a Pod
starts before the plugin has processed a freshly created policy, it "may be
started unprotected." But once the plugin has handled the policy:

> All newly created pods affected by a given NetworkPolicy will be isolated
> before they are started. Implementations of NetworkPolicy must ensure that
> filtering is effective throughout the Pod lifecycle, even from the very
> first instant that any container in that Pod is started.

My policy had existed for many minutes before the probe ran. That gap
isn't the documented one.

## Measuring the window

I wanted a number, not a single run. The new probe resolves the Postgres
Service once, then tries a TCP connection to it every 100 ms from the moment
the container starts, and prints each change:

```bash
t0=$(date +%s%3N)
while [ $(( $(date +%s%3N) - t0 )) -lt 4000 ]; do
  if timeout 0.3 bash -c "exec 3<>/dev/tcp/$pg/5432" 2>/dev/null
  then r=open; else r=blocked; fi
  [ "$r" != "$last" ] && echo "$(( $(date +%s%3N) - t0 ))ms $r" && last=$r
  sleep 0.1
done
```

I ran it in ten fresh Pods, one after another:

| Pod | First attempt | Blocked from |
|---|---|---|
| 1 | open at 7 ms | 1269 ms |
| 2 | open at 5 ms | 1162 ms |
| 3 | open at 6 ms | 1163 ms |
| 4 | open at 5 ms | 1062 ms |
| 5 | open at 5 ms | 1161 ms |
| 6 | open at 5 ms | 1052 ms |
| 7 | open at 6 ms | 1161 ms |
| 8 | open at 5 ms | 1161 ms |
| 9 | open at 6 ms | 1053 ms |
| 10 | open at 6 ms | 1052 ms |

Ten out of ten. Every new Pod could reach Postgres for **1.05 to 1.27
seconds** after its container started, then never again. The window is
consistent, not a rare race.

## A connection opened in that second stays open

A one-second window sounds small. What made it worse was the next question:
what happens to a connection opened during the window once filtering
starts?

The probe also opened one connection at t=0 and kept it. After the loop, it
spoke the Postgres protocol over it: an `SSLRequest`, eight bytes, to which
the server answers with a single `N` (no TLS) or `S`.

```bash
exec 3<>/dev/tcp/$pg/5432                       # at t=0, inside the window
# ... 4 s of new connections being blocked ...
printf '\x00\x00\x00\x08\x04\xd2\x16\x2f' >&3   # at t=8 s
read -r -n1 -t 3 reply <&3                      # reply = N
```

In all ten Pods, Postgres answered at 8 seconds. I ran it once more with
the request at 45 seconds, and it still answered. (I stopped short of 60
seconds because Postgres closes connections that haven't authenticated by
then, `authentication_timeout`, and that would be measuring Postgres, not the
policy.)

So **the window doesn't need to stay open.** Code that connects in its first
second keeps that connection for as long as it wants, while every new
connection to the same address is blocked.

## Why

kindnet's policy engine is
[kube-network-policies](https://github.com/kubernetes-sigs/kube-network-policies).
It installs an nftables table on each node, and the relevant part looks like
this (trimmed):

```
table inet kindnet-network-policies {
  set podips-v4 { type ipv4_addr; elements = { 10.244.0.9 } }
  chain postrouting {
    ...
    ct label 28 ct state established,related accept
    ip saddr @podips-v4 queue flags bypass to 101
    ip daddr @podips-v4 queue flags bypass to 101
    ct label set 28
  }
}
```

Packets to or from an address in `podips-v4`, the Pods that some policy
selects, go to a userspace process through an nfqueue, and that process
decides. Everything else falls through to `ct label set 28`, which marks the
connection as decided, and the first rule then accepts every later packet of
it.

My reading of the two findings:

- **The window.** A new Pod's IP isn't in `podips-v4` yet, so its packets
  never reach the queue. They fall through, unfiltered, until the agent
  learns the IP and adds it. About a second would fit the time it takes
  the kubelet to report a new Pod's IP back to the API server.
- **The surviving connection.** A connection that fell through got label 28
  and counts as decided. When the IP lands in the set later, that
  connection's packets match the `established` rule before they reach the
  queue.

I haven't traced this in the agent's code, so treat the mechanism as my
reading of the rules. The measurements stand on their own.

It's not the first bug of this kind in the project.
[Issue #414](https://github.com/kubernetes-sigs/kube-network-policies/issues/414),
closed in November, was a new Pod's first packets being judged by the
policies of a finished Pod that had held the same IP. In that thread, a
maintainer states the invariant: "a decision of a policy should be tied
exclusively to the live of the Pod that actually holds the IP." A
contributor adds that correct identity resolution alone "doesn't guarantee
first-packet enforcement when Pod information or dataplane state hasn't
caught up". That is the case I hit.

## Does it matter here?

For my CI, today, not much, and only by luck. The first process in a check
is the worker, which is my code. It clones the repository and builds it, and
nothing the agent wrote runs until `go test`, several seconds in. `git clone`
doesn't run code from the repository, and the worker doesn't connect to
Postgres. By the time untrusted code starts, the window has been closed for
seconds.

But that's an accident of ordering, not a property of the system. A CI that
runs a user's script as its first step, a sidecar that starts in parallel, or
a future change that runs an agent's setup command before the build, and the
untrusted code gets the first second, plus every connection it opens in it.

## The fix: wait for isolation in an init container

The documentation's own advice for the opposite problem, a Pod that starts
with *less* connectivity than it should, is an init container that waits
until its destinations are reachable. The same idea works here in reverse:
**wait until something the policy denies is unreachable, and only then start
the containers that matter.**

```yaml
initContainers:
  - name: wait-for-isolation
    image: localhost:5001/agentic-ci-worker@sha256:...
    command: ["bash", "-c"]
    args:
      - |
        # The policy denies the API server. Filtering is on once a
        # connection to it times out: dropped, not refused or misaddressed.
        addr=$KUBERNETES_SERVICE_HOST/$KUBERNETES_SERVICE_PORT
        while [ $SECONDS -lt 30 ]; do
          timeout 0.2 bash -c "exec 3<>/dev/tcp/$addr" 2>/dev/null
          if [ $? -eq 124 ]; then exit 0; fi
          sleep 0.05
        done
        echo "NetworkPolicy not enforced after 30s" >&2
        exit 1
```

Why this works:

- **NetworkPolicy applies to the whole Pod**, init containers included, so
  the init container sees the same network as the check will.
- **Its connections die with it.** Whatever it opened during the window is
  closed when it exits, before the next container starts.
- **The Kubernetes API is a good canary.** Kubernetes injects
  `KUBERNETES_SERVICE_HOST` into every container, even with
  `enableServiceLinks: false`. It's reachable from any Pod without a policy,
  and it's the destination I care about most.
- **Only a timeout counts.** `timeout` exits with 124 when the connect is
  still hanging, which is what a dropped packet looks like. A refused
  connection or an empty variable fails at once with another code, and the
  loop keeps going instead of reporting a false "isolated".
- **It fails closed.** If the policy is never enforced, the init container
  exits 1, the check's container never starts, and the Job fails. That also
  catches a cluster where NetworkPolicy isn't enforced at all, which is the
  mistake I made in the opposite direction in the last post.

With the gate in front of the same probe, three runs of exactly this script
(and five more of an earlier version that counted attempts instead of
seconds) all looked like this:

```
[wait-for-isolation] isolated after 1s
[probe]              held_at_0ms=no
[probe]              612ms blocked
[probe]              4394ms end: blocked
```

The gate waited about a second, the same window as before, and the probe
couldn't reach Postgres on its first attempt or hold a connection. As a
negative control, I turned the policy off and ran it again: the init
container gave up after 30 seconds, and the probe never started.

One limitation: the gate checks one destination. In kindnet, isolation is a
single switch per Pod (its IP goes into the set), so one canary covers every
rule. A plugin that applies rules per node or per destination could isolate
some addresses before others. The documentation gives exactly that example,
a Pod that can reach Pod A at once and Pod B a few seconds later. There, the
canary should be the destination you least want reached.

Next, the gate goes into the Job spec the control plane builds, and into the
admission policy that checks it.

## What I'm keeping from this

**A policy that exists isn't the same as a policy in effect.** Probe it from
inside a Pod, and probe it at the moment your untrusted code starts, not five
seconds later. My first probe had a `sleep` to "let the network come up," and
it hid exactly the part that mattered.

The full probe is
[`deploy/examples/netpol-window.yaml`](https://github.com/vitkarpov/agentic-ci/blob/main/deploy/examples/netpol-window.yaml)
in the project's repository. Change the namespace and the address it
probes, and it works against any policy that denies something.
