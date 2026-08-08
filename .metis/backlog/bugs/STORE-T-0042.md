---
id: ephemeral-reservation-fails-on-windows
level: task
title: "open_ephemeral fails intermittently on Windows: ERROR_ACCESS_DENIED reserving a temp file"
short_code: "STORE-T-0042"
created_at: 2026-08-08T15:00:00.000000+00:00
updated_at: 2026-08-08T15:30:00.000000+00:00
parent: 
blocked_by: []
archived: false

tags:
  - "#task"
  - "#bug"
  - "#phase/completed"


exit_criteria_met: true
initiative_id: NULL
---

# open_ephemeral fails intermittently on Windows: ERROR_ACCESS_DENIED reserving a temp file

## Objective **[REQUIRED]**

**Filed after the fact, because the reasoning is worth more than the fix.** The fix is four
lines. What took the afternoon was that the first three explanations were wrong, and the
thing that settled it was one line of CI output that did not exist until we changed this
library to print it.

odin-rdf-shacl adopted `open_ephemeral` across its suites (v0.3.0, `STORE-T-0033`) and its
Windows CI job began failing intermittently: one or two of ~58 ephemeral opens per run, a
different test each run, three runs out of three. Every failure was
`Store_Error.Temp_Unavailable`.

## Bug Details **[CONDITIONAL: Bug]**

### Severity
- [x] High — a consumer's CI is red and cannot be made green by anything in that repository.

### Reproduction

Not reproducible on macOS or Linux, and **not reproducible in this repository at all**. See
the failed reproduction below, which is the most useful part of this record.

## Root Cause **[CONDITIONAL: Bug]**

`ERROR_ACCESS_DENIED` from `CREATE_NEW`, on a **fresh random name** in the Windows temp
directory.

That last detail is what identifies it. Windows reports a name that is already taken as
`ERROR_ALREADY_EXISTS`, which `os.create_temp_file` already retries; access denied on a name
nothing has ever used is another process holding a file briefly — on a CI runner, a scanner
or the indexer. This library's own file lifecycle was excluded before reaching that
conclusion: `close` calls `env_close` before `os.remove`, so it never leaves a
delete-pending name behind for a later create to trip over.

`os.create_temp_file` retries only on `.Exist`. So one transient refusal ended the open.

## Resolution **[CONDITIONAL: Bug]**

Two changes, in two releases, and the order mattered.

**v0.3.1 — stop classifying the error.** `ephemeral_reserve` collapsed every failure into
`Temp_Unavailable`, which reported that something went wrong and nothing about what. The
`Error` union gained `os.Error` and the reservation returns it verbatim;
`Store_Error.Temp_Unavailable` was removed rather than left as a classification with no
producer. **This is what found the bug**, on the first CI run after the consumer pinned it.

**v0.4.0 — retry the reservation.** Eight attempts over roughly 35ms, returning the last
error verbatim if they all fail. Reserving a temp file is idempotent and cheap; a temp
directory that is genuinely full or read-only still fails quickly and says why.

**This is mitigation of a transient OS condition, not a root cause.** The condition is
outside this library. What was wrong *here* is that one attempt was treated as a verdict.

v0.4.0 rather than v0.3.2 because v0.3.1 had shipped a breaking change — a public union
gained a variant, an enum lost a member — under a patch number, which this project's own
rule contradicts. v0.3.1 stays published; nothing depends on it.

## The reproduction that failed **[CONDITIONAL: Bug]**

`test_many_ephemeral_stores_open_at_once` was written to reproduce this: 8 threads, 8 whole
stores each, opened, written to, and held. **It passes on all three platforms, including
Windows.** It is kept anyway, and its comment says it does not reproduce the failure,
because a test that is quietly known not to cover the thing it was named for is worse than
no test.

The existing `test_ephemeral_names_never_collide` did not catch this either, and the reason
is instructive: it reserves *names* concurrently, and reservation is only half of
`open_ephemeral`. The other half is an LMDB environment that materializes its entire
`map_size` on disk the moment it opens under Windows.

## Two dead hypotheses, recorded so nobody re-derives them **[CONDITIONAL: Bug]**

- **Concurrent ephemeral opens are the trigger.** Killed by the 8×8 test above passing on
  Windows.
- **The Odin test runner seeds every test's RNG identically, so temp names collide far more
  on Windows** — where `open_ephemeral` keeps its file until `close` rather than unlinking
  it immediately, holding names longer. Checked locally: two tests in one run draw different
  names. False.

A third — that concurrent 1 GiB durable maps were exhausting the temp volume — was never
tested, and the real error made it unnecessary.

## Verification **[REQUIRED]**

- [x] The error is named rather than classified: the failing run reported `Permission_Denied`
      instead of `Temp_Unavailable`, which is the whole reason this entry can name a cause.
- [x] **Five consecutive odin-rdf-shacl CI runs green on Windows**, against three of three
      failing before. Stated as what it is: the failure rate dropped below what five runs can
      detect. It is not proof the condition cannot recur, because the condition is not ours.
- [x] `make test` green at both `Term_ID` widths, `make check` clean.

## Status Updates **[REQUIRED]**

- **2026-08-08 — Fixed and released as v0.4.0; filed here afterwards.** The lesson worth
  carrying is not about temp files. **A library that classifies an error it does not
  understand destroys the only evidence anyone will ever have**, and it does it at the one
  point in the program that held it. `Temp_Unavailable` looked like good hygiene — a tidy
  domain error instead of a leaky OS type — and it cost three wrong hypotheses and two
  releases. The `Error` union carrying `os.Error` is the durable half of this fix; the retry
  is the disposable half.
