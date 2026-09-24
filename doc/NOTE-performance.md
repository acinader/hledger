# Performance: findings and remaining ideas

Working notes from the 2026-09-23 optimisation session, kept so the measurements, lessons and
the ranked list of remaining ideas survive between sessions. How to benchmark and profile is in
BENCHMARKS.md; the per-version tables and the changelog draft are in _NOTE-performance-2026.md
(untracked); commit-level history is in git (`git log --grep=^perf:`).

Machine: MacBook Pro M5 Pro, GHC 9.14.1, 2026-09 Stackage nightly. Test journal:
examples/100ktxns-1kaccts.journal (8 MB, 500k lines: 100k one-line transactions with 200k
postings, 100k P price directives and 100k blank lines; 1k accounts, 26 commodities, a third of
the postings carry a unit cost, no assertions, assignments or comments). Numbers are wall-clock
seconds for `hledger balance` unless stated; allocation figures are from `+RTS -s` or `--debug=1`
and are deterministic, wall time varies by a few percent.

## Where the time goes now (2026-09-23, after the parser commit)

`hledger bal -f examples/100ktxns-1kaccts.journal --debug=1`, about 2.3s in total (2.2s in a
normal run):

| phase                                        | time  | allocation | notes                                                                |
|----------------------------------------------|-------|------------|----------------------------------------------------------------------|
| startup + read                               | 0.05s | 70 MB      |                                                                      |
| parse                                        | 1.28s | 10.5 GB    | 55% of the run; ~10% of it is the megaparsec regression (below)      |
| journalReverse                               | 0.09s | 12 MB      | a GC pause landing in this slot; the stage itself is trivial         |
| journalAddAccountTypes                       | 0.04s | 161 MB     |                                                                      |
| journalStyleAmounts                          | 0.22s | 197 MB     | rebuilds every posting to set display styles                         |
| journalTagCostsAndEquityAndMaybeInferCosts   | 0.02s | 136 MB     | skipped per transaction unless conversion accounts are involved      |
| journalBalanceTransactionsAndDeferAssertions | 0.10s | 415 MB     | pass 2 skipped (no assertions/assignments)                           |
| journalInferCommodityStyles                  | 0.05s | 61 MB      |                                                                      |
| journalInferMarketPricesFromTransactions     | 0.06s | 348 MB     | timer artifact: only valuation consumes this lazily-built list       |
| balance command                              | 0.37s | 1.1 GB     | account tree building, rendering                                     |
| GC, spread across all of the above           | 0.69s |            | 31% of the run; 12.6 GB allocated, 262 MB max residency, ~0.8 GB RSS |

Other commands on the same journal, quickbench best of 2: print 2.87s, register 15.3s (rendering
a 26-commodity running balance for 200k lines; real journals have few commodities), balance
2.38s. A lot-using variant (100k journal plus 1000 AAPL buy/sell pairs with `lots: fifo`,
generator tools/_100k-lots-journal.py) took 3.26s for balance before the parser commit, the extra
0.36s being the lot stages that still touch every transaction or account name.

Versions for context (balance, this machine): 1.25 2.6s, 1.40 4.0s, 1.52 4.1s, 1.99.4 5.7s,
main now 2.4s.

## What was done (5.65s -> 2.4s)

Oldest first, with the gain each gave on the 100k balance run:

- skip lot processing when the journal has no lot features: 5.65 -> 4.05s.
- build postings while parsing: peak residency 300 -> 254 MB, GC -0.15s.
- parse journal items by dispatching on the first character: 4.05 -> 3.30s, parse
  allocation 25.6 -> 17.1 GB.
- calculate source positions incrementally: -4% (a profile had claimed 8%).
- skip the balancer's running-balance pass when nothing needs it: 3.27 -> 3.10s.
- `--debug=1` prints each phase's time and allocation (the tool used for everything below).
- infer commodity styles in one pass, inserting only changed styles: 3.15 -> 2.95s.
- skip cost/equity tagging without conversion postings: stage 0.075 -> 0.02s.
- skip lot stages and lot balancing per transaction: lot journal 4.39 -> 3.26s.
- balancer: no style inference for exactly-zero sums, no rebuilds when nothing to infer,
  no-op cost conversions: balancing 0.20s/945MB -> 0.17s/690MB.
- multiplyQuantities instead of Decimal's (*): balancing -> 0.12s/415MB; also speeds
  -B, valuation and lot arithmetic.
- parser: check the next character before optional syntax instead of trying it and
  backtracking: parse 1.71 -> 1.28s and 17.1 -> 10.5 GB; print 3.35 -> 2.87s, register
  17.0 -> 15.3s, balance 3.02 -> 2.38s.
- stats: hash sets for the unique counts, no sort: the command's own work 0.70 -> 0.33s.
- journal filters return the journal unchanged for a null query (ledgerFromJournal was
  rebuilding it twice): stats' own work 0.33 -> 0.18s; stats run 2.5 -> 2.0s.

Pending upstream: mrkkrp/megaparsec#612 (filed 2026-09-23), worth ~10% of every command when a
fixed release can be required; the patch (INLINE pragmas on the Stream instances) is on the fork
branch inline-stream-instances, PR to be opened only if the maintainer asks.

## Performance across releases

Here is the performance of some notable releases on this machine
(`quickbench -w hledger-1.25,hledger-1.40,hledger-1.52,hledger-1.99.4,hledger` on 2026-09-23,
showing seconds, for the 100k-transaction journal):

| command    |  1.25 |  1.40 |  1.52 | 1.99.4 | latest |  since 1.25 |  since 1.52 | since 1.99.4 |
|------------|------:|------:|------:|-------:|-------:|------------:|------------:|-------------:|
| stats      |  2.70 |  3.95 |  4.29 |   5.96 |   2.00 |  35% (1.4x) | 114% (2.1x) |  198% (3.0x) |
| balance    |  2.68 |  3.92 |  4.06 |   5.80 |   2.15 |  25% (1.2x) |  89% (1.9x) |  170% (2.7x) |
| print      |  3.24 |  4.27 |  4.42 |   6.32 |   2.84 |  14% (1.1x) |  56% (1.6x) |  123% (2.2x) |
| register   | 71.99 | 30.22 | 20.73 |  19.02 |  14.17 | 408% (5.1x) |  46% (1.5x) |   34% (1.3x) |
| **txns/s** |   37k |   25k | 23k * |  17k * |    52k |  41% (1.4x) | 126% (2.3x) |  206% (3.1x) |

(\* adjusted real values, not the too-high value shown by hledger 1.51 through 1.99.4)

Summary: latest hledger is the fastest-ever hledger:
3x faster than the last preview release, 2x faster than the
current hledger 1 release, and 1.2x faster than hledger 1.25.

## Findings worth remembering

Measurement:

- The `--debug=1` phase timer deep-forces each stage's result, then subtracts the cost of a second
  traversal, so no-op stages read ~0 (they read 0.08-0.12s before that fix). It charges work that a
  normal run leaves unevaluated (inferred market prices) and GC pauses to whichever stage is running
  (journalReverse). Its total matches a normal run within 3%; it costs nothing when off.
- Profiling inflates tiny hot functions (isWideChar, source positions: claimed 8%, real 4%) and
  shifts shares; use it to find candidates, use `--debug=1` and quickbench to judge them. Under
  CPS parsers the profile tree is misleading: the percentages beneath a parser mostly belong to its
  continuation (everything parsed after it), so read the individual columns, or measure directly.
- Splitting the journal by line kind measures a parser's share directly: `grep -v '^P '` gave a
  journal without price directives and `grep '^P '` one with only them, which showed the price
  directives costing 0.45s of the 1.7s parse.
- `hledger stats` measures its elapsed time at the end of the command again; from
  1.51 to 1.99.4 it measured before computing the stats, so its elapsed and txns/s covered only
  reading the journal and were ~0.5s short of `time` on the 100k journal. Per-version txns/s
  figures from those versions are not comparable with 1.25's or with current ones.
- Allocation is the reliable signal: it is deterministic and tracks GC cost. Wall time on this
  machine is noisy at the 3-5% level (one quickbench run "showed" a print slowdown that vanished on
  rerun).
- The lot journal is needed for lot-stage work; the plain 100k journal flatters those stages.
  Real journals have assertions, comments, multi-line transactions and few commodities, so run
  `--debug=1` on a real journal before trusting the ranking below.

GC and memory:

- GC time (0.7s) is copying the live journal, not collection overhead: nursery sizes from 4 MB
  (default) to 128 MB change nothing except RSS (tested 2026-09-23: -A16m 2.71s, -A64m 2.93s,
  -A128m 2.81s vs 2.65s). Don't retest.
- Memory-for-time flags: `-xn` (non-moving GC) -10% time for 0.8 -> 1.3 GB RSS; `-xn -F3` -13% for
  +24% RSS; `-F4` -6% for +32% RSS. Judged not attractive for all users.
- Compile flags: package-wide `-fexpose-all-unfoldings -fspecialise-aggressively` gave only -4% for
  a much longer compile. Not adopted. `-O2` alone was not measured separately.
- The journal is ~2.6 KB per transaction in memory (262 MB for 100k). Residency is the remaining
  GC lever: every amount carries its own AmountStyle copy (the styling pass allocates
  `news{asprecision=..}` even when unchanged), account name Texts are not shared between
  postings, and poriginal/ptransaction add pointers per posting.

Parsing:

- Megaparsec >= 9.3.0 (PR 495, ShareInput wrappers) made the plain Text instance delegate through
  a newtype; hledger's parser became ~15% slower and 33% more allocating. Not the wide-char column
  counting added in 9.7.0, which was measured slightly faster than 9.6.1. Bisected by rebuilding
  hledger 1.25 on GHC 9.14 with pinned megaparsec versions (recipe in the performance memory note;
  four small mtl/aeson patches). Current main with megaparsec 9.2.2: balance 2.81 vs 3.13s.
- A failing parse attempt is expensive: megaparsec builds an error value, with sets of expected
  items and hints, for every failure, even one immediately backtracked by `try` or `optional`.
  Dispatching journal items on their first character removed most of these and was the single
  biggest win; the parser commit removed the rest. All optional syntax (signs, commodity symbols,
  exponents, costs, lot annotations, comments, status marks, codes, secondary dates, assertions,
  times in price directives) is now checked by peeking at the next character or two with
  Hledger.Utils.Parse's peekChar, peekChars2 and peekAfterSpaces, and parsed only when present;
  manyWhile ends the posting, comment-line and account-name-part loops the same way. Before that,
  a typical transaction plus price line failed dozens of attempts, and each one-line price
  directive allocated 47 KB (the 100k of them: 0.45s/4.7GB, now 0.30s/2.2GB).
- Labels are free: stubbing out every `label`/`<?>` in Common.hs and JournalReader.hs changed
  neither time nor allocation. Don't retest.
- What remains in the parser is megaparsec's own machinery (composition closures, pure/return,
  getParserState, the StateT layer) and Text.Megaparsec.Stream.takeWhile_ at 14% of all
  allocation, which is the Stream instance regression above. Little hledger-side waste is left.
- `postingphelper` building postings strictly during parsing helped; a deepseq there was slower for
  balance because it forces tags and comments that balance never reads.

Finalising:

- The lot stages must run for any journal with lot features even for non-lot reports, because they
  add gain postings and basis-derived amounts that ordinary reports show; `-I` is the opt-out. So lot
  work is gated per transaction (transactionHasLotfulAmounts), not per command.
- journalInferCommodityStyles can't be skipped after the first pass: forecast transactions, auto
  postings and balancing add amounts later.
- Deferring amount styling to report time was rejected: every report would need to do it and get it
  right; unreliable and a lot of code.
- Decimal's (*) goes via Rational, 10^255 and normalizeDecimal (~6 KB and >1 us per multiplication);
  its (/) does the same via fromRational (divideAmount, only on rare paths so far). Upstream
  (Data.Decimal 0.5.2) could be told.

Reports:

- Balance report: accountFromPostings (HashMap alter, PeriodData insert, maPlus per posting) is most
  of its 0.37s; rendering calls showMixedAmountB three times per account (column width computed
  twice plus the render). No big cheap win.
- Register's cost is output volume (running balance rendering), not a bug.
- Journal filtering with a null query used to rebuild every transaction; ledgerFromJournal did it
  twice. Now short-circuited. Other report paths that filter with possibly-empty
  queries may have similar no-op passes worth checking with `--debug=1`.

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

## Tooling notes

- `stack --profile` on GHC 9.14.1 panics compiling tls; use `stack --stack-yaml stack-prof.yaml
  --work-dir .stack-prof install --library-profiling --executable-profiling --local-bin-path bin
  hledger` (see BENCHMARKS.md). Profiles from this session are archived under doc/profs/202609*.
- For `+RTS` experiments, build in a scratch work dir with `--ghc-options=-rtsopts`, eg
  `stack --work-dir .stack-rtsopts build --ghc-options=-rtsopts hledger` (the shipped binary
  allows `+RTS -s` but not `-A`/`-F`/`-xn`); `stack --work-dir .stack-rtsopts path
  --local-install-root` gives its bin directory.
- `just functest` rebuilds with -Werror, so don't `stack build` in parallel with it.
- quickbench needs the binaries on PATH; `hledger-1.99.4` on PATH is the pre-optimisation reference.
