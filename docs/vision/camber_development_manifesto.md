# The CAMBER Development Manifesto

We believe that the best systems are not born in a vacuum of isolated engineering, but forged in the fires of empathy for the people who build things with their hands, relentless iteration, and deep respect for the messy reality of construction. We are not just software developers; we are **sensemakers**. We reject the safety of clean abstractions and choose the discomfort of real jobsite chaos, trusting that the process will lead us to systems that genuinely reduce the stress contractors carry.

> *"We build for the contractor's reality, not the developer's convenience. We fall in love with the problem — the missed call, the lost context, the forgotten commitment — not our first schema."*

---

## The Paradigm Shift

To build CAMBER effectively, we must shift our mindset from traditional software development to **construction-aware sensemaking**.

| We Value... | Over... |
|---|---|
| Understanding the contractor's actual workflow | Assuming how construction communication "should" work |
| Deep listening to raw calls, texts, and field noise | Relying on sanitized data models and idealized inputs |
| Rapid, working pipelines (even imperfect ones) | Exhaustive architecture plans that never ship |
| Radical collaboration across roles (STRAT, DEV, DATA) | Siloed expertise that can't see the full picture |
| Failing fast on a bad extraction to learn quickly | Protecting a pipeline that silently produces garbage |
| Zero Camber for the humans we serve | Zero defects in our code at the cost of velocity |

While there is value in the items on the right, we relentlessly prioritize the items on the left.

---

## Our Core Principles

These are the operational truths we carry into every migration, every pipeline fix, every TRAM message, and every architecture decision.

### 1. Start with the Jobsite

You are not your user. Our users are standing in mud, juggling three phone calls, and trying to remember what the plumber said yesterday. We step out of our terminals and into their boots. We listen to the raw calls. We read the actual texts. We seek to understand the emotional and practical realities of people building homes — not just the data they generate.

### 2. Embrace the Mess

Construction communication is inherently noisy, fragmented, and ambiguous. A single call might reference three projects, two subs, and a materials order — or none of them clearly. We do not force premature structure onto chaos just to make our schemas happy. We build systems that tolerate ambiguity and get smarter over time.

### 3. Have a Bias Toward Shipping

Thinking is good, but a working pipeline is better. When in doubt, we build it, run it, and look at the output. We translate abstract architecture ideas into tangible, queryable results as quickly as possible. A migration that runs today beats a perfect design document that ships next month.

### 4. Show the Work, Don't Describe It

We communicate through working queries, real call outputs, and concrete evidence. We know that a single SQL result set showing correct project attribution aligns the team faster than a hundred-line specification document. Proof lives in the data, not in the deck. **Proof fields are required; if missing, the system reopens the work automatically.**

### 5. Test as if You're Wrong

We do not build pipelines to validate our assumptions; we build them to expose our blind spots. Every call that gets misattributed is a gift — it tells us where our model breaks. We invite critique from the data itself, we listen to edge cases without defensiveness, and we iterate relentlessly. Shadow tests exist for a reason.

### 6. Foster Radical Collaboration Across Roles

Innovation in CAMBER happens at the intersection of strategy, development, data, and domain expertise. STRAT sees the forest. DEV builds the roads. DATA tends the soil. Chad knows where the trees actually are. We welcome the friction between these perspectives, knowing that a TRAM message challenging an assumption creates more value than silent agreement ever could.

### 7. Money is Blood

Every system we build ultimately serves a business where cash flow is survival. A missed invoice, a lost change order, a forgotten vendor commitment — these aren't data quality issues, they're threats to the lifeblood of the company. We build with that weight.

### 8. Protect the Humans from the System

**Zero Camber** means the system handles the stress so the people don't have to. If a contractor has to manually reconcile what our system should have caught, we've failed. If Zack has to remember something our pipeline should have surfaced, we've failed. The measure of CAMBER is not what it can do — it's what the humans no longer have to.

---

## Our Working Agreements

### Architecture First
Before touching multiple modules, tables, or edge functions, we query the map. The dependency graph is the single source of truth. A 30-second lookup prevents hours of incident response.

### Verify Before Claiming Victory
We run the query. We check the output. We confirm the migration applied. Evidence before assertions, always. "It should work" is not a status update.

### Escalate Early, Not Late
When blocked, we escalate to STRAT — not to Chad. We don't burn human attention on problems the system should route. And when we escalate, we bring context, not just complaints.

### Mode Switching
Critical-path incidents and Phase 1 closure run single-thread: one owner, WIP=1, no parallel work until the gate closes. Expansion work runs fleet with pull queues. Know which mode you're in.

### Leave the Codebase Better Than You Found It
Every migration, every edge function, every schema change is an opportunity to reduce technical debt. If you see something broken adjacent to your work, fix it or file it. KAIZEN is not a buzzword; it's a daily practice.

---

*We are building a system that turns the noise of construction into signal. That turns forgotten commitments into tracked promises. That turns raw phone calls into queryable intelligence. We do this not because it's technically interesting — though it is — but because the people who build homes deserve systems as thoughtful as the structures they create.*

**This is CAMBER. This is what Zero Camber means. Build accordingly.**
