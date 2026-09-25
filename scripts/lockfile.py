"""Read a Blueprint.lock (S-expression Lock) in the test scripts.

`load(text)` returns the Lock as plain Python data; `nix_graph(text)` returns
the Nix provider's native lock graph from its hint, as json.loads would.
"""
import re

_TOKEN = re.compile(r'\s+|;[^\n]*|\(|\)|"(?:[^"\\]|\\.)*"|[^\s()";]+')
_ESCAPES = {'n': '\n', 't': '\t', 'r': '\r', '"': '"', '\\': '\\', '$': '$'}


def _tokens(text):
    pos = 0
    while pos < len(text):
        match = _TOKEN.match(text, pos)
        if not match:
            raise ValueError(f"bad lock syntax at {pos}")
        token = match.group(0)
        pos = match.end()
        if not token.isspace() and not token.startswith(';'):
            yield token


def _parse(tokens):
    token = next(tokens)
    if token == '(':
        items = []
        while True:
            try:
                items.append(_parse(tokens))
            except _Close:
                return items
    if token == ')':
        raise _Close
    if token.startswith('"'):
        return re.sub(r'\\(.)', lambda m: _ESCAPES.get(m.group(1), m.group(1)), token[1:-1])
    if re.fullmatch(r'-?\d+', token):
        return int(token)
    return {'true': True, 'false': False}.get(token, token)


class _Close(Exception):
    pass


def _record(items):
    return {name: value for name, value in items}


def _value(tagged):
    tag, payload = tagged
    if tag == 'Attrs':
        return {_record(f)['name']: _value(_record(f)['value']) for f in payload}
    if tag == 'List':
        return [_value(item) for item in payload]
    return payload  # Str, Int, Bool


def load(text):
    lock = _record(_parse(_tokens(text)))
    lock['format'] = _record(lock['format'])
    lock['sources'] = [_record(s) for s in lock.get('sources', [])]
    lock['hints'] = [_record(h) for h in lock.get('hints', [])]
    return lock


def nix_graph(text):
    hint = next(h for h in load(text)['hints'] if h['provider'] == 'nix')
    return _value(hint['value'])['graph']
