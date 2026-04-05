---
title: My On-Call Investigation Tool
date: 2026-04-05
draft: false
tags:
  - mcp
  - ai
  - infrastructure
  - devops
categories:
  - devops
  - mcp
  - ai
  - infrastructure
---

I've been on-call and the thing that always got to me wasn't the incidents themselves, it was the context-switching. You get paged, you stop what you're doing, you open six different tools, each with its own auth and query language, and you start piecing together what's broken. By the time you've gathered enough signal to have a theory, twenty minutes have passed and half of that was just logging in to things.

I was already using Claude for ad hoc investigation, asking it to help me read logs, check on things. At some point I thought, what if I just gave it access to everything I normally check during an incident, plus all the knowledge about what usually goes wrong? So I built a Claude Code skill and a custom MCP server for it.

The MCP server is about 800 lines of TypeScript. It gives Claude access to our databases, message queues, Elasticsearch, Kafka, and Redis. I also plugged in managed MCP servers from vendors for Kubernetes, our observability platform, documentation, data warehouse, and incident management. I kept each domain in its own server: different auth, different failure modes. If one connection is flaky, everything else still works.

Now when I get paged I type something like

> I got paged for Incident 199

and the skill kicks off. It checks the relevant logs, queries databases, finds the runbook, correlates with recent deployments. What used to take me twenty minutes of clicking around happens in about three.

I underestimated how much tool descriptions matter. The description is what the AI reads to decide whether and how to use a tool. My Elasticsearch tool originally just said "search an Elasticsearch index." The AI would try indices that didn't exist, get the naming convention wrong, waste time. I rewrote the description to include our actual index naming patterns, environment prefixes, date suffixes. It ended up longer than the implementation. But it gets the right index on the first try now. Same with databases, I had to put which databases exist and what they contain directly into the tool metadata. Felt like over-documenting. Turns out that's the difference between useful and useless.

The other thing that took more time than expected was making the whole thing safe. Dedicated read-only database users, read-only Kubernetes roles, result size caps, blocked dangerous query types. I opened shell sessions with the most restrictive permissions I could manage and built gating to ban commands like `cp`, `rm`, `mv`. Tedious, but the kind of tedious that lets you sleep easy knowing it can't do anything dramatic. This was all before Anthropic shipped auto-accept permissions in Claude Code, which is now my default.
Even when it has the right access, it doesn't always get the investigation right. Early on the AI had a bad habit of going deep instead of going broad. I'd mention one signal and it would latch onto it, building an elaborate theory about why that one thing was the root cause, ignoring everything else. I had to learn to steer it away from that. It still does this sometimes. It's a tool, not a replacement for thinking.


The first time it ran a full investigation correctly I was pretty amazed. Then I had to copy-paste its findings into a chat thread for my team, which was tedious. That's when I realised I was already using our observability platform's MCP server for logs and metrics. I had it start creating notebooks instead. Now every investigation produces a shareable notebook with graphs, metrics, log links, and a summary, all scoped to the incident window. Instead of pasting terminal output into Slack, I share a link.

Over time I encoded about a dozen recurring incident patterns into the skill, things we've seen before and know how to investigate. Each pattern has the signals to check, queries to run, and known resolutions. Runbooks are mapped to patterns too, so the right docs surface automatically. We have this recurring bug around holidays, a scheduled job that breaks when things arrive earlier than expected, like before Christmas. Debugging it requires mental math across scheduling windows and system state. That kind of knowledge usually lives in one or two people's heads. Now it's in the skill, available to whoever gets paged.

I also built a feedback loop. After incidents resolve, a separate skill reads through closed incidents and postmortems, compares them against the pattern library, flags gaps, and drafts new patterns for review. The investigation knowledge compounds instead of sitting in a postmortem nobody reads.

People are jaded about AI, so I didn't announce this to the whole team. I started with a small cohort. The feedback was positive but not groundbreaking. I kept using it on my own on-call rotations, kept improving it with every incident, and it slowly got better. Eventually I published it to our internal npm registry as a shared Claude skill. Not everyone uses it. But the people who do keep coming back, which is a good sign.

A few things I'd do differently. Start with the tool descriptions, not the code. The descriptions drive how the AI uses the tools, which drives whether the whole thing is useful. Budget for auth, the tool implementations were straightforward but auth, credential management, token refresh, tunnels, onboarding docs, that's where the real time went. And don't build integrations on assumptions. We built a whole environment for our analytics stack before discovering all the useful data was already in the data warehouse. Check what's actually there first. I use it whenever I can now, and it's working.
