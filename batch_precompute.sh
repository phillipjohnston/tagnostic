#!/bin/sh
#
# Batch precompute script for Tagnostic
#
# Uses the Anthropic Message Batches API to precompute all embeddings
# at 50% cost. Results are written to /tmp/tagnostic_cache so that
# tagnostic.pl can run without any API calls.
#
# Usage: ./batch_precompute.sh --agent=agents/claude_agent.sh
#
# Requirements: curl, jq, ANTHROPIC_API_KEY env var

set -e

# Parse arguments
agent_bin=""
for arg in "$@"; do
    case "$arg" in
        --agent=*) agent_bin="${arg#--agent=}" ;;
    esac
done

if [ -z "$agent_bin" ]; then
    echo "Usage: $0 --agent=<script>" >&2
    exit 1
fi

model="${TAGNOSTIC_MODEL:-claude-haiku-4-5}"
cache_file="/tmp/tagnostic_cache"
batch_file="/tmp/tagnostic_batch_requests.jsonl"
content_dir="${TAGNOSTIC_CONTENT_DIR:-.}"
TRUNCATE_BYTES=32768

# Load semantic dimensions from the same file the agent uses
script_dir=$(dirname "$(readlink -f "$0")")
dimensions_file="${TAGNOSTIC_DIMENSIONS:-$script_dir/agents/dimensions.default}"

if [ ! -f "$dimensions_file" ]; then
    echo "Dimensions file not found: $dimensions_file" >&2
    echo "Create one (see agents/dimensions.default) or set TAGNOSTIC_DIMENSIONS." >&2
    exit 1
fi

DIMENSIONS=$(grep -v '^\s*#' "$dimensions_file" | grep -v '^\s*$' | tr '\n' ',' | sed 's/,$//')
DIMENSION_COUNT=$(echo "$DIMENSIONS" | tr ',' '\n' | wc -l)

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

# Touch cache file
touch "$cache_file"

# Load existing cache keys
cached_keys=$(cut -d: -f1 "$cache_file" 2>/dev/null || true)

is_cached() {
    echo "$cached_keys" | grep -qxF "$1"
}

echo "Listing content via agent..."
content_list=$("$agent_bin" list-content)

# Build JSONL batch file
echo -n > "$batch_file"
request_count=0

echo "Checking cache and building batch requests..."

echo "$content_list" | while IFS=',' read -r name hash tags_rest; do
    [ -z "$name" ] && continue

    # Content embedding
    cache_key="content_${name}_${hash}"
    if ! is_cached "$cache_key"; then
        # Read and preprocess content
        content=$(cat "$content_dir/$name" 2>/dev/null \
            | awk '/^---$/ { fm = !fm; next } !fm' \
            | grep -vE '^[0-9., -]+$' \
            | head -c $TRUNCATE_BYTES || true)

        if [ -n "$content" ]; then
            jq -n -c \
                --arg id "content:$cache_key" \
                --arg model "$model" \
                --arg system "$SYSTEM_PROMPT" \
                --arg content "Score the following content on all semantic dimensions:

$content" \
                '{
                    custom_id: $id,
                    params: {
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
                    }
                }' >> "$batch_file"
        fi
    fi

    # Tag embeddings
    remaining="$tags_rest"
    while [ -n "$remaining" ]; do
        tag="${remaining%%,*}"
        if [ "$tag" = "$remaining" ]; then
            remaining=""
        else
            remaining="${remaining#*,}"
        fi

        [ -z "$tag" ] && continue
        tag_cache_key="tag_$tag"
        if ! is_cached "$tag_cache_key"; then
            jq -n -c \
                --arg id "tag:$tag_cache_key" \
                --arg model "$model" \
                --arg system "$SYSTEM_PROMPT" \
                --arg content "Score the following tag/topic on all semantic dimensions: $tag" \
                '{
                    custom_id: $id,
                    params: {
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
                    }
                }' >> "$batch_file"
        fi
    done
done

request_count=$(wc -l < "$batch_file")

if [ "$request_count" -eq 0 ]; then
    echo "All items already cached. Nothing to do."
    exit 0
fi

echo "Submitting batch with $request_count requests..."

# Read JSONL and build JSON array of requests
requests_json=$(jq -s '.' "$batch_file")

# Submit batch
batch_response=$(curl -s https://api.anthropic.com/v1/messages/batches \
    -H "Content-Type: application/json" \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -d "{\"requests\": $requests_json}")

batch_id=$(echo "$batch_response" | jq -r '.id')

if [ -z "$batch_id" ] || [ "$batch_id" = "null" ]; then
    echo "Error creating batch:" >&2
    echo "$batch_response" | jq . >&2
    exit 1
fi

echo "Batch created: $batch_id"
echo "Polling for completion..."

# Poll until batch is done
while true; do
    status_response=$(curl -s "https://api.anthropic.com/v1/messages/batches/$batch_id" \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01")

    status=$(echo "$status_response" | jq -r '.processing_status')
    succeeded=$(echo "$status_response" | jq -r '.request_counts.succeeded // 0')
    processing=$(echo "$status_response" | jq -r '.request_counts.processing // 0')

    echo "  Status: $status (succeeded: $succeeded, processing: $processing)"

    if [ "$status" = "ended" ]; then
        break
    fi

    sleep 30
done

# Retrieve results
echo "Retrieving results..."
results_url=$(echo "$status_response" | jq -r '.results_url')

if [ -n "$results_url" ] && [ "$results_url" != "null" ]; then
    results=$(curl -s "$results_url" \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01")
else
    # Fall back to API endpoint
    results=$(curl -s "https://api.anthropic.com/v1/messages/batches/$batch_id/results" \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01")
fi

# Parse results and write to cache
success_count=0
error_count=0

echo "$results" | while IFS= read -r line; do
    [ -z "$line" ] && continue

    custom_id=$(echo "$line" | jq -r '.custom_id')
    result_type=$(echo "$line" | jq -r '.result.type')

    if [ "$result_type" = "succeeded" ]; then
        # Extract the cache key (strip the "content:" or "tag:" prefix)
        cache_key="${custom_id#*:}"
        embedding=$(echo "$line" | jq -r '.result.message.content[0].text' | tr -d ' \n')

        if [ -n "$embedding" ] && [ "$embedding" != "null" ]; then
            printf "%s:%s\n" "$cache_key" "$embedding" >> "$cache_file"
            success_count=$((success_count + 1))
        fi
    else
        error_count=$((error_count + 1))
        echo "  Error for $custom_id: $(echo "$line" | jq -r '.result.error // .result')" >&2
    fi
done

errored=$(echo "$status_response" | jq -r '.request_counts.errored // 0')
final_succeeded=$(echo "$status_response" | jq -r '.request_counts.succeeded // 0')

echo ""
echo "Done! Succeeded: $final_succeeded, Errored: $errored"
echo "Cache updated at: $cache_file"
echo ""
echo "Now run: ./tagnostic.pl --agent=$agent_bin -- --all"
