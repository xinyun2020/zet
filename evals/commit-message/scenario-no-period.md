---
description: commit message does not end with period
layer: 1
assertions:
  - type: not_regex
    value: "\\.$"
---
fix(parser): handle empty input gracefully
