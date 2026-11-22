---
title: "ECS restarted my one-off task, twice: once after a crash, once after it finished"
description: "A one-off ECS backfill reported 'another process holds the lock'. It had actually been killed at a 512 MB limit my override never raised, then restarted by a policy I didn't know was on. Once fixed, it finished and started over."
pubDate: 2027-01-06
tags: ['AWS', 'Reliability', 'Node.js']
---

At Sky I needed to run a backfill: walk every stored report section, rebuild
a derived column, and write it back. That's a job you run once per
environment, not something a long-lived worker should do on startup. So I
wrote a GitHub Actions workflow that starts it as a **one-off ECS task**,
reusing the worker service's task definition with a different command.

It looked like the simplest possible setup. It failed in two ways I didn't
expect, and both came from settings I hadn't written myself.

## The setup

The workflow reads the worker service's task definition and network
configuration, then calls `run-task` with overrides:

```bash
OVERRIDES=$(cat <<EOF
{
  "cpu": "1024",
  "memory": "4096",
  "containerOverrides": [{
    "name": "$CONTAINER",
    "command": ["node", "dist/mdast-backfill/runOnce.js", "dry-run"],
    "environment": [{"name": "NODE_OPTIONS", "value": "--max-old-space-size=3072"}]
  }]
}
EOF
)

aws ecs run-task \
  --cluster "$ECS_CLUSTER" \
  --task-definition "$TASKDEF" \
  --launch-type FARGATE \
  --network-configuration "$NETCFG" \
  --overrides "$OVERRIDES"
```

The worker service itself runs on 512 MB, which is too small for the largest
sections, so the backfill asks for 1 vCPU and 4 GB. Then the workflow polls
`describe-tasks` until the task stops, reads the container's exit code, and
maps it to a result.

The backfill takes a Redis lock, so two runs can't overlap: `SET NX` with a
10-minute TTL, renewed every 200 seconds while it runs. If the lock is
already taken, the process exits with code 75 (`EX_TEMPFAIL`), and the
workflow prints:

```
Another process holds the backfill lock; nothing ran.
```

## Failure one: "another process holds the lock"

The first dry run on dev ended with exactly that message. Nothing else was
running a backfill. The task's log stream told a stranger story (progress
lines trimmed):

```
11:29:54  mdast-backfill.started   mode=dry-run
11:32:40  mdast-backfill.progress  scanned=3000
...
11:36:05  mdast-backfill.progress  scanned=7600
11:36:32  mdast-backfill.skipped   reason="another process holds the lock"
```

One log stream, one task, and it both ran the backfill for six minutes and
was refused the lock. The entry point calls the locked function exactly once.
There's no process manager in the image, just `CMD ["node", ...]`. So one
process can't produce both lines. **Two processes ran in the same container
slot, one after the other.**

The task definition explained both halves:

```bash
aws ecs describe-task-definition --task-definition sky-dev-custom-reports-worker:61 \
  --query 'taskDefinition.{cpu:cpu, mem:memory,
           containerMem:containerDefinitions[0].memory,
           restart:containerDefinitions[0].restartPolicy}'
```

```json
{
  "cpu": "256",
  "mem": "512",
  "containerMem": 512,
  "restart": { "enabled": true }
}
```

**The override didn't raise the limit that mattered.** ECS has two memory
settings. The task-level `memory` is the size of the Fargate task. The
container-level `memory` is a **hard limit** for that container: exceed it
and the kernel kills the process. My override raised the task to 4 GB, but
the container definition still said 512. The task had 4 GB, and the
container was allowed to use 512 MB of it. The backfill grew past that around
section 7,600, and the kernel sent `SIGKILL`. A process killed with `SIGKILL`
doesn't get to log anything, which is why the stream just stops after
11:36:05.

**The restart policy then hid the crash.** ECS
[container restart policies](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/container-restart-policy.html)
restart a container in place, inside the same task, when it exits. The
restarted container logs to the same stream and runs the same command, here
including my override. The new process asked Redis for the lock. The dead
process still held it, since it never got to release it and the TTL had
minutes left. So the new process exited 75 within seconds. A container that
exits that quickly isn't restarted again (more on that rule below), so this
time ECS let the task stop.

`describe-tasks` reports the exit code of the container's **last** run. The
workflow saw 75 and printed the lock message. The OOM kill that actually
ended the run appears nowhere in the task's status.

I hadn't turned the restart policy on. The task definition comes from the
[`terraform-aws-modules/ecs`](https://github.com/terraform-aws-modules/terraform-aws-ecs)
module, and its container definition defaults to
`restartPolicy = { enabled = true }`. For a long-running service that's a
reasonable default: a crashed worker comes back in seconds instead of waiting
for the service scheduler to replace the task.

The fix for the memory limit is one line. Container overrides accept their own
`memory`:

```json
"containerOverrides": [{
  "name": "$CONTAINER",
  "command": $CMD,
  "memory": 4096,
  "environment": [{"name": "NODE_OPTIONS", "value": "--max-old-space-size=3072"}]
}]
```

I also changed the message for exit code 75. It now says the lock was held
"by another backfill, **or** this task's container was killed and restarted",
and points to the log stream.

## Failure two: it finished and started over

I ran the dry run again from the fix branch. This time it went through all
16,347 dev sections:

```
11:45:51  mdast-backfill.started   mode=dry-run
12:00:47  mdast-backfill.done      scanned=16347 errors=0 conflicts=0
12:01:00  mdast-backfill.started   mode=dry-run
```

Thirteen seconds after a clean `exit(0)`, it started again.

That's also the restart policy. By default it restarts a container **whatever
its exit code**, as long as the container ran for at least the restart
attempt period (300 seconds by default). Exit code 0 isn't special. A service
container is never supposed to exit, so a policy written for services doesn't
need to treat "done" differently.

A one-off task that runs longer than five minutes therefore never ends. It
finishes, restarts, does the work again, and repeats until someone stops the
task. Here the second pass would have been harmless: the backfill is
idempotent and finds nothing to do once everything is current. But the workflow
waiting on the task would have polled forever. I stopped the task by hand.

`run-task` can't change the restart policy. Container overrides cover the
command, environment, CPU and memory, but not `restartPolicy`. So the fix
belongs in the task definition. I kept the policy for this container and made
it ignore a clean exit:

```hcl
each.key == "custom-reports-worker" ? {
  restartPolicy = {
    enabled          = true
    ignoredExitCodes = [0]
  }
} : {}
```

A worker in the service only exits 0 when ECS is already stopping it, so the
service loses nothing. Crashes still restart in place.

After that change, the dev backfill ran for real: 8 minutes, exit code 0, and
the task stopped on its own. Production later took 38 minutes for 63,238
sections, and it also started exactly once.

## What I took from it

**Override the container's memory, not only the task's.** On Fargate the
task size is what you pay for, and the container's `memory` is what the
kernel enforces. If the container definition sets a hard limit, raising only
the task size changes nothing except the bill.

**Check the restart policy before reusing a service's task definition.** A
policy that's right for a service is wrong for a job. A crashed job gets
restarted, and a finished one gets restarted too. If you use the
`terraform-aws-modules/ecs` module, it's on unless you turned it off.

**A restart hides the first exit code.** The task status shows how the last
run of the container ended. If anything restarts a container, whether a
policy, a supervisor or a wrapper script, the reason the first run ended is
only in its logs, and an OOM kill leaves nothing there. That's the same
lesson as [Kubernetes Jobs](/blog/kubernetes-job-exit-code-is-lying/): the
exit code is a poor channel for "what happened".

**A lock held by a dead process looks like contention.** The lock did its job
and stopped a second run. But the message assumed the holder was alive. If I
built the lock again, I'd store the holder's task ID as its value and log it
when refusing. "Held by task `decb6de5`" would have pointed straight at this
very task, and the OOM.

Neither problem was in the backfill code. Both came from defaults that are
right for the service this task definition was written for.
