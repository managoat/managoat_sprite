`openapi.json` is generated response-contract data for the implemented
Manasprites host routes. Source: Fountain's `sdk/contract/contract.json` at
`01ed20a38d39be9c72fcb2828047f1cce7a6bb55` (BinaryBourbon/fountain).

Regenerate from the repository root:

```sh
python3 scripts/fountain-openapi.py /path/to/fountain/sdk/contract/contract.json
```

The independent deployed runner validates actual responses against its own
pinned contract, and separately compares the advertised schema. Passing the
advertisement check alone does not establish implemented behavior. See
`docs/fountain-api.md` for scope and qualification.
