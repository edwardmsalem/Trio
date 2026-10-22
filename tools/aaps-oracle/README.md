# AAPS dosing oracle

A Python reference implementation of the AndroidAPS 3.4.2.6 OpenAPS SMB
`DetermineBasalSMB.determine_basal`, as built in Eddie's AAPS fork at release
`42bb385ff4`. It is the oracle for proving that a ported Trio engine gives the
same doses AAPS gives for the same inputs.

It covers the dosing path line by line, including:

- Dynamic ISF (`variable_sens`) and the plain profile ISF path with autosens.
- The fork's ISF tiers, both "on top of dynamic" (`variable_sens * tier`, the
  mode the fork ships) and the older "clamped to autosens" form.
- The carb ratio tier (`carb_tier`).
- Dosing sensitivity (`future_sens`, the TDD log formula logged by AAPS as
  "Dosing sensitivity: N using eventual BG") that sizes `insulinReq`.
- Predictions (IOB, COB, aCOB, UAM, ZT), the low guards, SMB sizing and temp
  basal selection.

Not ported: `adv_target_adjustments` raises `NotImplementedError`. It was off in
every logged run.

## Files

| File | What it does |
|---|---|
| `dbsmb.py` | The rebuilt `determine_basal`. Pure functions, no I/O. |
| `extract.py` | Walks a folder of AAPS logs and pulls every `Inserted APSResult` line (glucose status, current temp, IOB array, profile, autosens, meal data and the logged result) into one JSONL record per loop run. Deduplicates by timestamp. |
| `replay.py` | Feeds each record back through `dbsmb.py` and checks eventual BG, insulinReq, SMB units and temp rate against what AAPS logged. Also computes two counterfactuals per run: tiers off, and tiers in the clamped form. |

## Running it

Python 3 standard library only. No dependencies.

```
# 1. Pull loop runs out of AAPS logs (AndroidAPS.log and rotated files, any depth)
python3 -I extract.py <folder of AAPS logs> aps.jsonl

# 2. Replay them and compare with the logged decisions
python3 -I replay.py aps.jsonl rows.json
```

`replay.py` prints the tier bands it saw in the logs, the tier table it used,
then `checked N mismatch M`. `rows.json` holds one row per run with the
replayed result (`A`, tiers on top of dynamic), the counterfactuals (`B` tiers
off, `C` clamped tiers) and the logged values (`log`).

A run matches when eventual BG is equal, insulinReq is within 0.01 U, SMB units
are within 0.001 U and the temp rate is within 0.01 U/hr.

## Result on Eddie's logs

Against 1,020 loop runs from September and October 2026, 1,019 match exactly.
The one miss is a 1 mg/dL eventual BG rounding difference (70 vs 71) at BG 71
with no dose either way, so every dose matched.

The logs and extracted data are personal health data and are not in this
repository. They live in a private folder outside git on the Studio.

## Using it as the oracle for a Trio port

Feed the same extracted inputs to the Trio engine under test and diff its
eventual BG, insulinReq, SMB units and temp rate against `A` in `rows.json`
(or against `dbsmb.determine_basal` directly). A port is equivalent when it
reproduces the same match count.

## The Swift port in Trio

Trio's Swift engine has the same calculation as an "AAPS dosing" mode
(`Trio/Sources/APS/OpenAPSSwift/AAPS/`). Its equivalence test,
`TrioTests/OpenAPSSwiftTests/AAPS/AAPSEquivalenceTests.swift`, reads the same
`aps.jsonl` (and the raw `logs/` folder for the Dynamic ISF check) and skips
when the folder is not given:

```
TEST_RUNNER_AAPS_ORACLE_DIR=<private folder> xcodebuild test-without-building \
  -workspace Trio.xcworkspace -scheme "Trio Tests" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath <dd>
```

On the 1,020 runs the Swift port matches AAPS on every field it checks,
including the eventual BG at BG 71 that this Python oracle misses by 1.
