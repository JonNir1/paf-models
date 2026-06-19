---
name: code-test-review-loop
description: Run a looped Coder->Tester->Reviewer cycle on a coding task for this PAF/EMC2 repo until the Reviewer signs off ("ship") or a max-iteration cap is reached. The main session is the durable orchestrator: it keeps the three subagents warm (continued via SendMessage), carries a persistent open-issues ledger across iterations, runs autonomously, and reports once at the end. Use for "/code-test-review-loop <task>", "code/test/review until clean", "iterate on X with the agent loop". Pass iterations=1 (or single) for a single pass.
---

# code-test-review-loop

You (the main assistant) are the **durable orchestrator**. You drive a looped Coder -> Tester -> Reviewer cycle over one task, keep the three subagents **warm** across iterations, maintain a shared **open-issues ledger**, and stop when the Reviewer ships or the iteration cap is hit. The agents are defined in `.claude/agents/` and all share this working tree.

The user invoking this skill IS the explicit request to spawn agents.

## Inputs (parse from the skill args)
- **task** — the change to implement (the bulk of the args). If absent, ask the user once; do not invent it.
- **max-iters** — iteration cap. Default **3**. (`iterations=1` or the word `single` => exactly one pass, i.e. the old single-shot behavior.)

## Core mechanics
- **Warm agents.** Spawn each agent ONCE with the Agent tool (`subagent_type: Coder` / `Tester` / `Reviewer`, **no isolation** so they share this tree). Record each agent's id/name. On every later iteration, **continue the same instance with `SendMessage`** — never cold-re-spawn (that throws away context and costs more).
- **Open-issues ledger.** A running list you maintain across iterations = Reviewer's blocking items + any failures the Tester found. It is the agenda for the next Coder pass. Starts empty.
- **Sequential within an iteration; looped across iterations.** Coder and Tester both *write* the shared tree, so they cannot run concurrently, and Reviewer must read a stable post-Tester snapshot. This ordering is forced by shared state, not preference. (Reviewer is read-only: you MAY run it in the background while you compile the ledger, but do not let the next Coder pass start writing until the Reviewer has finished reading its snapshot.)

## The loop

```
ledger  <- {}            # open issues
verdict <- "needs-work"
iter    <- 0
while (verdict != "ship" && iter < max_iters) {
  iter <- iter + 1
  coder_step(iter, ledger)        # implement (iter 1) or fix ledger items (iter 2+)
  tester_step(iter, ledger)       # add/prune tests; re-test; confirm fixes
  verdict, ledger <- reviewer_step(iter)   # audit; refresh ledger
  if (length(ledger) == 0 && tests_green) verdict <- "ship"
}
report()
```

### coder_step
- **Iteration 1**: `Agent(subagent_type: Coder, ...)` with the full task + the reminders to reuse existing helpers and self-verify (parse + L1). Capture: files changed, summary, verification, anything risky/unverified. **If the Coder is blocked/fails, break the loop and report** - do not proceed to Tester.
- **Iteration 2+**: `SendMessage(Coder, ...)` with the current ledger ("address these, in priority order: ...") plus any Tester failure details. Capture what it changed.

### tester_step
- **Iteration 1**: `Agent(subagent_type: Tester, ...)` with the task + Coder's summary + changed-file list. It adds adversarial/edge tests with descriptive names, **prunes duplicate/irrelevant tests** (suite is bloated, >200), respects tiers (L1 fast/no-EMC2, L2 build-once, L3 tiny MCMC), and runs the affected tier. Capture: tests added/merged/removed (+rationale), failures found, net count, tier results.
- **Iteration 2+**: `SendMessage(Tester, ...)` -> "Coder changed X to address <ledger>; re-test, confirm those are now covered/passing, keep pruning." Capture updated results + any still-failing items (these stay in the ledger).

### reviewer_step
- **Iteration 1**: `Agent(subagent_type: Reviewer, ...)` (read-only) with task + Coder + Tester summaries + the changed code/test files. Capture its report: **verdict** (ship / ship-with-fixes / needs-work), blocking issues (`file:line`), test findings, quality notes.
- **Iteration 2+**: `SendMessage(Reviewer, ...)` -> "Re-audit after this iteration; confirm prior blockers <list> are resolved; give an updated verdict and any remaining blockers."
- Set `ledger` = Reviewer's remaining blocking items + Tester's still-failing items. Treat **"ship-with-fixes"** as needs-work unless the fixes are trivial and already applied.

## Stop conditions
- `verdict == "ship"` (Reviewer signs off, tests green), **or**
- `iter == max_iters` (cap reached - stop even if issues remain), **or**
- Coder hard-blocked (stop early).

## Final report (once, at the end)
Present a single consolidated report - not the raw agent transcripts:
- **Outcome**: shipped / capped-out-with-issues / blocked.
- **Per-iteration trace**: one line each - `iter N: <what Coder did> | tests <+a/-b net> | verdict`.
- **What was built** and files touched.
- **Test suite delta**: net count, notable additions/removals.
- **Residual issues** (if capped without ship): the remaining ledger, prioritized, with a recommended next action (targeted fix, or re-run the loop with a higher cap).

## Guardrails
- **Cap is mandatory** - never loop unbounded; default 3. Autonomous between iterations (no pausing), but respect a user interrupt.
- **No isolation / shared tree** - edits propagate; writers (Coder, Tester) never run concurrently.
- **Warm, not re-spawned** - use SendMessage to continue agents after iteration 1.
- **Don't commit** - leave the result in the working tree for the user to review/commit unless they say otherwise.
- Heavy MCMC (L3 / real fits) is slow and may be CI-only; let agents flag what they couldn't run locally rather than blocking the loop.
