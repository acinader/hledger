# Performance: remaining ideas

Working notes: the ranked list of performance ideas not yet tried, kept between sessions.
Measurements, lessons learned and how to measure are in [PERFORMANCE](PERFORMANCE.md);
the September 2026 optimisation commits are listed by `git log --grep='^perf:'`.
Numbers below are for `hledger balance` on examples/100ktxns-1kaccts.journal (about 1.7s on a
MacBook Pro M5 Pro in late 2026-09, with 152 MB max residency).
A lot-using variant for idea 3 can be generated with tools/_100k-lots-journal.py (local, untracked).

Done in 2026-09: the megaparsec regression (fixed upstream in megaparsec 9.8.3, via our
[megaparsec#613](https://github.com/mrkkrp/megaparsec/pull/613); pinned in all stack configs),
and the residency reductions (strict parser accumulators, shared amount styles, account names and
commodity symbols: 2.6 -> 1.5 KB per transaction).

## Remaining ideas, ranked

Expected gains are for the 100k balance run; "general" means every command pays it.

1. Parser, 60% of the run (1.0s): a hand-written fast path for the common posting, date and number
   shapes would bypass megaparsec's per-token overhead, with the general parser as fallback.
   The biggest remaining target, but it means a second parser to keep consistent.
2. Report side, per command: the balance command is 0.31s (18%), mostly building the account tree
   (HashMap update and period data insertion per posting), and it computes amount widths more than
   once. print's own rendering is about 0.9s at 100k, and is shared by exports, hledger-ui and
   hledger-web: profile it.
3. Remaining lot overhead on lot journals, ~0.36s: calculateLots still sorts, rebuilds and re-ties
   every transaction (0.135s); basis-from-account-name and transacted-cost inference search every
   account name (0.07s); commodity tags, method coherence.
4. Small finalise stages, ~1-2% each: style inference (0.04s), account types (plus the regex
   fallback on every untyped-account lookup, accountNameInferType), cost tagging.
5. Remaining memory: the steady state is mostly postings, amounts and their maps, transactions,
   and descriptions (slices of the input text, which keep it alive). (The compacting collector,
   `+RTS -c`, was measured: 20-40% less memory for 40-60% more time; see PERFORMANCE. It's now
   suggested in the manual for users short of memory.)
6. Order of magnitude, not incremental: an on-disk cache of the finalised journal keyed by file
   contents and finalising options, skipping most of the run on unchanged journals; big feature
   with invalidation risks (includes, config, -I and friends, CSV/timeclock inputs). Parallel
   parsing of included files would help multi-file setups only.

Not worth retrying: nursery sizes; memory-doubling GC flags (unless the trade-off is reconsidered);
aggressive specialisation flags; deepseq in postingphelper; a dedicated `--timing` flag (`--debug=1`
was chosen); tying lot checks to `--lots`/holdings; removing parser labels; applying display styles
at render time instead of storing them per amount (7% of the run, but every report would need to
get it right); re-pointing postings during posting transforms, and releasing the balancer's input
journal early (both addressed short-lived peaks only); moving the finalised journal into a GHC compact
region (ghc-compact) so the GC stops copying it: `compactWithSharing` is needed (the journal is cyclic,
and its texts are slices of the input) and takes 1.3s for the 100k journal, three times what the GC
copying costs, and it comes after the memory peak. It might still suit hledger-web and hledger-ui,
which keep a journal loaded through many collections.
Also: recording journal items (jitems, for print --export) only on request. Measured with a
keep_items_ input option: the items cost about 60 bytes per transaction plus 70 per top-level
comment or directive line, so skipping them saved 5% of live data on the 100k journal (which has a
P directive per transaction) but only 2% without those directives; not worth a new option.
