---
title: "My bot kept saying it was 2025. I had to tell it the date"
description: "My Telegram bot's jokes kept naming the wrong year, even with a prompt rule against inventing dates. The model has no clock, so it guessed from its training data. Passing the post's date and today's date fixed it in about 40 lines."
pubDate: 2026-11-30
tags: ['AI', 'Go']
image: /images/tldr-year-after.png
---

[Last week's post](/blog/tldr-roast-the-situation-not-the-person/) ended with
a problem I hadn't fixed. My group-chat bot, tldr, answers `/roast` with one
short joke about whatever post you reply to. The jokes had gotten good, but
they kept naming years that weren't in the post: "Britain 2022", a "2024" in
testing. The prompt already had a rule against that, and it didn't always
win.

A few days later it happened again:

![A Telegram message from the tldr bot, in Russian: "Reality: a random gay guy in a Reel gets it on the first try, you on the fifth, 'still learning to live'. Hair styling in 2025 still runs on the 'lucky or not' principle."](/images/tldr-year-before.png)

"Hair styling in 2025." This was in November 2026. The post said nothing
about a year.

## Why the rule didn't work

The roast prompt has said this for a while:

```
Don't invent facts: no years, dates, figures or details that aren't in
the post, the image or the context.
```

The model ignored it because the rule asks it to hold back, while the rest of
the prompt pushes the other way. The prompt also tells it to "use the
specifics" and says that "a joke that would fit any post is a failed joke". A
year is an easy specific detail to add, and most of the time the model adds it.

The rule had a second problem. When the model reaches for "this year", it has
nothing to go on. It has no clock. Its sense of "now" comes from its training
data, which ended some time before the model was released. My prompt never
said what day it was, so the model used the last year it knew well. To the
model, 2025 wasn't made up. It was its best guess.

So the fix was simple: tell the model what the date is.

## Which date

There are two dates that matter, and they're often different.

- **When the post was written.** People forward things to the chat that are
  days or years old. A joke about "this week's news" should use the date of
  the post, not the date of the forward.
- **Today.** When the joke is about now, today's date is the one to use.

Telegram has both. Every message has a `date` field with Unix seconds. A
forwarded message also has a `forward_origin`, and that has its own `date`:
when the original was sent. The bot didn't parse either field before. Now it
does, and the webhook picks the earlier one:

```go
// PostedAt returns when the content was originally written: the forward origin's date
// for forwarded messages, otherwise the message's own date. Zero if unknown.
func (m *Message) PostedAt() int64 {
	if m == nil {
		return 0
	}
	if m.ForwardOrigin != nil && m.ForwardOrigin.Date != 0 {
		return m.ForwardOrigin.Date
	}
	return m.Date
}
```

The webhook only queues jobs. A worker Lambda reads them from SQS and calls the
model. So the date goes into the job as a new `posted_at` field, and the worker
passes it to the prompt with today's date next to it:

```go
// dateLine grounds the model in the real date; without it, it guesses the year from its training data.
func dateLine(posted, now time.Time) string {
	const layout = "2 January 2006"
	today := now.UTC().Format(layout)
	if posted.IsZero() || posted.UTC().Format(layout) == today {
		return fmt.Sprintf("Today is %s.\n", today)
	}
	return fmt.Sprintf("Posted on %s. Today is %s.\n", posted.UTC().Format(layout), today)
}
```

The model sees one line, for example `Posted on 2 March 2026. Today is 13
November 2026.` If the post is from today, it just sees `Today is 13 November
2026.` I spelled out the month so there's no doubt whether `03/11` means March
or November.

The line goes in the user message, with the other facts about the post: who
forwarded it, whether it has an image. The system prompt stays the same on
every call.

I also updated the rule so it refers to the new line:

```
Don't invent facts: no years, dates, figures or details that aren't in
the post, the image or the context. The message tells you today's date;
if you mention the current year or time, use that, never a year from
your own memory.
```

Voice-message summaries get the same date line. A summary of "let's meet next
Friday" is more useful when the model knows which Friday that is.

## A small detail: jobs already in the queue

The webhook and the worker are separate Lambdas, and SQS can still hold jobs
from before a deploy. An old job has no `posted_at`. The field is
`omitempty`, so it decodes as zero, and `dateLine` falls back to today's date
only. Nothing breaks during the deploy.

## After

The next roast was on a screenshot of an X post. The author was giving up on a
data science job search to retrain as a special-education teacher, because,
the post argued, people are having kids later and later. The caption: "We've
reached this point 😭".

![The same Telegram chat. A forwarded post captioned "Мы в этой точке 😭" ("We've reached this point"), a /roast reply, and the bot's answer in Russian, with "2026 года" ("of 2026") highlighted: "AI took the junior positions, the job market is wrecked, and the best career strategy of 2026 is literally counting how many forty-something men didn't get enough sleep before conception. Macroeconomics reached us through andrology."](/images/tldr-year-after.png)

"The best career strategy of 2026." The model still uses a year when the joke
calls for one. Now the year is right.

## What I'd take from this

- **A model has no clock.** If the date matters at all, put it in the prompt.
  Otherwise the model guesses from its training data, and it sounds just as
  sure as when it's right.
- **A rule against making things up only holds back.** It can't give the model
  a fact it doesn't have. If the model keeps inventing something, check
  whether you can just give it the real value.
- **"The date" can mean more than one date.** For forwarded content, the date
  it was written and today's date are different facts. Telegram gives you
  both.

This won't stop every invented detail. The model can still name the wrong
year, and the "80 square meter" flat from last week's testing has nothing to
do with dates. If a wrong year really mattered, I'd also check the output:
find any year that isn't in the input and regenerate. For jokes in a group
chat, one line in the prompt is enough.

The change is in [the tldr repo](https://github.com/vitkarpov/tldr/pull/2), in
`internal/summarize/summarize.go` and `internal/telegram/telegram.go`.
