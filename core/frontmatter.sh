#!/bin/bash
# Zet Frontmatter — shared YAML frontmatter parsing for templates
# Usage: source this file, then call get_template_type / get_frontmatter_value
# Dependencies: bash, awk
#
# Extracted from generator.sh, scanner.sh, doctor.sh to eliminate
# three independent implementations of the same awk patterns (DRY).

# Get the type: field from a template's YAML frontmatter
# Args: file_path
# Returns: the type value (skill, agent, rule) or empty string
get_template_type() {
    local file="$1"
    awk '/^---$/{if(fm){exit}else{fm=1;next}} fm && /^type:/{sub(/^type: */,"");print;exit}' "$file"
}

# Get any frontmatter field value from a template
# Args: file_path, key_name
# Returns: the value (unquoted) or empty string
get_frontmatter_value() {
    local file="$1" key="$2"
    awk '/^---$/{if(fm){exit}else{fm=1;next}} fm && /^'"$key"':/{sub(/^'"$key"': *"?/,"");sub(/"$/,"");print;exit}' "$file"
}

# Get a YAML list field from frontmatter (handles multi-line "- item" syntax)
# Args: file_path, key_name
# Returns: newline-separated list items (stripped of "- " prefix and quotes)
# Example: child:\n  - foo\n  - bar → "foo\nbar"
get_frontmatter_list() {
    local file="$1" key="$2"
    awk -v key="$key" '
        BEGIN { in_fm=0; in_key=0 }
        /^---$/ { if(in_fm){exit}else{in_fm=1; next} }
        !in_fm { next }
        # Start of our key (inline list or block list start)
        $0 ~ "^"key":" {
            val = $0
            sub(/^[^:]*:[ \t]*/, "", val)
            # Inline list: key: [a, b, c]
            if (match(val, /^\[.*\]$/)) {
                gsub(/[\[\]"]/, "", val)
                n = split(val, items, /,[ \t]*/)
                for (i=1; i<=n; i++) {
                    gsub(/^[ \t]+|[ \t]+$/, "", items[i])
                    if (items[i] != "") print items[i]
                }
                exit
            }
            # Single value on same line (not a list)
            if (val != "" && val !~ /^$/) {
                gsub(/^"/, "", val); gsub(/"$/, "", val)
                print val
                exit
            }
            # Block list follows on next lines
            in_key=1
            next
        }
        in_key {
            # Continuation: indented "- item" lines
            if (/^[ \t]+-/) {
                item = $0
                sub(/^[ \t]+-[ \t]*/, "", item)
                gsub(/^"/, "", item); gsub(/"$/, "", item)
                gsub(/^[ \t]+|[ \t]+$/, "", item)
                if (item != "") print item
            } else {
                # End of list (next key or blank)
                exit
            }
        }
    ' "$file"
}

# Resolve a path to absolute (relative paths become relative to ZET_ROOT)
# Args: path
# Returns: absolute path with trailing slash stripped
resolve_path() {
    local path="$1"
    path="${path%/}"
    [[ "$path" == /* ]] && echo "$path" && return
    echo "${ZET_ROOT:-.}/$path"
}
