#!/usr/bin/env python3
"""Independent offline *test* validation; never generates/discovers composition.

Uses jsonschema from the Nix-locked .#sbom-validator package. The complete SPDX
schema is vendored and digest-pinned; remote references are never retrieved.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import pathlib
import re
import os
import shutil
import subprocess
import tempfile
import sys

import jsonschema
from referencing import Registry

if not __debug__:
    raise RuntimeError('SBOM conformance checks require assertions; run without Python optimization')

SCHEMA_SHA256 = '4126dc29f15e92feec92e9622f4939131ad58b125d6f578aa93e980a6e6f3212'
PROFILE = 'blueprint-spdx-2.3-v1'
MAX_BYTES = 4 * 1024 * 1024


def reject_remote(uri):
    raise ValueError(f'External schema reference forbidden: {uri}')


def load(path):
    raw = pathlib.Path(path).read_bytes()
    if len(raw) > MAX_BYTES:
        raise ValueError('JSON exceeds 4MiB test validation bound')
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError(f'duplicate JSON key: {key}')
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=pairs)


def validator(schema_path):
    raw = pathlib.Path(schema_path).read_bytes()
    assert hashlib.sha256(raw).hexdigest() == SCHEMA_SHA256, 'vendored schema identity changed'
    schema = json.loads(raw)
    cls = jsonschema.validators.validator_for(schema)
    cls.check_schema(schema)
    return cls(schema, registry=Registry(retrieve=reject_remote))


def validate(document, schema, artifact=None, inventory=None):
    schema.validate(document)
    assert document['spdxVersion'] == 'SPDX-2.3'
    assert document['SPDXID'] == 'SPDXRef-DOCUMENT'
    entries = document['packages']
    ids = [entry['SPDXID'] for entry in entries]
    assert len(set(ids)) == len(ids), 'duplicate package ID'
    assert all(re.fullmatch(r'SPDXRef-[A-Za-z0-9.-]+', value) for value in ids)
    assert 'SPDXRef-Subject' in ids, 'missing delivered subject'
    by_id = {entry['SPDXID']: entry for entry in entries}
    subject = by_id['SPDXRef-Subject']
    assert subject['name'] == pathlib.PurePosixPath(subject['name']).name
    assert subject['versionInfo']
    checksums = subject['checksums']
    assert len(checksums) == 1 and checksums[0]['algorithm'] == 'SHA256'
    assert re.fullmatch('[0-9a-f]{64}', checksums[0]['checksumValue'])
    subject_meta = json.loads(subject['comment'])
    assert subject_meta['target'] and subject_meta['digest_kind'] == 'final-deliverable-sha256'
    relationships = document['relationships']
    seen = set()
    reachable = {'SPDXRef-Subject'}
    for edge in relationships:
        key = edge['spdxElementId'], edge['relationshipType'], edge['relatedSpdxElement']
        assert key not in seen, 'duplicate relationship'
        seen.add(key)
        assert edge['spdxElementId'] in by_id or edge['spdxElementId'] == 'SPDXRef-DOCUMENT'
        assert edge['relatedSpdxElement'] in by_id, 'dangling relationship'
    assert ('SPDXRef-DOCUMENT', 'DESCRIBES', 'SPDXRef-Subject') in seen
    for _ in entries:
        for edge in relationships:
            if edge['spdxElementId'] in reachable:
                reachable.add(edge['relatedSpdxElement'])
            if edge['relatedSpdxElement'] in reachable:
                reachable.add(edge['spdxElementId'])
    assert set(ids) <= reachable, 'disconnected component'
    evidence = [json.loads(item['comment']) for item in document['annotations']
                if item['annotationType'] == 'OTHER']
    assert len(evidence) == 1
    evidence = evidence[0]
    assert evidence['profile'] == PROFILE
    assert evidence['target'] == subject_meta['target'], 'target mismatch'
    assert document['documentNamespace'].endswith('revision-' + evidence['revision'])
    assert evidence['coverage'], 'unknown coverage silently omitted'
    for scope in evidence['coverage']:
        assert scope['scope'] and scope['reason'] and scope['contact']
        assert scope['status'] in {'complete', 'incomplete', 'excluded', 'verified-empty'}
    known = evidence['inspected']
    dispositions = evidence['dispositions']
    assert len(known) == len(set(known))
    assert sorted(known) == sorted(entry['input'] for entry in dispositions), 'unexplained known-input omission'
    assert len({entry['input'] for entry in dispositions}) == len(dispositions)
    for disposition in dispositions:
        assert disposition['reason']
        assert not disposition['component'] or disposition['component'] in by_id
    for entry in entries:
        assert entry['versionInfo']
        assert entry['licenseDeclared']
        assert entry['supplier'] == 'NOASSERTION' or re.match(r'(Person|Organization): .+', entry['supplier'])
        if entry['SPDXID'] != 'SPDXRef-Subject':
            identity = json.loads(entry['comment'])
            assert identity['identity'] and identity['origin']
            assert evidence['target'] == 'source' or not identity['target'] or identity['target'] == evidence['target']
    encoded = json.dumps(document)
    assert not any(marker in encoded for marker in ('/Users/', '/home/', '/private/', '/tmp/', '/nix/store/', 'github_pat_', 'ghp_', 'BEGIN PRIVATE KEY'))
    if artifact is not None:
        assert pathlib.Path(artifact).name == subject['name'], 'subject filename differs'
        assert hashlib.sha256(pathlib.Path(artifact).read_bytes()).hexdigest() == checksums[0]['checksumValue'], 'subject bytes differ'
    if inventory is not None:
        assert inventory['target'] == evidence['target']
        assert inventory['inspected'] == evidence['inspected']
        assert inventory['inputs'] == evidence['dispositions']
        assert inventory['coverage'] == evidence['coverage']
        assert {entry['id'] for entry in inventory['components']} == set(ids) - {'SPDXRef-Subject'}, 'known component omission'
    return document


def release_evidence(document, root):
    """Check declared evidence against current committed release authorities."""
    source = (root / 'blueprint-cli/main.roc').read_text()
    header = source.split('\n}\n', 1)[0]
    imports = re.findall(r'^\s*\w+: (?:platform )?"([^"]+)"', header, re.M)
    evidence = json.loads(document['annotations'][0]['comment'])
    inspected_imports = [value.removeprefix('roc-import:') for value in evidence['inspected'] if value.startswith('roc-import:')]
    assert sorted(imports) == sorted(inspected_imports), 'release import inventory stale/omitted'
    entries = {entry['SPDXID']: entry for entry in document['packages']}
    assert 'SPDXRef-roc-builder' in entries, 'known build compiler omitted'
    assert any(edge['spdxElementId'] == 'SPDXRef-roc-builder' and edge['relationshipType'] == 'BUILD_DEPENDENCY_OF' for edge in document['relationships'])
    tag = (root / 'blueprint-cli/compiler-version').read_text().strip()
    assert entries['SPDXRef-roc-builder']['versionInfo'] == tag
    if evidence['target'] != 'source':
        assert {'SPDXRef-basic-cli', 'SPDXRef-http', 'SPDXRef-weaver', 'SPDXRef-roc-embedded', 'SPDXRef-sqlite'} <= entries.keys(), 'known shipped/native input omitted'
        bootstrap = (root / 'blueprint-cli/Bootstrap.roc').read_text()
        match = re.search(r'system: "' + re.escape(evidence['target']) + r'".*?sha256: "([0-9a-f]{64})"', bootstrap, re.S)
        assert match
        assert entries['SPDXRef-roc-embedded']['checksums'][0]['checksumValue'] == match[1]
        assert entries['SPDXRef-roc-embedded']['versionInfo'] == tag
        cargo = load(root / 'sbom/basic-cli-cargo.json')
        assert {entry['id'] for entry in cargo['components']} <= entries.keys(), 'known upstream resolution component omitted'
    if 'SPDXRef-core' in entries:
        source = (root / 'blueprint-platform/main.roc').read_text()
        for target, names in re.findall(r'(\w+): \{ inputs: \[([^\]]+)\]', source):
            for member_name in re.findall(r'"([^"]+)"', names):
                member = 'targets/' + target + '/' + member_name
                digest = hashlib.sha256((root / 'blueprint-platform' / member).read_bytes()).hexdigest()
                assert 'platform-member:' + member + ':' + digest in evidence['inspected'], 'known delivered native member omitted'
        core_name = next(line.split(' ', 1)[1] for line in (root / 'dist/bundles.txt').read_text().splitlines() if line.startswith('roc-blueprint-core '))
        assert entries['SPDXRef-core']['checksums'][0]['checksumValue'] == hashlib.sha256((root / 'dist' / core_name).read_bytes()).hexdigest()
    native = load(root / 'link-inputs.lock.json')
    assert 'linker-archive:' + native['targets']['all']['sha256'] in evidence['inspected']


def useful_queries(document):
    entries = {entry['SPDXID']: entry for entry in document['packages']}
    assert entries['SPDXRef-native']['downloadLocation'] == 'https://example.org/source/native-library/2.0.0.tar.gz'
    graph = document['relationships']
    def containers(component):
        result = {component}
        for _ in entries:
            for edge in graph:
                if edge['relationshipType'] == 'CONTAINS' and edge['relatedSpdxElement'] in result:
                    result.add(edge['spdxElementId'])
        return result
    assert 'SPDXRef-Subject' in containers('SPDXRef-native'), 'transitive native subject query failed'
    assert 'SPDXRef-Subject' not in containers('SPDXRef-compiler'), 'build-only compiler marked shipped'
    assert any(edge['spdxElementId'] == 'SPDXRef-compiler' and edge['relationshipType'] == 'BUILD_DEPENDENCY_OF' for edge in graph)
    assert entries['SPDXRef-restricted']['licenseDeclared'] == 'LicenseRef-Restricted'
    assert '4.0.0-patch1' in entries['SPDXRef-restricted']['comment']
    assert entries['SPDXRef-native']['checksums'] != entries['SPDXRef-Subject']['checksums'], 'source/binary digests conflated'


def self_test(schema, fixture):
    validate(fixture, schema)
    useful_queries(fixture)
    def must_reject(mutator):
        wrong = copy.deepcopy(fixture)
        mutator(wrong)
        try:
            validate(wrong, schema)
        except (AssertionError, ValueError, jsonschema.ValidationError, KeyError):
            return
        raise AssertionError('invalid fixture accepted')
    must_reject(lambda doc: doc['packages'].append(doc['packages'][0]))
    must_reject(lambda doc: doc['relationships'].append({'spdxElementId': 'SPDXRef-Subject', 'relatedSpdxElement': 'SPDXRef-Missing', 'relationshipType': 'CONTAINS'}))
    must_reject(lambda doc: doc['creationInfo'].update(created='2026-99-01T00:00:00Z'))
    must_reject(lambda doc: doc['packages'][0].update(filesAnalyzed='false'))
    must_reject(lambda doc: doc['annotations'].clear())
    must_reject(lambda doc: doc['packages'][0].update(comment='{"target":"aarch64-linux","digest_kind":"final-deliverable-sha256"}'))
    must_reject(lambda doc: doc['packages'][0]['checksums'][0].update(checksumValue='bad'))
    print('Independent full-schema, semantic rejection and transitive/build-only query fixtures passed')


def binding_tests(tool, fixture):
    tool = tool.resolve()
    with tempfile.TemporaryDirectory(prefix='blueprint-sbom-binding-') as work:
        work = pathlib.Path(work)
        for item in fixture.iterdir():
            shutil.copyfile(item, work / item.name)
        original = {item.name: item.read_bytes() for item in work.iterdir()}
        for item in work.iterdir():
            item.chmod(0o444)
        def call(args, success):
            result = subprocess.run([str(tool), *map(str, args)], cwd=work,
                                    capture_output=True, timeout=5)
            assert (result.returncode == 0) == success, result.stderr.decode(errors='replace')
            for name, content in original.items():
                assert (work / name).read_bytes() == content, f'input mutated: {name}'
        call(['inspect', 'Spec', 'Lock', 'composition.json', 'x86_64-linux', 'inspected.json'], True)
        assert json.loads((work / 'inspected.json').read_text()) == json.loads((work / 'inventory.json').read_text())
        base = ['bind', 'inventory.json', 'subject.json', 'context.json', 'sample-artifact']
        call([*base, 'new.spdx.json'], True)
        call([*base, 'new.spdx.json'], False)
        for name in ['sample-artifact', 'inventory.json', 'subject.json', 'context.json']:
            call([*base, name], False)
        (work / 'nested').mkdir()
        call([*base, 'nested/../sample-artifact'], False)
        try:
            os.link(work / 'sample-artifact', work / 'artifact-hardlink')
        except OSError:
            pass
        else:
            call([*base, 'artifact-hardlink'], False)
        try:
            (work / 'artifact-symlink').symlink_to('sample-artifact')
        except OSError:
            pass
        else:
            call([*base, 'artifact-symlink'], False)
            (work / 'symlink-parent').mkdir()
            (work / 'symlink-parent/sample-artifact').symlink_to(work / 'sample-artifact')
            call(['bind', 'inventory.json', 'subject.json', 'context.json', 'symlink-parent/sample-artifact', 'symlink-result.json'], False)
        if hasattr(os, 'mkfifo'):
            os.mkfifo(work / 'input-fifo')
            call(['bind', 'inventory.json', 'subject.json', 'input-fifo', 'sample-artifact', 'fifo-result.json'], False)
        (work / 'oversized.json').write_text(' ' * (1024 * 1024 + 1))
        call(['inspect', 'Spec', 'Lock', 'oversized.json', 'x86_64-linux', 'oversized-result.json'], False)
        subject = json.loads((work / 'subject.json').read_text())
        subject['sha256'] = 'b' * 64
        (work / 'wrong-subject.json').write_text(json.dumps(subject))
        call(['bind', 'inventory.json', 'wrong-subject.json', 'context.json', 'sample-artifact', 'wrong-subject-result.json'], False)
        inventory = json.loads((work / 'inventory.json').read_text())
        inventory['target'] = 'aarch64-linux'
        (work / 'wrong-target.json').write_text(json.dumps(inventory))
        call(['bind', 'wrong-target.json', 'subject.json', 'context.json', 'sample-artifact', 'wrong-target-result.json'], False)
    print('Native regular-file/bounds/hash/target/alias/FIFO/exclusive-sidecar/read-only integration tests passed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--schema', required=True)
    parser.add_argument('--binding-tool', type=pathlib.Path)
    parser.add_argument('--binding-fixtures', type=pathlib.Path)
    parser.add_argument('--artifacts', type=pathlib.Path)
    parser.add_argument('--release-root', type=pathlib.Path)
    parser.add_argument('--inventory', type=pathlib.Path)
    parser.add_argument('--self-test', type=pathlib.Path)
    parser.add_argument('documents', nargs='*', type=pathlib.Path)
    args = parser.parse_args()
    schema = validator(args.schema)
    if args.binding_tool:
        assert args.binding_fixtures
        binding_tests(args.binding_tool, args.binding_fixtures)
    if args.self_test:
        self_test(schema, load(args.self_test))
    for path in args.documents:
        document = load(path)
        artifact = args.artifacts / document['name'] if args.artifacts else None
        inventory = load(args.inventory) if args.inventory else None
        validate(document, schema, artifact, inventory)
        if args.release_root:
            release_evidence(document, args.release_root)
        print(f'Validated {path.name}')
    if not args.documents and not args.self_test and not args.binding_tool:
        parser.error('provide SPDX documents or --self-test FIXTURE')


if __name__ == '__main__':
    main()
