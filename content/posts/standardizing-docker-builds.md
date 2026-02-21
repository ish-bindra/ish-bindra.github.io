---
title: "Standardizing Docker Builds Across Dozens of Microservices"
date: 2026-02-17
draft: false
tags: [docker, nodejs, ci-cd, devops]
categories: [devops]
---

We had about 40 Node.js microservices, each with its own Dockerfile and CI pipeline. They all did basically the same thing — install dependencies, build TypeScript, run tests, push an image — but every repo had its own variation. Upgrading Node versions meant touching every single one. It was tedious.

I spent a few months replacing all of that with a single shared Dockerfile and pipeline. Each service now just declares what it needs in a small YAML file, and the centralized system handles the rest.

Here's what made it work and what didn't.

## The Setup

Instead of each service maintaining its own build scripts, they now have a `.service.yaml`:

```yaml
name: my-service
team: platform

build:
  nodeVersion: 24
  tool: yarn

test:
  dependencies:
    postgresql:
    redis:
```

That's it. The actual Dockerfile and pipeline logic lives in one central repo that all services reference.

## The Shared Dockerfile

Four-stage multi-stage build:

1. **Dependencies** — Install system packages and Node modules. Only re-runs when package.json changes.
2. **Builder** — Copy source, compile TypeScript, run lint. This stage doubles as the test image.
3. **Prod dependencies** — Prune dev dependencies without rebuilding native modules.
4. **Runner** — Clean base image with only production code and dependencies.

### Things That Weren't Obvious

**Native modules need runtime libraries.** If you compile a Kafka client against `libssl-dev` in the builder stage, your runtime stage needs `libssl3`. Miss one and you get cryptic shared library errors at startup. This tripped me up constantly.

**ORM code generation is awkward.** Tools like Prisma generate code during `npm install`, but you don't have source files yet in the dependency stage. I had to let it fail there, then re-run generation after copying source. Not clean, but works.

**Node 19+ changed keep-alive defaults.** This caused random socket hang-ups with our load balancers. Had to disable keep-alive globally via a required script.

## The Pipeline

Each service's pipeline file is about 10 lines — it just loads the shared pipeline definition. The shared pipeline:

1. Validates `.service.yaml` against a schema (using CUE)
2. Builds the Docker image
3. Spins up test dependencies (PostgreSQL, Redis, whatever's declared)
4. Runs tests
5. Creates a deployment PR

The schema validation catches mistakes early — invalid Node versions, typos in service names, etc.

## Test Dependencies Were the Hard Part

The old approach was a `docker-compose.yml` in each repo. The new approach reads `test.dependencies` from the config and bootstraps containers automatically.

Sounds simple. Wasn't.

**Migration scripts need to run before tests.** I initially ran database migrations in a `pretest` hook, but the ORM's "generate" command doesn't create tables — only the client. Had to switch to running actual migrations. Obvious in hindsight.

**Coverage tools can conflict.** One service's coverage tool broke when run alongside the dev server. Switching libraries fixed it, but it meant `yarn test` has to work standalone with no ambient processes.

**Private registries need auth tokens.** Hardcoding `.npmrc` credentials in the repo is obviously bad. Pass them as build args and write them during the build instead.

## Escape Hatches

Not every service fits the standard. Some need headless Chrome for PDFs, or Canvas for image processing. For these, services can set `customDockerfile: true` and provide their own Dockerfile while still using the shared pipeline.

This was critical. If it was all-or-nothing, nobody would've adopted it.

## Rolling It Out

Started with one moderately complex service (PostgreSQL, Redis, Elasticsearch, Kafka, native modules). This surfaced most of the edge cases.

Migration per service:
1. Create `.service.yaml`
2. Add `pretest` script if needed
3. Replace pipeline file
4. Delete old Dockerfile and build scripts
5. Test on a branch
6. Merge

First service took two weeks. Now it takes a day.

## What I'd Do Differently

**Define the schema first.** I spent weeks tweaking the Dockerfile before the service contract was clear. Starting with `.service.yaml` — what can services declare, what's required — would've saved rework.

**Test infrastructure is harder than the Dockerfile.** The multi-stage build was straightforward. Getting health checks, environment variable injection, and init scripts working across different services took way longer.

**Document escape hatches early.** People adopt standards faster when they know they can opt out of parts. Having `customDockerfile` and override flags documented upfront reduced pushback.

## The Result

Every service now has the same build, test, and deploy flow. Node upgrades are one line per service. Dockerfile improvements benefit everyone immediately. New engineers learn one pattern instead of twenty.

Total config per service went from hundreds of lines across multiple files to about 15 lines in one YAML file.

---

*Start small, make escape hatches first-class, and expect the test infrastructure to be harder than the Dockerfile.*
