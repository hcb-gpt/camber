# Camber: The Intelligence Layer for Heartwood (Updated Architecture)

**Executive Summary**
Version 3 · January 2026
Heartwood Custom Builders

---

## The Big Idea

Camber turns the daily stream of calls, texts, and emails into **actionable intelligence**—and then drives the next steps.

It's not just listening. It's understanding who's talking, what they're talking about, what needs to happen next, and what it means financially—then creating the follow-ups, flags, and tasks that keep projects moving without relying on anyone's memory.

Communication intelligence. Scheduling intelligence. Relationship intelligence. Financial intelligence. All in one system that gets smarter with every conversation.

Learning is primarily about internal Heartwood patterns (workflows, failure modes) — not external people profiling.

---

## What Problem Are We Solving?

Heartwood runs on human communication. Every day, dozens of calls and messages flow through the business—vendors confirming schedules, clients asking questions, subs discussing scope, Zack coordinating the field. Inside that stream is everything the company needs to know:

- What's happening — status updates, progress reports, issues surfacing
- What needs to happen next — commitments, deadlines, follow-ups
- Who's involved — which vendor, which project, which people
- What it costs — scope changes, invoice previews, budget implications

Today, that intelligence lives in human memory. Chad and Zack connect the dots. They remember that Malcolm said he'd finish Friday. They know that number belongs to the electrician on Permar. They recognize when a scope change means a budget adjustment.

This works—until it doesn't. With multiple jobs running in parallel, things slip. Follow-ups get missed. Relationships go stale because nobody remembered to check in. Invoices land without context. The knowledge exists, but it's trapped in conversations that happened three days ago and were never written down.

---

## What Camber Actually Does

Camber extracts intelligence from every communication and turns it into structured, actionable information. The system has **four functional layers** (what it does) and **three platform components** (how it stays coordinated and trustworthy).

### Functional layers (what it does)

#### 1) Capture & Understanding (Communication Intelligence)
Camber ingests calls and messages, produces transcripts, and generates:

- Summaries — What actually happened here?
- Decisions and commitments — What did someone agree to do?
- Entities — Who/what/where (people, projects, vendors, locations)
- Time signals — Dates, sequencing, "before/after," deadlines

The goal is clarity: the conversation becomes a durable record that can be searched and acted on.

#### 2) Action & Follow-up (Scheduling Intelligence)
Camber converts meaning into momentum:

- Tasks — what needs to be done next, by when, by whom
- Follow-ups — commitments that must be tracked
- Deadlines — dates that matter
- Reminders — the "don't let this fall through the cracks" layer

This is the engine that reduces the cognitive load currently sitting on Chad and Zack.

#### 3) Identity & Relationship Context (Relationship Intelligence)
Camber answers "who is this?" reliably:

- Phone/email identity resolution → contact
- Contact → vendor/trade/company mapping
- Contact/vendor → projects touched
- Relationship history — searchable conversation context

Over time, this becomes institutional memory that does not depend on any one person.

#### 4) Financial Context (Financial Intelligence)
Camber connects words to money:

- Vendor inference — who this is financially
- Cost code mapping — which budget lines are implicated
- Scope signals — "this might change cost/schedule"
- Invoice context — when a bill arrives, show the conversations that led to it

This makes coding faster, more accurate, and much easier to audit.

---

## The Camber Architecture (how it stays coordinated and trustworthy)

### CAMBER (Sensemaking Engine)
CAMBER is the intelligence layer: it turns raw conversations into structured information (summaries, entities, tasks, financial context) and retains the trail of "why" behind each output.

### ORBIT (Orchestrated Routing Between Instances and Teammates)
ORBIT is the operating model that keeps work moving across humans and multiple AI instances (e.g., ChatGPT agents and Claude agents) with minimal friction:

- Routes work to the right endpoint (instance or teammate)
- Defines handoff formats (clear TO/FROM/SUBJECT/DATE)
- Enforces gates ("stop-the-line" when evidence or SSOT is missing)
- Coordinates "apply windows" so changes don't drift

The end-user goal: Chad can route work and approvals without fanfare.

### TRAM (Transport + Mailroom)
TRAM is the practical transport layer that makes ORBIT real:

- Packages deliverables into "envelopes" (addressed artifacts)
- Drops them into shared inboxes (Drive) so instances can pull their own mail
- Preserves a turn ledger ("what happened, when, and why")
- Rejects ambiguous or risky packages early (instead of silently routing)

This eliminates "copy/paste courier work" while keeping auditability.

---

## The Four Kinds of Intelligence

**1. Communication Intelligence**
What was said, and what does it mean?
Every call and message gets captured, summarized, and made searchable.

**2. Scheduling Intelligence**
What needs to happen next?
Commitments become tasks and reminders with dates and owners.

**3. Relationship Intelligence**
Who is this, and how do they connect?
Contacts resolve to vendors, projects, and history—fast, reliably.

**4. Financial Intelligence**
What does this mean for money?
Conversations are tagged with cost and scope signals so invoices arrive with context.

---

## A Day in the Life (After Camber)

**8:15 AM** — Zack takes a call from Malcolm. Camber captures the transcript, summarizes it ("Malcolm completing rough-in at Permar today, will invoice Friday"), and creates two follow-ups: expect Malcolm's invoice, confirm inspection scheduling.

**10:30 AM** — A cabinet vendor text thread mentions a lead time change. Camber flags likely schedule impact on Woodbery, creates a task for Zack to review, and tags it with cabinet cost codes.

**2:00 PM** — Chad reviews a single dashboard: what happened, what tasks were created, and what needs attention. One low-confidence item goes to the review queue—an unknown number that needs identity resolution.

**Friday** — Malcolm's invoice arrives. The system suggests: Permar, Division 26, electrical rough-in. The coding screen shows the conversations that led here. One click to confirm.

**Month-end** — Job cost reports reflect reality. Follow-ups don't disappear. Relationships stay warm. Work doesn't slip just because humans are busy.

---

## Why This Matters

**For operations:** Tasks and follow-ups get created automatically. The system provides impetus—it doesn't wait for someone to remember.

**For relationships:** Every conversation builds the relationship record. Contact history, project involvement, communication patterns—captured and accessible.

**For finance:** Invoices arrive with context. Cost coding gets faster and more accurate. Variance is meaningful because it's not buried under classification errors.

**For scale:** The cognitive load currently sitting on Chad and Zack gets distributed to a system that doesn't forget, doesn't get overwhelmed, and doesn't go on vacation.

---

## The Roadmap (Simplified)

**Phase 0–1: Harden Capture + Action**
Communications flow cleanly, timestamps are accurate, summaries are meaningful, tasks are being created consistently.

**Phase 2: Stand Up Financial Context**
Vendor registry, cost code structure, conservative inference logic, cautious thresholds. Start with high-volume vendors.

**Phase 3: Make It Trustworthy**
Quality checks, review queues, dashboards, override flows, and end-to-end audit trails.

**Phase 4: Refine and Expand**
Tune confidence thresholds based on real usage. Integrate external systems. Let the system handle the obvious cases automatically and reserve human attention for exceptions.

---

## Success Looks Like

- Every meaningful conversation produces a summary and at least one actionable item.
- Tasks and follow-ups get created without anyone having to remember.
- Relationships are tracked—who's involved, on which projects, with what history.
- Financial context is attached to interactions before invoices arrive.
- Chad and Zack trust the system enough to let it handle routine coordination and focus attention on what actually needs thought.

---

## The Bottom Line

Camber isn't just transcription or recordkeeping. It is the intelligence layer that makes Heartwood smarter with every conversation:

It captures meaning, produces follow-ups, keeps relationships coherent, ties words to money, and does it with audit trails and clear routing across humans and AI instances.

The goal is a company where important information doesn't live only in human memory—and where follow-ups don't depend on someone remembering.

That's Camber.

---

*Document prepared by Seat 02 (VP Product / Strategy)*
*Source: vision_v3_for_camber_v1 (updated to new architecture model)*
