---
description: commit body does not leak ticket IDs (belong in PR title only)
layer: 1
assertions:
  - type: not_regex
    value: "(JIRA|IAP|TPOT)-[0-9]+"
  - type: not_contains
    value: "fixes #"
---
refactor(api): simplify response serialization

Remove nested wrapper objects that added complexity without value.
Response shape is now flat for all /v2 endpoints.
