---
title: "`kubectl auth can-i` said my control plane couldn't read secrets. It read one anyway"
description: "I locked down a Kubernetes CI worker and proved from inside a Pod that it couldn't read secrets. Then the control plane read one through a Job it was allowed to create. RBAC checks who sends a request, not what's in it. Here's how I closed the gap with a ValidatingAdmissionPolicy."
pubDate: 2026-11-13
tags: ['Kubernetes', 'Security', 'CI']
---

I'm building a small CI system that checks code written by AI agents. Each
check runs as a Kubernetes Job: the control plane creates the Job, and a
worker inside it clones the commit and runs `go build`, `go vet` and
`go test`. ([The previous post](/blog/kubernetes-job-exit-code-is-lying/) is
about how that worker reports its result.)

The code under test is untrusted by definition. An agent can write a test
that does anything a Go program can do, and `go test` will run it. So the
second thing to get right, after the result, is what that code can reach. The
first requirement on my list was simple: **the worker must not be able to read
secrets.**

I set that up, proved it from inside a Pod, and ticked the box. Then I found
that the control plane, which `kubectl auth can-i` said couldn't read a single
secret, could read every one of them.

## The setup

Two namespaces and two ServiceAccounts:

| ServiceAccount | Namespace | Permissions |
|---|---|---|
| `agentic-ci-worker` | `agentic-ci-runs` | None. Its token is never mounted. |
| `agentic-ci-control-plane` | `agentic-ci` | A Role in `agentic-ci-runs`: create, get, list, watch and delete Jobs; get, list and watch Pods. |

`agentic-ci-runs` contains only the check Jobs. The control plane gets a
`Role`, not a `ClusterRole`, so it can create Jobs there and nowhere else.
There is nothing about secrets in its rules.

The worker's ServiceAccount has no RoleBindings, and both the ServiceAccount
and every Pod set `automountServiceAccountToken: false`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: agentic-ci-worker
  namespace: agentic-ci-runs
automountServiceAccountToken: false
```

Setting it in both places isn't redundant. **The Pod's setting overrides the
ServiceAccount's**, so the ServiceAccount setting alone wouldn't stop a Pod that
asks for the token. And a dedicated ServiceAccount, instead of the namespace's
`default`, means that permissions someone later grants to `default` for some
unrelated reason don't end up with the code under test.

## Proving the worker can't read secrets

First, from the API server's point of view:

```
$ kubectl auth can-i get secrets -n agentic-ci-runs \
    --as=system:serviceaccount:agentic-ci-runs:agentic-ci-worker
no
```

The same `no` for `list secrets`, for secrets in `kube-system`, for Jobs and
for Pods.

`can-i` only tells you what RBAC thinks, though. I wanted to see what the code
actually gets, so I created a test secret in `agentic-ci-runs` and ran two
Pods on the worker image that call the API server with `curl`. One looks
exactly like a real check, with no token. The other mounts the worker's token
on purpose:

```
[notoken] token: none
[notoken] GET .../agentic-ci-runs/secrets/probe -> 403
          secrets "probe" is forbidden: User "system:anonymous" cannot get ...
[token]   token: mounted
[token]   GET .../agentic-ci-runs/secrets/probe -> 403
          secrets "probe" is forbidden:
          User "system:serviceaccount:agentic-ci-runs:agentic-ci-worker" cannot get ...
```

Without a token, the check is `system:anonymous` to the API server. With a
token, it's a ServiceAccount with no permissions. Either way it gets 403.
**Two independent layers both hold**, so turning one of them off by mistake
doesn't open anything.

I ticked "the worker can't read secrets" and moved on.

## The control plane read the secret anyway

While writing up the notes, I wrote down that the control plane can only
create Jobs, not Pods, "so it can't create a Pod that mounts a secret either."
That sentence didn't look right, so I tested it. As the control plane's
ServiceAccount, I created this Job:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: steal
  namespace: agentic-ci-runs
spec:
  template:
    spec:
      volumes:
        - name: s
          secret:
            secretName: probe
      containers:
        - name: c
          image: agentic-ci-worker:dev
          command: ["cat", "/s/password"]
          volumeMounts:
            - name: s
              mountPath: /s
      # ...restartPolicy, securityContext, resources
```

```
$ kubectl create --as=system:serviceaccount:agentic-ci:agentic-ci-control-plane -f steal.yaml
job.batch/steal created
$ kubectl -n agentic-ci-runs logs job/steal
hunter2
$ kubectl auth can-i get secrets -n agentic-ci-runs \
    --as=system:serviceaccount:agentic-ci:agentic-ci-control-plane
no
```

`can-i` says no, and the secret is in the logs.

**RBAC authorizes the request, not what's in it.** The API server checked
that the control plane may create Jobs in `agentic-ci-runs`, and it may. Then
the Job controller created the Pod, and the kubelet mounted the secret. Nobody
in that chain asked whether the control plane could read secrets, because it
never read one through the API.

A secret volume isn't the only way in. The Pod template can also take a secret
through `env[].valueFrom.secretKeyRef` or `envFrom[].secretRef`, or run as any
ServiceAccount in the namespace with its token mounted. Kubernetes documents
this in its [RBAC good practices](https://kubernetes.io/docs/concepts/security/rbac-good-practices/):
permission to create workloads in a namespace implicitly gives access to its
secrets and ServiceAccounts. I'd read that page before. I just hadn't applied
it to my own Role.

And RBAC can't express the rule I actually wanted. There is no way to say "may
create Jobs, but only ones that don't mount secrets." RBAC sees verbs and
resources, not fields.

## Who could actually use this

The code under test can't. It has no token and gets 403 on Jobs, as shown
above. The control plane can, in two ways:

- **It gets compromised.** That's bad, but it adds little, since the control
  plane already holds the database password and the GitHub credentials.
- **It has a bug.** This is the realistic one. A field from a webhook payload
  ends up in the Pod template, or a future "configurable steps" feature lets a
  user add an env variable or a volume. The control plane builds Pod specs from
  outside input all day.

So the risk isn't really that an attacker will escape the sandbox. It's that
my own code will one day put something into a Job that it shouldn't, and
nothing will stop it.

## The fix: check what's in the Job

Checking the contents of a request is admission's job. Since Kubernetes 1.30,
`ValidatingAdmissionPolicy` is built in: rules written in
[CEL](https://kubernetes.io/docs/reference/using-api/cel/) that the API server
evaluates itself, with no webhook to deploy. I added two policies.

**The first one: Jobs from the control plane must look like the ones it's
supposed to build.**

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: agentic-ci-check-jobs
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: ["batch"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["jobs"]
  matchConditions:
    - name: control-plane
      expression: >-
        request.userInfo.username ==
        'system:serviceaccount:agentic-ci:agentic-ci-control-plane'
  variables:
    - name: pod
      expression: object.spec.template.spec
    - name: containers
      expression: >-
        variables.pod.containers +
        (has(variables.pod.initContainers) ? variables.pod.initContainers : [])
  validations:
    - expression: >-
        has(variables.pod.serviceAccountName) &&
        variables.pod.serviceAccountName == 'agentic-ci-worker'
      message: "checks run as the agentic-ci-worker service account"
    - expression: >-
        has(variables.pod.automountServiceAccountToken) &&
        variables.pod.automountServiceAccountToken == false
      message: "checks must not mount a service account token"
    - expression: >-
        !has(variables.pod.volumes) ||
        variables.pod.volumes.all(v, has(v.emptyDir))
      message: "checks may only use emptyDir volumes"
    - expression: "!has(variables.pod.imagePullSecrets)"
      message: "checks must not reference image pull secrets"
    - expression: >-
        variables.containers.all(c, !has(c.envFrom) &&
          (!has(c.env) || c.env.all(e, !has(e.valueFrom))))
      message: "checks may only have literal env values"
    - expression: >-
        variables.containers.all(c,
          c.image.startsWith('agentic-ci-worker:') ||
          c.image.startsWith('agentic-ci-worker@'))
      message: "checks run the agentic-ci-worker image"
```

A `ValidatingAdmissionPolicyBinding` with a `namespaceSelector` limits it to
`agentic-ci-runs`. A few choices are worth explaining:

- **Allow, don't deny.** The volume rule doesn't list `secret`, `projected`
  and `hostPath`. It allows only `emptyDir`. Whatever volume type I didn't
  think of is rejected by default. The same goes for env: only literal values,
  no `valueFrom` of any kind.
- **The image is pinned too.** Without that rule, the control plane could run
  any image with the worker's setup. Init containers are included, because
  they're an easy way to slip a second image in.
- **Only for the control plane.** `matchConditions` checks
  `request.userInfo.username`. A cluster-admin can read secrets directly
  anyway, and my hand-written example Jobs use other images.

**The second one: no Secrets in `agentic-ci-runs` at all, for anyone.**

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: agentic-ci-runs-no-secrets
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["secrets"]
  validations:
    - expression: "false"
      message: "no secrets in agentic-ci-runs: any Job there could mount them"
```

The first policy limits what the control plane can put into a Job. This one
makes sure there's nothing to steal in that namespace even if the first policy
has a gap. Until now, "keep secrets out of the runs namespace" was a
convention. Now it's a rule, and it applies to cluster-admin as well. The
control plane's own secrets live in `agentic-ci`, where it can't create Pods.

## Trying to break it

I took a valid Job, modified it with `jq` one way at a time, and submitted
each variant as the control plane with `--dry-run=server`:

```
secret as cluster-admin  denied: no secrets in agentic-ci-runs: any Job there could mount them
baseline                 job.batch/policy-test-vc649 created (server dry run)
secret volume            checks may only use emptyDir volumes
secretKeyRef env         checks may only have literal env values
envFrom secret           checks may only have literal env values
projected token          checks may only use emptyDir volumes
default SA               checks run as the agentic-ci-worker service account
token mounted            checks must not mount a service account token
other image              checks run the agentic-ci-worker image
init container           checks run the agentic-ci-worker image
emptyDir                 job.batch/policy-test-tsq8z created (server dry run)
```

Every way of getting a secret into the Pod is rejected, each with its own
message, and the two valid Jobs still pass. Then I ran a real check end to end
with the policy in place, and it finished as `succeeded`, so the Job the
control plane actually builds passes too.

Two things about `ValidatingAdmissionPolicy` that helped:

- **CEL is type-checked when the policy is created.** `status.typeChecking`
  on the policy lists any expression that refers to a field that doesn't
  exist, so a typo shows up when you apply the policy, not on the first
  request it lets through.
- **`--dry-run=server` runs admission.** It goes through the full admission
  chain without creating anything, which makes a table like the one above
  cheap to produce and repeat.

The cost is duplication. The policy restates what the Go code that builds the
Job already does, so if I change one, I have to change the other. I think
that's the point, though. The second copy is enforced outside the process
whose bugs it's supposed to catch.

## Test the control plane with its own credentials

I found the gap by accident. One habit from this exercise I'll keep
on purpose: **run the control plane with its own ServiceAccount's token, not
your admin kubeconfig.** On a laptop, the control plane uses
`~/.kube/config`, which in kind means cluster-admin. Everything works, and
that proves nothing about the Role.

Building a kubeconfig for the ServiceAccount takes three commands:

```sh
kubectl config view --raw --minify --flatten > /tmp/cp.kubeconfig
kubectl --kubeconfig /tmp/cp.kubeconfig config set-credentials cp \
  --token="$(kubectl -n agentic-ci create token agentic-ci-control-plane --duration=1h)"
kubectl --kubeconfig /tmp/cp.kubeconfig config set-context --current --user=cp
KUBECONFIG=/tmp/cp.kubeconfig ./bin/control-plane
```

Then `kubectl auth whoami` and `--as=` let you test both directions: that the
Role is enough for the real workflow, and, as above, what else it lets you do.

## Two more things that bit me

I also labeled the namespace with Pod Security `restricted` and gave it a
ResourceQuota. Each of them broke something I'd already built.

**Pod Security admission applies to every Pod, no matter who creates it.**
With `pod-security.kubernetes.io/enforce: restricted`, the API server rejects
any Pod that could run as root, add capabilities or escalate privileges. That
holds whether the Pod comes from the control plane, a bug, or a person with
`kubectl`. The first Pod it rejected was my own example from a week earlier:
`golang:1.27` runs as root by default. It needed `runAsUser`, `HOME=/tmp`,
`seccompProfile: RuntimeDefault` and `capabilities.drop: [ALL]`.

**A quota on `limits.X` requires every Pod to set `limits.X`.** I capped
ephemeral storage for the whole namespace, because the checkout and the Go
build cache go to the node's disk, and I had already filled that disk once.
After that, every Pod without an `ephemeral-storage` limit was rejected,
including the examples and the probe.

## What's still open

Isolation is layers, and a few are still missing:

- **Network.** The code under test can connect anywhere: the internet,
  Postgres, the control plane. It only needs DNS and HTTPS to GitHub and the
  Go module proxy. A `NetworkPolicy` with restricted egress would fix that, but
  kind's default network plugin doesn't enforce NetworkPolicy, so it needs
  Calico or Cilium first.
- **A read-only root filesystem.** The worker writes to `/tmp` and `$HOME`.
  Those should be `emptyDir` volumes (which the policy already allows) with
  `readOnlyRootFilesystem: true`.
- **The kernel is shared.** A container isn't a VM. For code that's
  actively hostile, the next step is gVisor or Kata through `runtimeClassName`.

The main lesson from this one: `kubectl auth can-i` answers exactly the
question you ask it. It said the control plane couldn't read secrets, and
that was true. I just asked the wrong question. **Whoever can create Pods in a
namespace, directly or through a Job, Deployment or CronJob, can read
everything that namespace holds.** Keep that namespace empty, and check what
goes into the Pod template, not just who sends it.
