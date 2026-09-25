# Performance: remaining ideas

Working notes: the ranked list of performance ideas not yet tried, kept between sessions.
Measurements, lessons learned and how to measure are in [PERFORMANCE](PERFORMANCE.md);
the September 2026 optimisation commits are listed by `git log --grep='^perf:'`.
Numbers below are for `hledger balance` on examples/100ktxns-1kaccts.journal (about 2.2s on a
MacBook Pro M5 Pro in 2026-09).
A lot-using variant for idea 5 can be generated with tools/_100k-lots-journal.py (local, untracked).

Pending upstream: [megaparsec#612](https://github.com/mrkkrp/megaparsec/issues/612) (filed
2026-09-23), fixed by [megaparsec#613](https://github.com/mrkkrp/megaparsec/pull/613) (INLINE
pragmas on the Stream instances, opened 2026-09-25 at the maintainer's invitation). Measured on
current hledger: about 10% off every command (balance 2.25 -> 2.03s, parse allocation 10.4 -> 7.8 GB).
Once released, raise hledger's megaparsec lower bound or snapshot.

## Remaining ideas, ranked (general ones first)

Expected gains are for the 100k balance run; "general" means every command pays it.

1. Megaparsec regression, ~10%, general. Wait for #612, or ship an interim fix: a newtype around
   the input Text with a direct Stream instance (INLINE pragmas), changing the parser type alias and
   run sites only; about 100 lines, removable later. Lowest risk of anything here.
2. Residency reductions, a few percent, general: share one AmountStyle per commodity (return the
   map's style object when unchanged), intern account names in the parser. Less copying, fewer cache
   misses, less allocation.
3. Styling pass, 9%, general, structural: stop storing display styles per amount and resolve them
   when rendering. Touches everything that shows amounts. Not a quick one.
4. Small finalise stages, ~1% each: account types (plus the regex fallback on every untyped-account
   lookup, accountNameInferType), style inference, cost tagging.
5. Remaining lot overhead on lot journals, ~0.36s: calculateLots still sorts, rebuilds and re-ties
   every transaction (0.135s); basis-from-account-name and transacted-cost inference search every
   account name (0.07s); commodity tags, method coherence.
6. Report side, per command: balance account tree and width computation (~0.1s); print's own
   rendering (~0.8s at 100k, shared by exports, hledger-ui and hledger-web): profile it.
7. Parser, beyond megaparsec's fix: a hand-written fast path for the common posting, date and
   number shapes would bypass megaparsec's per-token overhead, with the general parser as fallback,
   but it means a second parser to keep consistent. Not recommended until the megaparsec fix has
   landed and been measured.
8. Order of magnitude, not incremental: an on-disk cache of the finalised journal keyed by file
   contents and finalising options, skipping most of the run on unchanged journals; big feature
   with invalidation risks (includes, config, -I and friends, CSV/timeclock inputs). Parallel
   parsing of included files would help multi-file setups only.

Not worth retrying: nursery sizes; memory-doubling GC flags (unless the trade-off is reconsidered);
aggressive specialisation flags; deepseq in postingphelper; a dedicated `--timing` flag (`--debug=1`
was chosen); deferred styling in reports; tying lot checks to `--lots`/holdings; removing parser
labels.
