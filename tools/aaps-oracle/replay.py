"""Replay extracted AAPS loop runs through dbsmb.py and compare with what AAPS logged.

Usage: python3 replay.py <aps.jsonl> <rows_out.json>
"""
import json, sys, os, re, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dbsmb

if len(sys.argv) != 3:
    sys.exit('usage: replay.py <aps.jsonl> <rows_out.json>')
IN_PATH, OUT_PATH = sys.argv[1], sys.argv[2]

recs = [json.loads(l) for l in open(IN_PATH)]
recs.sort(key=lambda r: r['ts'])

# Default tier table. Any band whose multiplier appears in the logged consoleLog
# ('ISF tier: BG x mult') overrides the default for that band.
# tier multipliers seen in the log, by band
band_m = collections.defaultdict(set)
for r in recs:
    for c in r['resultJson'].get('consoleLog', []):
        m = re.match(r'ISF tier: BG ([\d.]+) x([\d.]+)', c)
        if m:
            g = float(m.group(1)); band_m[[b for b in [(0, 70), (70, 140), (140, 200), (200, 250), (250, 400)] if b[0] <= g < b[1]][0]].add(float(m.group(2)))
print('bands seen:', dict(band_m))
tiers = [(0, 70, 1.2), (70, 140, 1.0), (140, 200, 0.9), (200, 250, 0.8), (250, 400, 0.7)]
for (lo, hi), ms in band_m.items():
    tiers = [(a, b, (list(ms)[0] if (a, b) == (lo, hi) else m)) for a, b, m in tiers]
print('tiers used:', tiers)


class D(dict):
    def __missing__(self, k):
        if k in ('iob', 'activity', 'lastBolusTime', 'carbs', 'mealCOB', 'slopeFromMaxDeviation', 'slopeFromMinDeviation', 'lastCarbTime', 'delta', 'shortAvgDelta', 'longAvgDelta', 'noise', 'duration', 'rate', 'ratio'):
            return 0.0
        if k == 'iobWithZeroTemp':
            return D()
        raise KeyError(k)


def dd(x):
    if isinstance(x, dict):
        return D({k: dd(v) for k, v in x.items()})
    if isinstance(x, list):
        return [dd(v) for v in x]
    return x


def run(r, **kw):
    p = r['profileJson']
    return dbsmb.determine_basal(dd(r['glucoseStatusJson']), dd(r['currentTempJson']), dd(r['iobDataJson']), dd(p), dd(r['autosensDataJson']),
                                 dd(r['mealDataJson']), r['mba'], r['ts'], r['flat'], r['dyn'], tiers=tiers, **kw)

errs = collections.Counter()
rows = []; mism = 0; checked = 0
for r in recs:
    res = r['resultJson']
    tier_on = any(c.startswith('ISF tier') for c in res.get('consoleLog', []))
    on_dyn = any('on top of dynamic' in c for c in res.get('consoleLog', []))
    try:
        a = run(r, tiersEnabled=True, onDynamic=True)
    except Exception as e:
        errs[repr(e)[:80]] += 1
        continue
    if 'error' in a:
        continue
    b = run(r, tiersEnabled=False)
    c = run(r, tiersEnabled=True, onDynamic=False)
    checked += 1
    ok = (a['eventualBG'] == res.get('eventualBG')) and abs(a.get('insulinReq', 0) - (res.get('insulinReq') or 0)) < 0.011 \
        and abs(a.get('units', 0) - (res.get('units') or 0)) < 0.001
    lr = res.get('rate'); ld = res.get('duration')
    if a.get('rate') is not None and lr is not None and abs(a['rate'] - lr) > 0.011:
        ok = False
    if not ok:
        mism += 1
    rows.append(dict(ts=r['ts'], bg=r['glucoseStatusJson']['glucose'], tier_on=tier_on, on_dyn=on_dyn, ok=ok,
                     iob=r['iobDataJson'][0]['iob'], m=a['tier_m'], var_sens=r['profileJson']['variable_sens'],
                     sens=a['sens'], fs=a['future_sens'], A=a, B=b, C=c, log=dict(eBG=res.get('eventualBG'), iR=res.get('insulinReq'),
                     units=res.get('units'), rate=lr, dur=ld, reason=res.get('reason', '')[:300])))
print('checked', checked, 'mismatch', mism, errs)
json.dump(rows, open(OUT_PATH, 'w'))
