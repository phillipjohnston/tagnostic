#!/bin/sh
#
# Claude agent for Tagnostic
#
# Uses the Anthropic Messages API to produce synthetic relevance vectors
# by scoring content/tags on semantic dimensions. Drop-in replacement for
# the OpenAI embedding-based agents.
#
# Requirements: curl, jq, ANTHROPIC_API_KEY env var
# Optional:     TAGNOSTIC_CONTENT_DIR env var (defaults to cwd)

set -e

script_dir=$(dirname "$(readlink -f "$0")")
content_dir="${TAGNOSTIC_CONTENT_DIR:-.}"
model="${TAGNOSTIC_MODEL:-claude-haiku-4-5}"

# Load semantic dimensions from file.
# Override with TAGNOSTIC_DIMENSIONS=/path/to/your/dimensions.txt
dimensions_file="${TAGNOSTIC_DIMENSIONS:-$script_dir/dimensions.default}"

if [ ! -f "$dimensions_file" ]; then
    echo "Dimensions file not found: $dimensions_file" >&2
    echo "Create one (see agents/dimensions.default) or set TAGNOSTIC_DIMENSIONS." >&2
    exit 1
fi

# Read dimensions: strip comments, blank lines, join with commas
DIMENSIONS=$(grep -v '^\s*#' "$dimensions_file" | grep -v '^\s*$' | tr '\n' ',' | sed 's/,$//')
DIMENSION_COUNT=$(echo "$DIMENSIONS" | tr ',' '\n' | wc -l)

# Build example output: mostly 0.0, with a few non-zero values
EXAMPLE_OUTPUT=$(echo "$DIMENSIONS" | tr ',' '\n' | awk '
    BEGIN { srand(42) }
    { printf "%s%.1f", (NR>1 ? "," : ""), (NR==12 ? 0.8 : (NR==13 ? 0.7 : (NR==14 ? 0.3 : (NR==2 ? 0.1 : 0.0)))) }
')

SYSTEM_PROMPT="You are a semantic dimension scorer. You will be given either a piece of content or a tag/topic name.

Score the input on each of the following $DIMENSION_COUNT semantic dimensions from 0.0 to 1.0, where 0.0 means completely unrelated and 1.0 means the input is primarily about that dimension:

Dimensions: $DIMENSIONS

Rules:
- Output ONLY a comma-separated list of $DIMENSION_COUNT floating point numbers, one per dimension, in the exact order listed above.
- No other text, no labels, no explanation.
- Use values between 0.0 and 1.0.
- Most values should be near 0.0; only rate dimensions that genuinely apply.

Example output format:
$EXAMPLE_OUTPUT"

call_claude() {
    local user_content="$1"

    # Build the JSON request with prompt caching on the system message
    local request_body
    request_body=$(jq -n \
        --arg model "$model" \
        --arg system "$SYSTEM_PROMPT" \
        --arg content "$user_content" \
        '{
            model: $model,
            max_tokens: 256,
            temperature: 0,
            system: [{
                type: "text",
                text: $system,
                cache_control: { type: "ephemeral" }
            }],
            messages: [{
                role: "user",
                content: $content
            }]
        }')

    local response
    response=$(curl -s https://api.anthropic.com/v1/messages \
        -H "Content-Type: application/json" \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -d "$request_body")

    # Extract text from response, strip whitespace
    echo "$response" | jq -r '.content[0].text' | tr -d ' \n'
}

case "$1" in

    list-content)
        find "$content_dir" -type f \( -name '*.md' -o -name '*.html' -o -name '*.htm' -o -name '*.txt' -o -name '*.org' \) | while read -r fn; do
            # Skip hidden files and directories
            case "$fn" in
                */.git/*|*/.obsidian/*|*/node_modules/*) continue ;;
            esac

            # Extract YAML frontmatter tags (supports "tags:" followed by
            # indented list items like "  - tagname")
            tags=$(perl -lne '
                /^tags:\s*$/ && ($in_tags = 1)
                    or ($in_tags && /^\s+-\s+(.+)/ && push @tags, $1)
                    or ($in_tags && /^\S/ && ($in_tags = 0));
                END { print join(",", @tags) }
            ' "$fn" 2>/dev/null)

            # Also try org-mode FILETAGS format
            if [ -z "$tags" ]; then
                tags=$(perl -lne '/FILETAGS: :([a-z:_]+):/ && print ($1 =~ tr/:/,/r)' "$fn" 2>/dev/null)
            fi

            name=${fn#$content_dir/}
            hash=$(sha256sum "$fn" | cut -d' ' -f 1)
            echo "$name,$hash,$tags"
        done
        ;;

    embed-content)
        name=${2:?}
        TRUNCATE_BYTES=32768

        # Strip YAML frontmatter, remove numeric-only lines, truncate
        content=$(cat "$content_dir/$name" \
            | awk '/^---$/ { fm = !fm; next } !fm' \
            | grep -vE '^[0-9., -]+$' \
            | head -c $TRUNCATE_BYTES)

        call_claude "Score the following content on all semantic dimensions:

$content"
        ;;

    embed-tag)
        tag=${2:?}
        call_claude "Score the following tag/topic on all semantic dimensions: $tag"
        ;;

    *)
        echo "Unrecognised subcommand." >&2
        exit 1
        ;;

esac
