#!/usr/bin/env python3
"""Read connection data without executing shell code; never print secrets on error."""
import re
import sys

def parse(text):
    values = {}
    patterns = {'PROXY_PORT': r'[0-9]+', 'PROXY_AUTH': r'[a-z0-9]+:[0-9a-f]+', 'TUNNEL_ID': r'[A-Za-z0-9][A-Za-z0-9.-]{0,80}'}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith('#'): continue
        key, sep, value = line.partition('=')
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'": value = value[1:-1]
        if not sep or key not in patterns or key in values or not re.fullmatch(patterns[key], value):
            raise ValueError('Invalid connection configuration')
        values[key] = value
    if set(values) != set(patterns) or not 1 <= int(values['PROXY_PORT']) <= 65535:
        raise ValueError('Invalid connection configuration')
    return values

if __name__ == '__main__':
    try:
        with open(sys.argv[1]) as f: values = parse(f.read())
        for key in ('PROXY_PORT', 'PROXY_AUTH', 'TUNNEL_ID'): print(values[key])
    except (OSError, ValueError):
        print('Missing or invalid connection configuration', file=sys.stderr)
        sys.exit(2)
