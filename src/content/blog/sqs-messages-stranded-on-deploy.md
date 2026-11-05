---
title: "Every deploy was quietly stranding SQS messages for 15 minutes"
description: "An SQS message-age alarm fired on an empty queue. The cause: our Node workers ignored SIGTERM, so each ECS deploy killed them mid-message. Here's how we traced it and the 60-line fix."
pubDate: 2026-11-05
tags: ['AWS', 'Node.js', 'Reliability']
draft: true
---

An alarm went off on our dev environment: the oldest message on a
document-processing queue had been waiting more than five minutes. That queue
normally drains in milliseconds, so I expected a backlog. There wasn't one.

## An empty queue that's still "late"

The queue metrics told a strange story:

- 19 messages arrived in the same minute.
- 18 were processed and deleted within that minute.
- 0 messages were waiting.
- **1 message was in flight**, and its age kept climbing past 300, 400, 500 seconds.

`ApproximateAgeOfOldestMessage` includes messages that a consumer has received
but not yet deleted. So one worker had taken a message and then never finished
it. Because nobody deleted it, SQS kept it hidden for the queue's visibility
timeout, which on this queue is 15 minutes.

The application logs matched: 18 messages logged "processing started" and
"processing completed". The 19th never logged anything. It had been received
and then dropped on the floor.

## The deploy that did it

The timing lined up with a deploy, and the ECS service events showed the
sequence:

1. ECS started replacing the API tasks and took the old task out of the load
   balancer.
2. The old task spent about three and a half minutes **draining connections**.
3. During that time it was still running, so it **kept polling SQS**. It
   processed two more messages and picked up a third.
4. Then ECS terminated it, with that third message still in its hands.

Draining is meant for HTTP: the load balancer stops sending new requests and
gives existing ones time to finish. But an SQS consumer doesn't care about the
load balancer. It keeps pulling work until the process dies, and nothing told
our process it was about to.

## Nobody was listening for SIGTERM

When ECS stops a task, it sends `SIGTERM` to the container, waits up to
`stopTimeout` (120 seconds in our task definition), and then sends `SIGKILL`.
That gap is your chance to shut down cleanly. Our Node app had no `SIGTERM`
handler, so it never used it.

There's a second detail that's easy to miss. Our entrypoint script ends with
`exec "$@"`, which makes Node **PID 1** in the container. Linux doesn't apply a
signal's default action to PID 1. A normal process with no handler is killed by
`SIGTERM`, but PID 1 with no handler simply ignores it. Either way the outcome
is the same: whatever the worker is doing gets cut off, either now or when
`SIGKILL` arrives, and in-flight messages are abandoned.

On a queue with a 30-second visibility timeout you'd barely notice. On a queue
with a 15-minute timeout, a document sits half-processed for a quarter of an
hour after **every** deploy. Users see it as "processing seems stuck
sometimes", and nobody connects it to a deploy that finished ten minutes
earlier.

## The fix: stop taking work, finish what you have, then exit

We use [`sqs-consumer`](https://github.com/bbc/sqs-consumer). Two things about
it matter here:

- `consumer.stop()` stops future polling, but a long poll that's already running
  can still return messages, and those are processed normally.
- `consumer.status.isPolling` stays `true` from the moment a batch is received
  until every message in it has been handled and deleted.

So "wait until no consumer is polling" means exactly what we want: all
in-flight work is done. I confirmed this against the real library with a
stubbed SQS client before relying on it. I called `stop()` in the middle of a
2-second handler, and `isPolling` only turned `false` after the handler
finished and the message was deleted.

```ts
export async function stopConsumers(
  consumers: Consumer[],
  timeoutMs: number,
  pollIntervalMs = 500
): Promise<boolean> {
  for (const consumer of consumers) {
    consumer.stop();
  }
  const deadline = Date.now() + timeoutMs;
  while (consumers.some((consumer) => consumer.status.isPolling)) {
    if (Date.now() >= deadline) return false;
    await new Promise((resolve) => setTimeout(resolve, pollIntervalMs));
  }
  return true;
}

export function registerGracefulShutdown({ server, consumers, timeoutMs }) {
  let shuttingDown = false;
  const shutdown = async (signal: string) => {
    if (shuttingDown) return; // a second signal changes nothing
    shuttingDown = true;
    server.close(); // stop accepting new HTTP connections
    await stopConsumers(consumers, timeoutMs);
    process.exit(0);
  };
  process.once("SIGTERM", () => void shutdown("SIGTERM"));
  process.once("SIGINT", () => void shutdown("SIGINT"));
}
```

A few decisions worth explaining:

- **The timeout is 100 seconds, not 120.** It has to fit inside ECS's
  `stopTimeout`, with enough margin that we exit on our own terms rather than
  being killed.
- **No `stop({ abort: true })`.** Aborting cancels the long poll faster, but it
  also cancels any `DeleteMessage` request that's in flight. A message we had
  already processed would then be delivered again. Waiting up to 20 extra
  seconds for a long poll to return is the better trade.
- **Watch for health checks that restart consumers.** We had a helper that
  restarts any consumer it finds stopped. Stopping a consumer clears that
  interval, which is what you want here. Otherwise your shutdown and your
  self-healing would fight each other.

## A checklist for any queue worker on ECS (or Kubernetes)

- **Handle `SIGTERM` explicitly**, especially if your process runs as PID 1. If
  you'd rather not, run an init like `tini`, or set `initProcessEnabled` in the
  ECS task definition.
- **Stop polling first, then wait for in-flight work**, with a deadline shorter
  than the platform's grace period (`stopTimeout` on ECS,
  `terminationGracePeriodSeconds` on Kubernetes).
- **Treat your visibility timeout as your worst case.** Any message a worker
  dies holding is delayed by that long. Long timeouts are sometimes necessary,
  but they make abandoned messages far more expensive.
- **Alarm on message age, not just queue depth.** Queue depth was zero the whole
  time. Only the age metric caught this.
- **Look at your deploy timeline when things are "sometimes stuck".** If the
  stalls cluster around deploys, it's probably shutdown, not your business
  logic.

The bug had probably been there since the service was first deployed. A single
alarm that happened to fire during a test run is what finally made it visible.
