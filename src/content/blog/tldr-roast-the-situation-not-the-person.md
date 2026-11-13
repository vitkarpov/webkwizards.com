---
title: "Teaching my Telegram bot to complain with us, not about us"
description: "I added /roast to my group-chat bot. The first version made fun of the wrong person, the second mocked the right one, and the one we kept roasts the situation instead. Plus what it took to get Claude running on Bedrock."
pubDate: 2026-11-23
tags: ['AWS', 'Go', 'AI']
image: /images/tldr-roast.png
---

My group-chat bot, [tldr](/blog/tldr-bot-for-voice-messages/), started life
summarizing voice messages. This week it learned a second trick: `/roast`.
You reply to any post with it (a forwarded channel post, a photo, a voice
message) and the bot answers with one short, dry joke.

It came from a real moment. Someone in our chat forwarded a post from the
channel of a founder who had sold his company to Yandex. The post was a photo
of a British TV studio: a big screen titled **"IF YOU HAVE TO… HEAT THE HUMAN
NOT THE HOME"**, with heated gloves for £12, heated insoles for £26 and a hot
water bottle for £3.50. The caption said, roughly, "Winter in Britain. Heating
your home is expensive, so they advertise heaters for people only ;)".

The chat's reaction was the usual mix of laughing and sighing. I wanted the
bot to join in. It took three rounds to get there:

![A Telegram chat. A forwarded post titled "Winter in Britain. Heating your home is expensive…" gets the reply "/roast это основатель стартапа на 30 ярдов" ("/roast this is the founder of a 30-billion startup"). The bot answers in Russian: "Britain 2022: put on an electric gilet, stick your feet into USB insoles, climb into a sleeping bag with a hot water bottle, and you're not a freezing person in an unheated house, just… a bit of a cyborg. The country that invented central heating advises heating people one part at a time." Someone replies to the bot: "во, вот это я понимаю!" ("now that's what I'm talking about!").](/images/tldr-roast.png)

That last line in the chat is the bar I was aiming for. Here's how the bot
got there, and the three things that went wrong first.

## How /roast works

It reuses everything from the summary bot: the webhook checks the chat and the
quota, puts a job on SQS, and a worker Lambda does the slow part. The new parts
are about what the bot can *see*:

- **Text and captions.** A forwarded post arrives in `reply_to_message` like
  any other message, with its text or caption.
- **The picture.** Telegram sends every photo in several sizes, smallest first.
  The webhook picks the largest one under 3.75 MB, which is Bedrock's limit for
  an inline image, and the worker passes it to the model as an image block.
- **Where it came from.** `forward_origin` says whether the post came from a
  user, a hidden user, a group or a channel, so the bot knows the author is an
  outsider and not someone in the chat.
- **Voice and video.** These are transcribed first, then roasted, using the
  same Amazon Transcribe path as `/tldr`.

One thing the bot *can't* see is the conversation around the post. It runs in
Telegram's privacy mode, so in a group it only receives commands, plus the one
message the command replies to. If you wrote "look at this, a founder with a
30-billion company is posting about hot water bottles" just above the forward,
the bot never sees it. So anything after `/roast` goes to the model as context:

```
/roast this is the founder of a 30-billion startup
```

That context line is useful. It also caused two of the three problems below.

## Round one: the bot roasted me

The first version ran on Amazon Nova Lite, the same small model that writes
the summaries. I tried it on the heating post with the founder context, and got
this:

> Виктор Карпов, твой стартап стоит 30 миллиардов, а вот зимой тебе придется
> таскать микроволновый мешок за 10 фунтов.

"Viktor Karpov, your startup is worth 30 billion, but in winter you'll have to
carry around a microwave bag for £10." I'm Viktor. I forwarded the post. The
startup isn't mine.

The prompt gave the model three people: who forwarded the post, who asked for
the roast (both me), and the original author. Then came a context line about
"the founder". The model had a name it could address and a description it
could attach to it, so it joined them up.

The fix had two parts. The prompt now spells out who is who: the author of a
forwarded post is "an outsider, not anyone in the chat", the people in the chat
are on the bot's side, and nobody gets addressed as "ты" ("you"). And the bigger
change: **the model no longer gets any chat member names at all.** It doesn't
need them to write a joke, and a name in the prompt is a name the model will
try to use.

I changed both at once, so I can't say which one did the work. But I'd make the
second change first next time: **don't give the model a name it doesn't need.**

## Round two: a better model, the wrong target

Nova Lite had a second problem: its Russian humor. That first reply ended with
"we'll all live in burnt shells, and you'll be in an electric gilet". It's
grammatical, and it doesn't mean anything. I added a few example roasts to the
prompt, but I didn't expect a small model to become witty in a language that
isn't its strongest.

So `/roast` now runs on Claude Sonnet 4.6 on Bedrock, behind a separate
`roast_model_id` setting. Summaries stay on Nova Lite, because they're about
getting facts right and Nova is fine at that. A roast is one short call with an
image, so a bigger model costs a fraction of a cent more per joke.

The Russian got much better right away. The target didn't:

> Человек продал бизнес на 30 млрд Яндексу, переехал в Лондон — и теперь с
> восхищением фотографирует грелку за 3.50 фунта. Это называется
> «адаптировался к местной культуре».

"A man sold a 30-billion business to Yandex, moved to London, and now admires
photos of a £3.50 hot water bottle. That's called 'adapting to the local
culture'." It's a good joke, at the author's expense. All three test runs were
the same joke: rich guy, cheap hot water bottle.

The trouble is that wasn't what the chat wanted. Nobody was laughing *at* the
author. He was laughing at the situation himself, with a `;)` at the end, and
we were laughing along. A friend in the chat doesn't answer that by mocking
the person who shared it. They pile on: "it's even worse than that".

## Round three: complain together

That changed the prompt from "roast the post" to something closer to "join
in". The core of it now reads:

```
Your job is to join in: pick up the emotion of the post (frustration,
disbelief, exhaustion, irony) and complain along with everyone in the
funniest way possible. You roast the situation, never the person.
```

Then a few rules that make it concrete:

- **You're on the author's side.** Whatever they're sighing about (prices,
  weather, bureaucracy, tech), you sigh too, louder and funnier.
- **The target is the situation.** Don't mock the author's money, naivety or
  choices, and don't make the joke "look who's talking".
- **Amplify, don't explain.** Take the absurd detail and push it one step
  further.

I also replaced the examples, because the model copies examples more closely
than any rule. The new ones are all about shared pain: a 590-ruble latte, a
phone update that deleted someone's notes, the earliest doctor's appointment
being in March.

That still wasn't enough. Two of the three runs led with the founder's money
again. The culprit was my own context line: "founder of a 30-billion startup"
sat in the prompt and pulled the joke toward the person. The fix was to say
what the context is *for*:

```
It is background that tells you how absurd things have got ("even he is
writing about this"); it is not the subject. The joke is about the
situation: don't build it on the author's money, career or biography.
```

After that, all three runs went after the situation:

> "Heat the human, not the home" — это уже не лайфхак, это диагноз. Шестая
> экономика мира, а решение — грелка за 3.50 и носки с проводом.

"'Heat the human, not the home' isn't a life hack anymore, it's a diagnosis.
The world's sixth-largest economy, and the solution is a £3.50 hot water
bottle and socks with a cable." Same facts, same picture, but now the bot is
on our side.

## It still makes things up

Look at the screenshot again: "Britain 2022". The post has no year, and the
chat happened in 2026. In testing, the model also invented a "2024" and an
"80 square meter" flat. The prompt now says not to state years, dates or
figures that aren't in the post, the image or the context. The screenshot
shows the rule doesn't always win. A joke wants a specific detail, and when
there isn't one, the model makes one up.

For a group chat I can live with that. For anything where the facts matter, I
wouldn't rely on a prompt rule alone.

## Getting Claude on Bedrock took three tries

The code change for Claude was small. Getting the account to allow it took
longer. Each step failed with a different error:

1. **Newest models: "not available for this account".** Claude Sonnet 5.5 and
   Haiku 5.5 are listed in eu-west-1, but calling them returned
   `AccessDeniedException`. Older models like Sonnet 4.6 answered, so I went
   with Sonnet 4.6.
2. **"Model use case details have not been submitted".** A few minutes later,
   Sonnet 4.6 stopped answering too. Anthropic models on Bedrock need a
   one-time use-case form per account: company, industry, intended users, and
   a short description. My first calls seem to have slipped through before
   that check kicked in. After I submitted the form, access came back in about
   four minutes.
3. **`INVALID_PAYMENT_INSTRUMENT`.** Claude on Bedrock is billed through an AWS
   Marketplace subscription, created on your first call. Mine couldn't be
   created because the account had no valid payment method. After I updated
   the billing details, it worked a couple of minutes later.

Two smaller things worth knowing. Claude models in eu-west-1 only run through
the `eu.` cross-region inference profiles, so the IAM policy needs both the
profile ARN and the foundation model ARN in every region it routes to. And if
your AWS CLI is a bit old, `aws bedrock list-inference-profiles` doesn't exist
yet. A tiny `converse` call with `maxTokens: 5` was the quickest way to check
access.

## What I'd take from this

- **Decide whose side the bot is on.** "Be funny" isn't a spec. "Be the friend
  who complains along with you" is, and it changed every joke.
- **Say what each input is for.** Context that's meant as background will be
  used as the punchline unless you say otherwise.
- **Leave out what the model doesn't need.** A name in the prompt is an
  invitation to use it.
- **Use the cheap model where it's good enough.** Summaries stay on Nova Lite,
  and only the part that needs wit pays for a bigger model.

The code, the prompt and the Terraform are on
[GitHub](https://github.com/vitkarpov/tldr). The prompt is in
`internal/summarize/summarize.go`, if you want to make your own bot complain
about your weather.
