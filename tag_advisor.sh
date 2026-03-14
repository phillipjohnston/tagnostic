#!/bin/sh
#
# Tag Advisor for Tagnostic
#
# Runs tagnostic diagnostics, then feeds low-scoring tags to Claude
# for actionable improvement suggestions (renames, merges, splits,
# removals, re-tagging).
#
# Usage: ./tag_advisor.sh --agent=agents/claude_agent.sh [--threshold=0.10]
#
# Requirements: curl, jq, perl, ANTHROPIC_API_KEY env var

set -e

script_dir=$(dirname "$(readlink -f "$0")")

# Parse arguments
agent_bin=""
threshold="0.10"
for arg in "$@"; do
    case "$arg" in
        --agent=*) agent_bin="${arg#--agent=}" ;;
        --threshold=*) threshold="${arg#--threshold=}" ;;
    esac
done

if [ -z "$agent_bin" ]; then
    echo "Usage: $0 --agent=<script> [--threshold=0.10]" >&2
    exit 1
fi

model="${TAGNOSTIC_ADVISOR_MODEL:-claude-sonnet-4-6}"

echo "Running tagnostic diagnostics (--all)..."
all_output=$("$script_dir/tagnostic.pl" --agent="$agent_bin" -- --all 2>&1)

echo ""
echo "=== Tag Quality Scores ==="
echo "$all_output"
echo ""

# Find tags below the threshold
low_tags=$(echo "$all_output" | awk -v thresh="$threshold" '
    $1 + 0 < thresh + 0 && NF >= 3 { print $3 }
')

if [ -z "$low_tags" ]; then
    echo "All tags score above threshold ($threshold). No suggestions needed."
    exit 0
fi

echo "=== Low-scoring tags (below $threshold) ==="
echo "$low_tags"
echo ""

# Collect per-tag diagnostics for low-scoring tags
tag_details=""
for tag in $low_tags; do
    echo "Getting details for tag: $tag"
    detail=$("$script_dir/tagnostic.pl" --agent="$agent_bin" -- "$tag" 2>&1)
    tag_details="$tag_details
--- Tag: $tag ---
$detail
"
done

echo ""
echo "=== Asking Claude for suggestions ==="
echo ""

# Build the prompt for Claude
user_prompt="I have a content tagging system and I've run diagnostics on my tags. Here are the results:

## Overall Tag Quality Scores
(Format: quality_score count tag_name)

$all_output

## Detailed Analysis of Low-Scoring Tags (below $threshold)
$tag_details

## What I Need
Based on these diagnostics, please provide actionable suggestions:

1. **Tags to rename** — if a tag name poorly captures its intended meaning, suggest a better name
2. **Tags to merge** — if two tags overlap significantly, suggest combining them
3. **Tags to split** — if a tag is too broad, suggest splitting into more specific tags
4. **Tags to remove** — if a tag adds no value (very low score, few applications, no clear pattern)
5. **Content to re-tag** — if specific content appears mistagged based on the relevance ordering

For each suggestion, explain your reasoning briefly. Focus on the most impactful changes first."

# Call Claude with prompt caching for the diagnostic data
request_body=$(jq -n \
    --arg model "$model" \
    --arg content "$user_prompt" \
    '{
        model: $model,
        max_tokens: 4096,
        temperature: 0,
        system: [{
            type: "text",
            text: "You are an expert content taxonomist. Analyze tag quality diagnostics and provide specific, actionable suggestions for improving a tagging system. Be concise and practical.",
            cache_control: { type: "ephemeral" }
        }],
        messages: [{
            role: "user",
            content: $content
        }]
    }')

response=$(curl -s https://api.anthropic.com/v1/messages \
    -H "Content-Type: application/json" \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -d "$request_body")

# Extract and display the suggestions
suggestions=$(echo "$response" | jq -r '.content[0].text')

if [ -z "$suggestions" ] || [ "$suggestions" = "null" ]; then
    echo "Error getting suggestions from Claude:" >&2
    echo "$response" | jq . >&2
    exit 1
fi

echo "$suggestions"
