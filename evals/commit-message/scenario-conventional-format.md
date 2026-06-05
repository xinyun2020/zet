---
description: commit message follows conventional format
layer: 1
assertions:
  - type: regex
    value: "^(feat|fix|test|refactor|chore|docs|perf|style|ci|build)"
  - type: not_contains
    value: "JIRA-123"
  - type: line_count_max
    value: "5"
---
feat(auth): add OAuth2 token refresh on expiry
