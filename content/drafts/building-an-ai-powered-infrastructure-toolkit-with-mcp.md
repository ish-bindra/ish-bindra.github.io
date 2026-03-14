---
title: Building an AI-Powered Infrastructure Toolkit with MCP
date: 2026-03-13
draft: true
tags:
  - mcp
  - ai
  - infrastructure
  - devops
categories:
  - devops
---

When you're running a few dozen microservices, each with its own database, message queues, log indices, and Kubernetes deployments, the knowledge required to investigate a production issue is scattered across a lot of systems. Each system has its own auth, its own query language, its own UI. During an incident, an engineer has to context-switch between all of them — check pod health, search logs, query the database for stuck records, look at queue backlogs, find the relevant runbook, cross-reference recent deployments. Each step is a different tool and a different mental model.

I spent a few days building a system that lets any engineer on the team query all of that through natural language, using AI as the orchestration layer. This is what I learned doing it.

## MCP as the integration layer

I built this on [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) — an open standard that lets AI assistants call tools in external systems. You write a server that exposes typed tools with descriptions, and the AI assistant decides when and how to invoke them during a conversation. The protocol handles the plumbing — tool discovery, parameter validation, result formatting.

The architecture ended up being several MCP servers, each handling a different domain. I wrote a custom one (~800 lines of TypeScript) for databases, message queues, Elasticsearch, Kafka, and Redis. The rest are managed servers provided by vendors — for Kubernetes, observability, documentation, the data warehouse, and incident management. Each server runs as a local stdio process on the developer's machine. No shared infrastructure, no network listeners.

The key architectural decision was using multiple specialized servers rather than one monolithic server. Each domain has different auth requirements, different failure modes, and different rate limiting concerns. Keeping them separate means a flaky connection to one system doesn't take down access to everything else. It also means you can adopt incrementally — start with the database server, add observability later, add the data warehouse when you need cross-service queries.

## Designing tools the AI can actually use

The thing I underestimated was how much the tool descriptions matter. An MCP tool isn't just a function signature — the description is what the AI reads to decide whether and how to use it. Vague descriptions lead to wrong tool choices and bad parameters.

For example, the Elasticsearch search tool initially had a generic description like "search an Elasticsearch index." The AI would try to search indices that didn't exist, or use the wrong index naming convention. After I rewrote the description to include the actual index naming convention (environment prefix, service-specific patterns, date-suffixed indices), the AI started getting it right on the first try. The description ended up being longer than the implementation.

The same applied to database tools. Each environment has dozens of databases, one per service. Without encoding which databases exist and what they contain in the tool description, the AI would guess — and guess wrong. I added a summary of the key databases and their schemas directly into the tool metadata. It felt like over-documenting, but it's the difference between the tool being useful and the tool being a guessing game.

The lesson: MCP tool descriptions are prompts. Write them like you're explaining the tool to a new engineer who's never seen your infrastructure. Include naming conventions, common patterns, and the gotchas they'd hit on their first day.

## Read-only access is harder than it sounds

The entire system is read-only by design. But "read-only" has more layers than I expected.

For PostgreSQL, there are three levels of defence. First, a dedicated database user with the `pg_read_all_data` role — this grants SELECT on all tables but no INSERT, UPDATE, DELETE, or DDL. Second, `default_transaction_read_only` is set at the connection level, so even if a query somehow bypasses the role check, the transaction is rejected. Third, result sizes are capped at 1000 rows to prevent bulk data extraction.

The first two are database-level guarantees — they can't be bypassed by a creative prompt. The third is application-level and is really about being a good citizen rather than a security boundary. A motivated user could make many small queries to extract data, but they already have the same access through any database client.

Elasticsearch needed its own guardrails. I added a hard cap of 100 results per query and blocked Painless script queries entirely. Script queries can be computationally expensive and are a common vector for abuse in shared Elasticsearch clusters. The cap and the block are simple string checks in the request handler — not sophisticated, but effective for the threat model. The real protection is that Elasticsearch access goes through an SSM tunnel that requires active SSO credentials, so the access boundary is the same as someone connecting directly.

The thing I'd tell someone starting a similar project: don't try to make the access model more restrictive than what developers already have. Match it. The goal isn't to create a new security boundary — it's to make existing access more efficient without expanding it.

## Auth is the hardest part of team adoption

Every MCP server needs credentials. Multiplied across several servers, onboarding becomes a real friction point if you get auth wrong.

The managed servers were easy — most support OAuth with a browser popup. First time you use it, a browser window opens, you log in, and the token is cached. No config files, no environment variables, no token rotation to think about.

The custom infrastructure server uses SSO profiles that developers already have configured. No additional setup. The server reads the profile, assumes a read-only IAM role, and establishes tunnels as needed. This was important — if adopting the tool required setting up new credentials, half the team wouldn't bother.

The data warehouse was the exception. We wanted the same browser popup flow, but creating an OAuth app required account-level admin access we didn't have. We tried several approaches — personal access tokens (rejected because every developer would need to create and rotate one), service principals (too complex for a local development tool), the vendor's SDK (didn't support the auth flow we needed). We landed on a shell wrapper that calls the vendor CLI to fetch a fresh token at MCP startup. The token is valid for about an hour, which means long sessions need a restart. It's the worst auth experience of the bunch, but it's two minutes of setup and the team accepted it.

The lesson: every auth mechanism you add is a support burden. Prefer OAuth browser popups when available, fall back to existing CLI auth, and accept imperfect solutions over complex ones. The perfect auth flow that requires admin access you don't have is worse than the hacky wrapper that works today.

## Building an investigation skill on top

The raw MCP tools are useful on their own — you can ask ad hoc questions about any system. But the real payoff came from building an investigation skill that orchestrates multiple tools in a specific pattern.

The skill encodes about a dozen recurring incident patterns we've seen: payment processing failures, database connection pressure, deployment-related errors, queue backlogs, and so on. Each pattern has a set of signals to check — which logs to search, which metrics to look at, which database queries to run, which runbooks are relevant. When someone says "the payments service is throwing errors," the AI matches it to a pattern and checks all the relevant signals in parallel rather than exploring blindly.

We also mapped our runbooks to these patterns, so the right documentation surfaces automatically during an investigation. And we built an "absorb" skill that runs after an incident is resolved — it reviews the timeline, cross-references the postmortem, and proposes updates to the investigation patterns. The investigation knowledge improves with every incident instead of sitting in a wiki page nobody reads.

The part that surprised me: the skill's value isn't the automation — it's the encoding of institutional knowledge. Senior engineers know which logs to check when the payment service is down. They know which database to query and what a stuck transaction looks like. That knowledge usually lives in their heads. Encoding it in an investigation skill makes it available to the whole team, especially during off-hours on-call when the person paged might not be the domain expert.

## Cross-service queries were the unexpected win

Our data warehouse has CDC replicas of every production database. I added a data warehouse MCP server as an afterthought — mostly for analytics questions. But it turned out to be one of the most useful tools in the stack.

The reason: in a microservice architecture, answering questions that span services usually means querying multiple databases, correlating IDs manually, and hoping the data models line up. With CDC replicas in a single warehouse, a single SQL query can join across service boundaries. Order records joined with customer data joined with payment records — all in one query, running entirely on the warehouse, putting zero load on production.

Anyone on the team can ask these kinds of cross-service questions in plain English. The AI writes the SQL, the warehouse executes it, and the results come back in the conversation. For a team where not everyone knows the schema of every service, this is a significant unlock.

One gotcha: CDC replicas have replication lag. For real-time incident investigation, you need to query the production database directly. The data warehouse is better for historical analysis, trend spotting, and questions that span services. Making this distinction clear in the tool descriptions — when to use which — saved a lot of confusion.

## What I'd do differently

**Start with tool descriptions, not implementations.** I wrote the tool implementations first and added descriptions later. But the descriptions drive how the AI uses the tools, which drives how useful the whole system is. Writing descriptions first — what should this tool do, when should the AI use it, what does the AI need to know about the data — would have saved iteration.

**Don't build an analytics environment you don't need.** We initially built a third environment for our analytics stack, assuming it had useful databases. After investigation, it turned out all the business data lives in the data warehouse via CDC. The analytics environment only hosts pipeline tooling. We removed it. Check what's actually in a data source before building the integration.

**Expect auth to be half the work.** The actual MCP server code — tool implementations, query execution, result formatting — was straightforward. Auth, credential management, token refresh, SSM tunnels, onboarding documentation — that's where the time went. If you're scoping a similar project, budget accordingly.

## The result

The total system is about 800 lines of custom TypeScript plus configuration for the managed servers. Every engineer on the team can query databases, search logs, check Kubernetes health, run cross-service analytics, and find runbooks — all through natural language in the same conversation. The investigation skill surfaces the right signals and documentation automatically during incidents.

The thing this changed isn't really the tooling. It's who can answer infrastructure questions. Instead of needing to know which database to connect to, what the tunnel command is, and how to write the query DSL, someone can just ask. We're still early — the team is stress-testing it now and we'll see what breaks.

---

*Built on [Model Context Protocol](https://modelcontextprotocol.io/) and runs with [Claude Code](https://docs.anthropic.com/en/docs/claude-code).*
