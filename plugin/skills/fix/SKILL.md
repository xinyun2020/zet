---
name: fix
description: Resolve issues found by zet doctor
---

# Fix — resolve harness issues

## When to use
After `zet doctor` reports issues, or when the user says "fix", "repair", "clean up".

## Method

1. Run `zet doctor --json` to get structured issue data
2. For each issue category, apply the resolution strategy:

### Broken symlinks
```bash
# Get the symlink target to classify
readlink -f /path/to/broken/link  # shows where it was pointing
```
- Target was in R-template/ (zet-generated) → `zet generate` rebuilds it
- Name starts with `ecc-` (ECC plugin cache) → `rm` the symlink, plugin recreates
- Unknown origin → check git log for when it was created, investigate

### Stale paths
- Glob for the referenced filename in likely locations
- If found at new path → update the reference
- If genuinely deleted → remove the reference
- If ambiguous → ask the user

### Missing descriptions
- Read the template body, infer a concise description from the content
- Add `description:` to the YAML frontmatter
- Run `zet validate` to confirm

### Secret detection
- Check if the match is a real credential or an example/pattern
- Real → remove immediately, warn user to rotate
- Example → add to allowlist or restructure to avoid false positive

## After fixing
- Run `zet doctor` again to confirm issues resolved
- Run `zet validate` to ensure no new issues introduced
- Report what changed
