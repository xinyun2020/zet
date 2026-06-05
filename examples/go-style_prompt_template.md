---
type: rule
description: Enforce idiomatic Go patterns when editing Go files.
paths: "**/*.go"
---

# Go Style

When editing Go files, follow these conventions:

## Naming

- Exported functions: PascalCase, starts with a verb (`GetUser`, `ParseConfig`)
- Unexported: camelCase
- Interfaces: noun or -er suffix (`Reader`, `Closer`, `UserStore`)
- Avoid `Get` prefix on unexported methods — just use the noun (`user()` not `getUser()`)

## Error Handling

- Always handle errors explicitly — never `_ = doThing()`
- Return errors, don't panic (except truly unrecoverable states)
- Wrap errors with context: `fmt.Errorf("parsing config: %w", err)`
- Check errors immediately after the call, before using the result

## Structure

- Keep functions under 40 lines — extract when logic branches
- Group related declarations with `var ()` or `const ()` blocks
- Order: constants, types, constructor, methods, helpers
- Receiver name: 1-2 letter abbreviation of type (`func (s *Server)`)

## Testing

- Table-driven tests for multiple cases
- Test file next to source: `user.go` → `user_test.go`
- Test function names: `TestFunctionName_Scenario`
- Use `testify/assert` for readable assertions
