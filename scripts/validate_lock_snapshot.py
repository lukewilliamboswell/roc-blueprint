#!/usr/bin/env python3
"""Independent offline schema/profile and real Roc consumer conformance tests."""
from __future__ import annotations
import argparse
from numbers import Number
import json
from pathlib import Path
import re
import subprocess
import tempfile
import jsonschema
from referencing import Registry

MAX_BYTES = 8 * 1024 * 1024

class NumberLexeme(Number):
    """Keep arbitrary metadata numbers without float/Decimal/int conversion limits."""
    def __init__(self, text):
        self.text = text

def integer(text):
    # Known format/size fields fit at most twenty decimal digits. Bigger native
    # metadata integers need no arithmetic and stay lossless, just like Roc.
    return int(text) if len(text.lstrip('-')) <= 20 else NumberLexeme(text)

def reject_remote(uri):
    raise ValueError(f'remote schema retrieval forbidden: {uri}')

def pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise ValueError('duplicate JSON key')
        result[key] = value
    return result

def load(raw):
    if len(raw) > MAX_BYTES:
        raise ValueError('report exceeds 8 MiB')
    result = json.loads(raw, object_pairs_hook=pairs, parse_float=NumberLexeme, parse_int=integer,
                        parse_constant=lambda _: (_ for _ in ()).throw(ValueError('non-JSON number')))
    def bounded(value, depth=0):
        if depth > 128:
            raise ValueError('report exceeds 128 levels')
        if isinstance(value, (dict, list)):
            if len(value) > 4096:
                raise ValueError('collection exceeds 4096 entries')
            for child in value.values() if isinstance(value, dict) else value:
                bounded(child, depth + 1)
    bounded(result)
    return result

def validate(raw, validator):
    data = load(raw)
    validator.validate(data)
    # JSON Schema cannot express cross-field equality or lexical integer policy.
    if type(data['format']) is not int:
        raise ValueError('format must use an integer JSON lexeme')
    seen = set()
    for key, source in data['sources'].items():
        if key != source['name']:
            raise ValueError('source key/name mismatch')
        if source['provider'] == 'file':
            identity = 'sha256:' + source['flatSha256']
            if source['identity'] != identity or source['digest'] != identity:
                raise ValueError('flat digest/identity mismatch')
    for entry in data['fetched']:
        key = entry['name'], entry['system']
        if key in seen:
            raise ValueError('duplicate fetched program/system')
        seen.add(key)
        if type(entry['size']) is not int:
            raise ValueError('size must use an integer JSON lexeme')
        if entry['identity'] != 'sha256:' + entry['sha256']:
            raise ValueError('program digest/identity mismatch')
    return data

def self_test(consumer, validator):
    raw = subprocess.run([consumer], check=True, capture_output=True).stdout
    good = validate(raw, validator)
    cases = [(raw, True)]
    cases += [(raw.replace(b'"format":1', b'"format":2'), False),
              (raw.replace(b'"format":1', b'"format":1.0'), False),
              (raw.replace(b'"format":1', b'"format":1,"format":1'), False),
              (raw + b'{}', False),
              (raw.replace(b'18446744073709551615', b'18446744073709551616'), False),
              (raw.replace(b'"nix":{', b'"different":{', 1), False),
              (raw.replace(b'"flatSha256":null', b'"flatSha256":"' + b'a'*64 + b'"'), False),
              (raw.replace(b'"published"', b'"future-state"').replace(b'"tree"', b'"future-kind"'), True),
              (raw.replace(b'"format":1', b'"additional":{"nested":[null,2.5]},"format":1'), True)]
    # No float conversion is involved in these independent lexical mutations.
    one = re.search(rb'"fetched":\[(.*)\]}\s*$', raw).group(1)
    cases.append((raw.replace(b'"fetched":[' + one + b']', b'"fetched":[' + one + b',' + one + b']'), False))
    cases.append((raw.replace(b'340282366920938463463374607431768211455', b'9' * 10000), True))
    cases.append((raw.replace(b'-1.2300e+99999', b'1e+' + b'9' * 10000), True))
    cases.append((raw.replace(b'"future":', b'"future":null,"\\u0066uture":'), False))
    file_source = {'name': 'archive', 'provider': 'file', 'ref': 'https://example.test/source.tar.gz',
                   'rev': '', 'digest': 'sha256:' + 'b'*64, 'identity': 'sha256:' + 'b'*64,
                   'digestKind': 'file', 'flatSha256': 'b'*64, 'metadata': {}}
    file_doc = {'format': 1, 'sources': {'archive': file_source}, 'fetched': []}
    file_raw = json.dumps(file_doc).encode()
    cases += [(file_raw, True),
              (file_raw.replace(b'"rev": ""', b'"rev": "wrong"'), False),
              (file_raw.replace(b'"flatSha256": "' + b'b'*64 + b'"', b'"flatSha256": null'), False),
              (file_raw.replace(b'"identity": "sha256:' + b'b'*64, b'"identity": "sha256:' + b'a'*64), False)]
    with tempfile.TemporaryDirectory(prefix='lock-snapshot-conformance-') as directory:
        path = Path(directory) / 'report.json'
        for index, (candidate, expected) in enumerate(cases):
            try:
                validate(candidate, validator)
                valid = True
            except (ValueError, jsonschema.ValidationError, KeyError, TypeError):
                valid = False
            if valid != expected:
                raise AssertionError(f'independent profile case {index}: expected {expected}, got {valid}')
            path.write_bytes(candidate)
            result = subprocess.run([consumer, str(path)], capture_output=True)
            if (result.returncode == 0) != expected:
                raise AssertionError(f'Roc consumer case {index}: {result.returncode}, {result.stderr!r}')
            if expected:
                validate(result.stdout, validator)
                for lexeme in [b'-1.2300e+99999', b'340282366920938463463374607431768211455', b'9' * 10000]:
                    if lexeme in candidate and lexeme not in result.stdout:
                        raise AssertionError('metadata numeric lexemes lost precision')
    print(f'PASS {len(cases)} independent schema/profile/native-Roc cases; exact null/numeric metadata retained')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--schema', required=True)
    parser.add_argument('--consumer')
    parser.add_argument('reports', nargs='*')
    args = parser.parse_args()
    schema = json.loads(Path(args.schema).read_text())
    cls = jsonschema.validators.validator_for(schema)
    cls.check_schema(schema)
    validator = cls(schema, registry=Registry(retrieve=reject_remote))
    if args.consumer:
        self_test(str(Path(args.consumer).resolve()), validator)
    for report in args.reports:
        validate(Path(report).read_bytes(), validator)
        print(f'PASS lock snapshot schema/profile: {report}')

if __name__ == '__main__':
    main()
