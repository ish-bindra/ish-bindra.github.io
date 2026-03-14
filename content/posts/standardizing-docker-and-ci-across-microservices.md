---
title: Standardizing Docker and CI across Microservices
date: 2026-02-17
draft: false
tags:
  - docker
  - nodejs
  - ci-cd
  - devops
categories:
  - devops
---
**The company I'm working at currently runs around 30 Node.js microservices.** At that scale, it doesn’t take long for each service to start developing its own "personality."

At first, it’s subtle. One service uses a slightly different base image; another has a bespoke CI script because of a weird test dependency. But eventually, you wake up and realize no two services work the same way. On paper, they all do the same thing: install dependencies, build TypeScript, run tests, and deploy. In practice, every repository has its own "flavor" of that workflow.

We hit the breaking point this year. A high-severity CVE dropped, requiring a Node image upgrade across the board. What should have been a morning's work turned into a multi-week slog of opening dozens of identical pull requests and babysitting 30 different pipelines.

That was our "never again" moment. We decided to start treating our build infrastructure like a platform.

## Accidental Complexity

None of our divergence was intentional. It just accumulated. Over time, copy-pasted CI pipelines were modified "just for this one fix," and those fixes became the new standard for that specific repo.

This created a massive tax on the team:
- Maintenance Overhead: Security patches meant touching every single repository.
- Onboarding Friction: New engineers had to learn the "quirks" of a specific repo before they could even get a green build.
- Configuration Drift: Some services had optimized layer caching; others were rebuilding everything from scratch every time, wasting hours of CI runner time.

## Declarative Service Configuration
The core idea was simple: **Separate _what_ a service needs from _how_ it gets built.** A developer shouldn't have to care about Docker layer caching strategies or how to orchestrate a test database in a CI runner. They should just be able to declare their requirements.

We moved all the "how-to" logic, the Dockerfiles, the shell scripts into a centralized repository. Now, each service repo contains a single, human-readable yaml config file at its root.

It looks like this:

``` yaml
name: my-service
team: platform

build:
  nodeVersion: 24
  tool: yarn

test:
  dependencies:
    postgresql:
    redis:
    elasticsearch:
      image: elasticsearch:7.17.29
```

Services declare what they need. The platform handles the rest.

## Practical issues showed up

Moving to a shared pipeline sounds great in a design doc, but the migration wasn't exactly "plug and play." Once we started onboarding more services, the edge cases started crawling out of the woodwork.

**The "Native Module" Headache**
Some services relied on building binaries, some required native C++ modules. We had to add support for building binaries and starting docker containers with provided binaries.

**Caching is King**
Our builds relied on agents caching layers from the previous step but it rarely happened. With aggressive ECR caching, our best-case build times plummeted from **6-8 minutes down to about 90 seconds**

**The "Escape Hatch" Strategy**
This was our most important cultural move. Engineers are (rightfully) terrified of being locked into a rigid system that breaks during an incident. We built in "escape hatches" from day one:
- `skipTests` or `hotfix` flags to bypass the heavy lifting during a production outage.
- Support for custom Dockerfiles. This proved useful for services that didn't fit the mold

Strangely enough, knowing they _could_ opt out made teams much more willing to opt in.

## The Result
Today, a Node version upgrade is a one-line change. When we optimize a Docker layer or fix a CI bug, every service in the company benefits immediately.

## Advice for Starting Out

If you’re managing a growing fleet of services and feeling the maintenance tax, here is my takeaway:

1. **Start Small:** Pick one simple service and one complex one. If the system works for both, it'll work for the others.
2. **Define a Clear Contract:** Make the configuration file the single source of truth for what the service requires.
3. **Build Escape Hatches Early:** Trust your engineers. Give them the tools to move fast, but ensure they have a way to opt out if a unique situation requires it.
