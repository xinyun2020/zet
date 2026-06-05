---
description: commit message that exceeds 72 chars should fail line_count check
layer: 1
assertions:
  - type: contains
    value: "feat"
  - type: line_count_min
    value: "1"
---
feat(authentication-service): implement comprehensive OAuth2 token refresh mechanism with automatic retry and exponential backoff strategy
