---
title: "Our WebSocket validator threw away every success message, and TypeScript couldn't see it"
description: "A dialog hung forever though the server replied in a second. Our WebSocket messages lived outside the OpenAPI spec, so each side hand-wrote its own types, and the client's validator rejected the real reply. How we moved them into the spec, and proved the compiler now catches it."
pubDate: 2026-12-23
tags: ['TypeScript', 'Architecture', 'Testing']
---

A browser test clicked **Add to Version**, saw "Adding to Version...", and
waited. Five minutes later the dialog was still there, the Close button was
still disabled, and nothing had redirected anywhere. After a refresh, the file
*was* in the version. The work had happened. The UI just never found out.

The test was new, and this was its first run. The bug wasn't new at all.

## The server answered in about a second

Adding files to a version doesn't go over REST. The dialog sends a request on
a WebSocket and waits for a reply on the same socket. The hook that wraps this
is small: set `isLoading`, send, and clear `isLoading` when a message for the
same channel comes back.

```ts
const handleResponse = (response: ActionResponse) => {
  if (response.messageType !== channel) return;
  setIsLoading(false);
  onResponse(response);
};
```

So either the server never replied, or the reply never reached that handler.
The backend logs settled the first question. The copy started, wrote one
section and four pages, and logged its final step about a second later. The
reply is sent right before that last log line, on the socket that made the
request. No new connection had opened in between, so the socket was still
alive.

The server replied. The client dropped it.

## The validator was strict, and wrong

Every inbound message goes through one parser before any listener sees it.
`JSON.parse` gives you `unknown`, and type guards are the only way a payload
becomes a typed response. A message that fails its guard is logged as invalid
and discarded:

```ts
if (value.messageType === "add-to-version") {
  if (!isAddToVersionResponse(value)) return { type: "invalid" };
  return { type: "add-to-version", message: value };
}
```

That's a reasonable design. The guard was the problem. It required the
`response` field to look like this:

```ts
response?: { id: string; fileCount: number };
```

That's the shape of a different action's reply: creating a version. The server
sends this for add-to-version:

```ts
response: { success: true, volumeId: targetVolumeId }
```

So every successful reply failed validation and went nowhere. The only signal
was a "message failed validation" line in the browser console. The error reply
had no `response` field, so it passed the guard, and the unit tests only
covered the error reply. Every success was rejected, and every failure got
through.

The shapes had been unified a few weeks earlier, in a refactor whose whole
purpose was to make WebSocket messages type-safe. It added runtime validation,
which is the right instinct. But it validated against a type someone wrote by
hand, and nothing compared that type with what the server sent.

## Why the compiler didn't catch it

Our REST API doesn't have this problem. The backend serves an OpenAPI spec,
and the frontend generates its client and models from it with
[orval](https://orval.dev). The backend generates its own types from the same
file with `openapi-typescript`. If someone renames a field in a REST response,
one side or the other stops compiling.

WebSocket messages weren't in the spec at all. They had two hand-written
definitions:

- **Server:** the request types were declared, but the replies were untyped
  object literals passed to `ws.send(JSON.stringify(...))`.
- **Client:** its own copy of every message type, plus the guards built from
  that copy.

Two copies of a contract with no link between them will drift. The type system
can't help, because each side is consistent with *itself*. The client's guard
matched the client's type. The server's literal was whatever the server wrote.
Neither file ever saw the other.

## Putting the messages in the spec

The immediate fix was one line in the guard. The real fix was making sure
there was only one definition left.

We didn't need a separate spec format for this. OpenAPI's `components.schemas`
can hold schemas that no REST path references, and both generators still emit
types for them. So the WebSocket replies went into the same `specs.yaml`:

```yaml
WsAddToVersionResponse:
  type: object
  description: Successful reply to an `add-to-version` action. Failures are sent as WsActionError.
  required: [messageType, action, response]
  properties:
    messageType: { type: string, enum: [add-to-version] }
    action: { type: string, enum: [message-response] }
    response:
      type: object
      required: [success, volumeId]
      properties:
        success: { type: boolean }
        volumeId: { type: string }
```

On the **server**, every reply now goes through one function typed with the
generated schemas, so a wrong shape is a compile error where it's written:

```ts
type WsSchemas = components["schemas"];

function sendWsReply(
  ws: WebSocket,
  reply:
    | WsSchemas["WsVolumeCreationResponse"]
    | WsSchemas["WsAddToVersionResponse"]
    | WsSchemas["WsActionError"]
) {
  ws.send(JSON.stringify(reply));
}
```

On the **client**, the hand-written types became the generated ones. The
runtime guards stayed, because socket data still has to be checked at runtime.
But a guard now reads fields through the generated type, so it can only check
fields that exist in the spec:

```ts
function isAddToVersionResult(
  value: unknown
): value is WsAddToVersionResponseResponse {
  if (!isRecord(value)) return false;
  const result: Partial<Record<keyof WsAddToVersionResponseResponse, unknown>> =
    value;
  return (
    typeof result.success === "boolean" && typeof result.volumeId === "string"
  );
}
```

`result.id` doesn't compile there, because `id` isn't a key of the generated
type.

## Two things the review caught

**Success and error were one shape.** My first schema had `action` accept
either `message-response` or `message-error`, with both `response` and `error`
optional. That made `{ action: "message-response" }` with no `response` a
valid reply, which is the same class of hole the original bug lived in. And
after checking `action === "message-response"`, the compiler still couldn't
tell you `response` was there. Two automated reviewers flagged it. Now each
success schema has the literal `message-response` action and a required
`response`, and failures are a separate `WsActionError` with a required
`error`. On the client, each channel's type is "this channel's success, or an
error for this channel", and checking `action` narrows it properly.

**A loose schema is a loose type.** The create-version reply spread the whole
volume record into `response`, so its schema needed
`additionalProperties: true`. The generated type then has an index signature,
and `keyof` of a type with an index signature is just `string`. A renamed
`id` would have compiled. The client only ever read `id`, so the server now
sends exactly `{ id, fileCount }` and the schema is strict. Being honest about
what a message contains is what makes it type-check.

## Did it actually help? Put the bug back

The same check as always: break it and see whether anything notices. With the
client built from the deployed spec, I made two changes and reverted each one.

**1. Reintroduce the original bug.** Make the add-to-version guard check `id`
and `fileCount` again:

```
src/lib/wss-messages.ts(143,19): error TS2339: Property 'id' does not exist
on type 'Partial<Record<keyof WsAddToVersionResponseResponse, unknown>>'.
```

**2. Change the contract from the other side.** Rename `volumeId` to
`targetVolumeId` in the spec and regenerate the client:

```
src/lib/wss-messages.ts(143,58): error TS2339: Property 'volumeId' does not
exist on type 'Partial<Record<keyof WsAddToVersionResponseResponse, unknown>>'.
```

On the server, sending the old `{ id, fileCount }` shape for add-to-version
fails too: `'id' does not exist in type '{ success: boolean; volumeId: string; }'`.

Before, all three would have compiled cleanly and failed silently at runtime.

## One thing to know about generating from a live spec

The frontend's dev build downloads `specs.yaml` from the dev API before it runs
orval. Right after the backend deployed, my first download didn't have the new
schemas. It wasn't the CDN, which doesn't cache that path. Most likely an old
container was still taking requests during the rollout. A minute later every
request returned the new spec. If a
frontend build depends on a backend change, wait for the rollout to finish,
not just for the deploy job to go green.

## The takeaway

If your REST types come from a spec, look at what *doesn't*: WebSocket
messages, queue payloads, webhook bodies, `postMessage` events. Each of those
is a contract with a hand-written copy on each side, and the compiler can't
compare them.

Runtime validation doesn't fix that by itself. A validator built from a
hand-written type will strictly enforce that type, and if the type is wrong, it
turns a mismatch into messages dropped without a word. Put the shapes where
both sides generate from them. The schemas don't have to be referenced by any
endpoint to be useful. Then break the contract on purpose, once from each side,
to check that the build notices.
