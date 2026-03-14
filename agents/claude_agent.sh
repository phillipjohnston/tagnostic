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

# Semantic dimensions used for synthetic embeddings.
# Both content and tags are scored on these same dimensions,
# so cosine similarity between them captures relevance.
DIMENSIONS="technology,science,politics,economics,business,finance,health,medicine,environment,energy,education,arts,culture,entertainment,sports,food,travel,personal_narrative,opinion,how_to,tutorial,history,philosophy,psychology,law,security,mathematics,design,communication,community"

SYSTEM_PROMPT="You are a semantic dimension scorer. You will be given either a piece of content or a tag/topic name.

Score the input on each of the following 30 semantic dimensions from 0.0 to 1.0, where 0.0 means completely unrelated and 1.0 means the input is primarily about that dimension:

Dimensions: $DIMENSIONS

Rules:
- Output ONLY a comma-separated list of 30 floating point numbers, one per dimension, in the exact order listed above.
- No other text, no labels, no explanation.
- Use values between 0.0 and 1.0.
- Most values should be near 0.0; only rate dimensions that genuinely apply.

Example output format:
0.0,0.1,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.8,0.7,0.3,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.1,0.0,0.0"

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
