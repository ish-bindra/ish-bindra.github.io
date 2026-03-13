---
title: "Standardizing Docker Builds Across Dozens of Microservices"
date: 2026-02-17
draft: false
tags: [docker, nodejs, ci-cd, devops]
categories: [devops]
---

When you're running dozens of Node.js microservices, it doesn't take long for each one to develop its own personality. Different Dockerfiles, different CI pipeline scripts, different ways of running tests. Each one works, but none of them work the same way. And when you need to make a cross-cutting change — say, upgrading Node versions or fixing a security issue in a base image — you're looking at touching every single repo.

I recently led an effort to replace all of that with a single, shared Dockerfile and a unified CI pipeline. One Dockerfile that every service uses. One pipeline definition that every service loads. Each service just declares what it needs in a small YAML config file, and the centralized system handles the rest.

It worked. But it wasn't straightforward. Here's what I learned along the way.

---

## The Problem: Configuration Drift at Scale

Every service had its own:

- **Dockerfile** — similar but not identical, with subtle differences in base images, build steps, and runtime configurations
- **CI pipeline** — copy-pasted and modified over time, each slightly different
- **Test infrastructure** — separate Docker Compose files for spinning up databases, caches, and message brokers during CI
- **Deployment scripts** — shell scripts for building images, running migrations, and deploying via Helm

On paper, they were all doing the same thing: install dependencies, build TypeScript, run tests, push an image, deploy. In practice, each repo had its own flavour of "the same thing," and that divergence created real maintenance overhead. Node version upgrades became multi-week projects. Base image security patches required PRs to every repo. New engineers had to learn each service's quirks.

## The Idea: Declarative Service Configuration

The core insight was separating **what a service needs** from **how it gets built**. A service shouldn't need to know about Docker layer caching strategies or how to bootstrap test databases. It should just declare: "I'm a Node 24 service, I use Yarn, and my tests need PostgreSQL and Redis."

That declaration lives in a `.service.yaml` file at the root of each service repo:

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
    elasticsearch:
      image: elasticsearch:7.17.29
```

That's it. The entire build configuration for a service. Everything else — the Dockerfile, the pipeline logic, the test dependency bootstrapping — lives in a single centralized repository that all services reference.

## The Golden Dockerfile: Multi-Stage Builds Done Once

The shared Dockerfile uses a multi-stage build with four meaningful stages:

**Stage 1 — Dependencies.** Install system packages needed for native modules (think Kafka clients, database drivers, compression libraries), then install Node dependencies. This stage only re-runs when `package.json` or lockfiles change, so it caches aggressively.

**Stage 2 — Builder.** Copy source code, run any code generation steps (ORMs that need to generate client code, for example), run lint and typecheck as quality gates, then compile TypeScript. This stage doubles as a dev/test image — it has everything you need to run the test suite.

**Stage 3 — Production dependencies.** Take the `node_modules` from Stage 1 and prune dev dependencies. This avoids rebuilding native modules from scratch — they're already compiled.

**Stage 4 — Runner.** Start from a clean slim base image. Copy only production dependencies, the compiled application, and config files. Set up a non-root user, add tini for proper signal handling, and configure the entry point.

A few things I wish I'd known going in:

**Native modules need runtime libraries too.** If you build something like a Kafka client in your dependency stage, it compiles against `libssl-dev`, `libsasl2-dev`, and so on. Those are *build-time* libraries. Your runner stage needs the *runtime* equivalents — `libssl3`, `libsasl2-2`, etc. Miss one, and your app crashes on startup with a cryptic shared library error. This is probably the single most common issue I hit.

**ORM code generation happens at the wrong time.** If your ORM has a "generate" step (producing a client library from your schema), it typically runs as a `prepare` script during `npm install`. But in a multi-stage build, you don't have your source code during the dependency stage. I had to tolerate the prepare script failing in Stage 1, then re-run it in Stage 2 after copying source. Not elegant, but it works.

**Copy the generated ORM client to production.** The generated client ends up in `node_modules/.prisma` (or equivalent). When you prune dev dependencies in Stage 3, that generated code might get blown away. You need an explicit `COPY --from=builder` to overlay it back onto the production `node_modules`.

**Keep-alive defaults changed in Node 19+.** Node started enabling HTTP keep-alive by default, which caused socket hang-ups with certain infrastructure configurations. I embed a small script that disables global keep-alive and load it via `--require` in the CMD. Subtle, but it saved hours of debugging.

## The Pipeline: What It Should Do

The CI pipeline is the other half of the system. Each service's pipeline file is about ten lines — it clones the central repository and loads the shared pipeline definition. The actual pipeline has six conceptual stages:

1. **Validate** — Check the `.service.yaml` against a schema before doing anything else. I use CUE for this, which gives you type-safe YAML validation. It catches mistakes like unsupported Node versions, invalid service names, or missing required fields before you waste time on a build.

2. **Build** — Read the service config, build the Docker image using the shared Dockerfile (or the service's own Dockerfile if it opts out), push to a container registry with registry-level caching.

3. **Test** — Read `test.dependencies` from the config, spin up containers (PostgreSQL, Redis, Elasticsearch, whatever the service needs), wait for health checks, inject connection strings as environment variables, and run `yarn test` inside the dev image. Tear everything down after.

4. **Quality gates** — Security audit (soft fail — it notifies but doesn't block).

5. **Approval gates** — Automatic for sandbox/staging, manual approval for production.

6. **Deploy** — Create a PR to a GitOps repository with the new image tag. ArgoCD picks it up from there.

The key design choice: the pipeline reads everything it needs from `.service.yaml`. Services don't write pipeline logic. They declare what they need, and the pipeline figures out the rest.

## Schema Validation: Catching Mistakes Early

One of the best decisions I made was adding schema validation using CUE. The `.service.yaml` file is validated against a CUE schema before the pipeline does anything else. The schema enforces:

- Service names must be lowercase alphanumeric with hyphens
- Node version must be one of the explicitly supported versions (20, 22, 24 — not 18 anymore, not 19, not "latest")
- Build tool must be `yarn` or `npm`
- Container registry repository must follow a specific naming pattern

This catches configuration errors in seconds rather than minutes into a failed build. It also documents the contract between services and the pipeline — the schema *is* the documentation of what's supported.

I wrote BATS tests for the validation itself, covering valid and invalid fixtures. It's a small thing, but it gives confidence when modifying the schema — you can verify that tightening a constraint actually rejects what it should.

## Test Dependencies: The Hardest Part

Getting test infrastructure right was where I spent the most time. The old approach was a `docker-compose-build.yml` file in each repo. The new approach bootstraps containers from the `test.dependencies` section of `.service.yaml`.

For known services (PostgreSQL, Redis, Elasticsearch), the pipeline knows the defaults — which image to use, how to health-check it, and what environment variables to inject. Services can override the image or add custom environment variables.

Things that tripped me up:

**Database migration ordering matters.** The pipeline runs `yarn test`, which triggers `pretest` as a lifecycle hook. My first service needed database migrations before tests could run. I initially ran the ORM's schema generation in `pretest`, but that only generates the client — it doesn't create tables. Switching to running the actual migration command in `pretest` fixed it. This is the kind of thing that's obvious in hindsight but wasted a full debug cycle.

**Coverage tools can conflict with your dev server.** One service used a coverage tool that conflicted with its dev server module. Switching coverage libraries resolved it, but the lesson was that standardizing `yarn test` as the entry point means you need to make sure your test command actually works as a standalone — no ambient processes, no shared state, no dev server assumptions.

**Auth tokens for private registries.** If your services pull packages from private registries, the Dockerfile needs the auth token at build time. Hardcoding it in `.npmrc` means it ends up in your repo. Passing it as a build argument and writing it to `.npmrc` during the build is cleaner and keeps secrets out of source control.

## Escape Hatches: Essential for Adoption

Not every service can use the shared Dockerfile. Some need system-level dependencies that don't make sense to include for everyone — headless Chrome for PDF generation, Canvas libraries for image processing, or unusual native dependencies.

For these, the config supports `customDockerfile: true`. The service provides its own Dockerfile, but still uses the shared pipeline for everything else — testing, deployment, gating. This was critical for adoption. If the system was all-or-nothing, the edge cases would have blocked the entire rollout.

Similarly, services can override the default entry point, use a different Node version, or use npm instead of Yarn. Each of these is a one-line change in `.service.yaml`.

## Caching: Making It Fast Enough

Nobody will adopt a shared build system if it's slower than what they had. Container registry-level caching was essential. The pipeline pulls cached layers from the most specific source available: first the current branch, then the develop branch, then main. It exports cache after every build so subsequent builds on the same branch are fast.

BuildKit cache mounts on the dependency installation step mean that even when the lockfile changes, only the delta gets installed rather than starting from scratch. For a service with hundreds of dependencies including native modules, this cuts build times significantly.

## Rolling It Out: Start with One Service

I migrated one service first — one with moderate complexity (PostgreSQL, Redis, Elasticsearch, Kafka, an ORM, native modules). This surfaced most of the edge cases without risking critical infrastructure.

The migration for each service follows the same pattern:

1. Create a `.service.yaml`
2. Add a `pretest` script to `package.json` for any test setup
3. Replace the pipeline file with the ten-line loader
4. Delete the old Dockerfile, build scripts, and test infrastructure files
5. Test with the shared pipeline on a feature branch
6. Merge

For the first service, this took about two weeks of iteration. Now that the patterns are established, subsequent services take a day or less.

## Testing Pipeline Changes Safely

When you change a shared pipeline, you're changing the build for dozens of services at once. The safety mechanism is simple: the pipeline loader accepts a branch override. To test a change, push it to a branch in the central repo and trigger a build on a low-risk service with that branch specified. Verify it works. Test on a second service with different characteristics. Then merge.

This was important for building team confidence. Nobody has to trust that a change is safe — they can verify it on a real service before it affects everything.

## What I'd Do Differently

**Start with the schema, not the Dockerfile.** I spent early iterations tweaking the Dockerfile before the service contract was clear. Defining `.service.yaml` first — what services can declare, what's required, what's optional — would have saved some rework.

**Don't underestimate test infrastructure.** The Dockerfile and pipeline logic were relatively straightforward. Getting test dependencies, health checks, environment variable injection, and init scripts working reliably across different services was the real challenge.

**Document the escape hatches from day one.** Engineers are more willing to adopt a standard if they know they can opt out of specific parts. Having `customDockerfile`, skip-test flags, and branch overrides documented upfront reduced resistance.

## The Result

Every service now has the same build, test, and deploy pipeline. Node version upgrades are a one-line YAML change per service. Dockerfile improvements benefit all services immediately. New engineers onboard faster because there's one pattern to learn, not twenty.

The total configuration per service went from hundreds of lines across multiple files to a single YAML file under twenty lines. That's the real win — not the uniformity for its own sake, but the reduction in accidental complexity that was slowing everyone down.

---

*If you're considering a similar standardization effort, my advice is: start small, make escape hatches first-class, and expect the test infrastructure to be harder than the Dockerfile.*
