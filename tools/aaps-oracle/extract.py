"""Extract every logged APSResult (inputs + result) from AAPS log files into JSONL.

Usage: python3 extract.py <folder of AAPS logs> <out.jsonl>
"""
import json, sys, os, re


def grab(line, key):
    i = line.find(key + '=')
    if i < 0:
        return None
    j = i + len(key) + 1
    if line[j] not in '{[':
        return None
    open_c = line[j]; close_c = '}' if open_c == '{' else ']'
    depth = 0; k = j; in_s = False; esc = False
    while k < len(line):
        c = line[k]
        if in_s:
            if esc: esc = False
            elif c == '\\': esc = True
            elif c == '"': in_s = False
        else:
            if c == '"': in_s = True
            elif c in '{[': depth += 1
            elif c in '}]':
                depth -= 1
                if depth == 0:
                    return json.loads(line[j:k + 1])
        k += 1
    return None


def main(root, outp):
    seen = set(); n = 0
    with open(outp, 'w') as out:
        for dp, dn, fn in os.walk(root):
            for f in fn:
                path = os.path.join(dp, f)
                mba = None; flat = None; dyn = None
                try:
                    fh = open(path, errors='replace')
                except Exception:
                    continue
                for line in fh:
                    if 'MicroBolusAllowed:' in line:
                        mba = line.strip().endswith('true')
                    elif 'flatBGsDetected:' in line:
                        flat = line.strip().endswith('true')
                    elif 'DynIsfMode:' in line:
                        dyn = line.strip().endswith('true')
                    elif 'Inserted APSResult APSResult(' in line:
                        m = re.search(r'APSResult\(id=(\d+).*?, timestamp=(\d+),', line)
                        if not m:
                            continue
                        ts = int(m.group(2))
                        if ts in seen:
                            continue
                        rec = {k: grab(line, k) for k in ['glucoseStatusJson', 'currentTempJson', 'iobDataJson', 'profileJson', 'autosensDataJson', 'mealDataJson', 'resultJson']}
                        if not rec['resultJson'] or not rec['iobDataJson']:
                            continue
                        seen.add(ts)
                        rec['ts'] = ts; rec['mba'] = mba; rec['flat'] = flat; rec['dyn'] = dyn; rec['file'] = path
                        out.write(json.dumps(rec) + '\n'); n += 1
    print(n, 'records')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit('usage: extract.py <aaps_log_dir> <out.jsonl>')
    main(sys.argv[1], sys.argv[2])
