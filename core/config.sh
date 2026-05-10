#!/bin/bash
# Zet Config — read zet.toml with section support
# Usage: source this file, then call zet_config_get
# Dependencies: bash, awk
#
# Example:
#   source core/config.sh
#   zet_config_init "/path/to/project"
#   templates_dir=$(zet_config_get "paths" "templates" "templates/")

# --- State ---
ZET_CONFIG_FILE=""
ZET_CONFIG_ROOT=""
ZET_CONFIG_ERRORS=()

# Initialize config reader
# Args: project_root (optional, defaults to $ZET_ROOT or pwd)
zet_config_init() {
    ZET_CONFIG_ROOT="${1:-${ZET_ROOT:-$(pwd)}}"
    ZET_CONFIG_FILE="$ZET_CONFIG_ROOT/zet.toml"
    ZET_CONFIG_ERRORS=()
}

# Validate config file structure
# Returns: 0 if valid (or no file), 1 if errors found
# Populates ZET_CONFIG_ERRORS array with error messages
zet_config_validate() {
    ZET_CONFIG_ERRORS=()

    [ ! -f "$ZET_CONFIG_FILE" ] && return 0

    local line_num=0 current_section="" line
    while IFS= read -r line || [ -n "$line" ]; do
        line_num=$((line_num + 1))

        # Skip blank lines and comments
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # Section header
        if [[ "$line" =~ ^\[ ]]; then
            if [[ ! "$line" =~ ^\[[a-zA-Z0-9_-]+\][[:space:]]*(#.*)?$ ]]; then
                ZET_CONFIG_ERRORS+=("line $line_num: malformed section header: $line")
            else
                current_section="${line#[}"
                current_section="${current_section%%]*}"
            fi
            continue
        fi

        # Key-value pair — must have = and be inside a section
        if [[ -z "$current_section" ]]; then
            ZET_CONFIG_ERRORS+=("line $line_num: key-value outside any section: $line")
            continue
        fi

        if [[ ! "$line" =~ = ]]; then
            ZET_CONFIG_ERRORS+=("line $line_num: not a valid key = value line: $line")
            continue
        fi

        local key_part="${line%%=*}"
        if [[ ! "$key_part" =~ ^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_-]*[[:space:]]*$ ]]; then
            ZET_CONFIG_ERRORS+=("line $line_num: invalid key name: ${key_part}")
        fi

        # Check for unclosed quotes
        local val_part="${line#*=}"
        val_part="${val_part#"${val_part%%[![:space:]]*}"}"
        if [[ "$val_part" =~ ^\" ]] && [[ ! "$val_part" =~ ^\"[^\"]*\"[[:space:]]*(#.*)?$ ]]; then
            ZET_CONFIG_ERRORS+=("line $line_num: unclosed quote: $line")
        fi
    done < "$ZET_CONFIG_FILE"

    [ ${#ZET_CONFIG_ERRORS[@]} -eq 0 ]
}

# Get a value from zet.toml
# Args: section, key, default_value
# Returns: the value (tilde-expanded), or default if not found
zet_config_get() {
    local section="$1" key="$2" default="$3"

    if [ ! -f "$ZET_CONFIG_FILE" ]; then
        echo "$default"
        return
    fi

    local val
    val=$(awk -v section="$section" -v key="$key" '
        # Skip blank lines and comment-only lines
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*#/ { next }

        /^\[/ {
            gsub(/[\[\]]/, "")
            gsub(/^[ \t]+|[ \t]+$/, "")
            in_section = ($0 == section) ? 1 : 0
            next
        }
        in_section && match($0, "^[ \t]*"key"[ \t]*=") {
            sub(/^[^=]*=[ \t]*/, "")
            # Strip inline comments (outside quotes)
            if (match($0, /^"[^"]*"/)) {
                $0 = substr($0, RSTART, RLENGTH)
            } else {
                sub(/[ \t]+#.*$/, "")
            }
            gsub(/^"/, ""); gsub(/"$/, "")
            # Trim trailing whitespace
            gsub(/[ \t]+$/, "")
            print
            exit
        }
    ' "$ZET_CONFIG_FILE")

    if [ -n "$val" ]; then
        echo "${val/#\~/$HOME}"
    else
        echo "$default"
    fi
}

# Get all keys in a section as key=value pairs
# Args: section
zet_config_section() {
    local section="$1"

    [ ! -f "$ZET_CONFIG_FILE" ] && return

    awk -v section="$section" '
        BEGIN { in_section = 0 }
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*#/ { next }
        /^\[/ {
            gsub(/[\[\]]/, "")
            gsub(/^[ \t]+|[ \t]+$/, "")
            in_section = ($0 == section) ? 1 : 0
            next
        }
        in_section && /=/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if ($0 !~ /^#/) {
                # Strip inline comments
                sub(/[ \t]+#[^"]*$/, "")
                print
            }
        }
    ' "$ZET_CONFIG_FILE"
}

# Check if config file exists
zet_config_exists() {
    [ -f "$ZET_CONFIG_FILE" ]
}
