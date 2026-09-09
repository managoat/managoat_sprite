#!/usr/bin/env python3
"""Project the pinned Fountain wire shapes onto the implemented host API routes.
No server implementation or runtime dependency is imported. Review generated
schema changes alongside the API and its externally pinned conformance run.
"""
import json
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1])
contract = json.loads(source.read_text())
collections = ('agents', 'environments', 'vaults')
selected = {}
for key, op in contract['operations'].items():
    method, path = key.split(' ')
    route = re.sub(r'\{[^}]+\}', '{}', path)
    allowed = set()
    if route in ('/health', '/health/ready', '/api/auth/me', '/api/catalog', '/api/events/stream'):
        allowed = {'GET'}
    elif route in ('/api/conversations', '/api/auth/api-keys'):
        allowed = {'GET', 'POST'}
    elif route in ('/api/conversations/{}', '/api/auth/api-keys/{}'):
        allowed = {'GET', 'DELETE'} if 'conversations' in route else {'DELETE'}
    elif route in ('/api/conversations/{}/prompts', '/api/conversations/{}/interrupt', '/api/conversations/{}/terminate', '/api/conversations/{}/requests/{}'):
        allowed = {'POST'}
    elif route in ('/api/conversations/{}/turns', '/api/conversations/{}/events', '/api/conversations/{}/stream', '/api/sandboxes/{}', '/api/sandboxes/{}/file'):
        allowed = {'GET'}
    elif any(route == '/api/' + c for c in collections):
        allowed = {'GET', 'POST'}
    elif any(route == '/api/' + c + '/{}' for c in collections):
        allowed = {'GET', 'PUT', 'DELETE'}
    if method in allowed:
        selected[key] = op
schemas = {}
def convert(node):
    if isinstance(node, list):
        return [convert(v) for v in node]
    if not isinstance(node, dict):
        return node
    if isinstance(node.get('ref'), str):
        name = node['ref']
        if name not in schemas:
            schemas[name] = None
            schemas[name] = convert(contract['schemas'][name])
        return {'$ref': '#/components/schemas/' + name}
    result = {k: ({name: convert(prop) for name, prop in v.items()} if k == 'properties' else convert(v)) for k, v in node.items() if k not in ('required', 'has_default')}
    if 'properties' in node:
        result['required'] = [k for k, v in node['properties'].items() if v.get('required')]
    return result
spec = {'openapi': '3.0.3', 'info': {'title': 'Manasprites Fountain host API', 'version': '0.1.0',
        'description': 'Fountain-compatible response vocabulary; supports Sprites, Claude and Codex, ephemeral sandboxes, and operator-provisioned accounts. Unsupported request features return 422.'},
        'paths': {}, 'components': {'schemas': schemas, 'securitySchemes': {'bearer': {'type': 'http', 'scheme': 'bearer'}}}, 'security': [{'bearer': []}]}
for key, op in selected.items():
    method, path = key.split(' ')
    value = {'responses': {status: {'description': 'Response', 'content': {mime: {'schema': convert(schema)} for mime, schema in content.items()}} for status, content in op['responses'].items()}}
    parameters = re.findall(r'\{([^}]+)\}', path)
    if parameters:
        value['parameters'] = [{'name': name, 'in': 'path', 'required': True, 'schema': {'type': 'string'}} for name in parameters]
    # Request schemas are declared separately by the adapter's validation; this
    # artifact pins compatible responses, including optional SDK vocabulary.
    spec['paths'].setdefault(path, {})[method.lower()] = value
out = pathlib.Path(__file__).resolve().parents[1] / 'desktop/priv/fountain/openapi.json'
out.write_text(json.dumps(spec, indent=2, sort_keys=True) + '\n')
