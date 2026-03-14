# Tagnostic

Determine the relevance and quality of tag assignments to any content, as long
as both tags and content can be transformed into something embedding-like.

## Installation

For Tagnostic itself: none as long as you're on a system that comes with Perl (this means almost all
Unix-like systems including Windows with git bash etc.) Download and run
`tagnostic.pl`.

However, your implementation of the _agent script_ might have additional
requirements, but that's on you. I recommend making it a shell script using
Simon Willison's `llm` CLI tool because that's a really quick way to get
started. But you can write the agent script any way you want, including
generating your own embeddings.

## Usage

First run

```shell
./tagnostic.pl --agent=<script> -- --all
```

to display an ordered table of all tags and their numeric quality score. For a
fictional newspaper issue, it might look like

```
-0.01    5   travel
 0.02   12   culture
 0.04    2   economy
 0.08    7   technology
 0.11   10   business
 0.19    4   sports
```

The first number is the tag quality score, which is a measure of the agreement
beteewn tag applications and tag relevance (as determined through embeddings.)
The second number is how often the tag is applied.

When a specific tag has been identified as a target for improvement, e.g.
because it has a low quality score or because it is rarely used in practice, one
can view the content listing for that tag. To do that for e.g. the _culture_ tag,
run

 ```shell
./tagnostic.pl --agent=<script> -- culture
 ```

This will show a list of content ordered by relevance to the tag, and indicate
to which content has the tag applied. For the newspaper issue, it might look
like

```
               Gomez still open to Liverpool exit
               Nottingham Forest sign forward Silva
               CrowdStrike sued by shareholders over global outage
     culture   The BBC faces questions over why it did not sack Huw Edwards
               GB Medal Hope Wightman pulls out of Olympics
               UK interest rates cut for first time in over four years
               Turbulence takes instant noodles off Korean Air menu
     culture   Video games strike rumbles on in row over AI
               Can AI fix the broken concert ticketing system?
     culture   Ancient Egypt to Taylor Swift: The historic roots of the 'cat lady'
Agreement: 0.02
```

Here, we can tell that some some of the most culture-associated articles are not
tagged with the _culture_ tag, and some articles tagged with the _culture_ tag do
not appear to be very cultural. At this point, there are N things we can do:

1. Keep the tag as it is, because we have determined it captures something the
   embeddings miss.
2. Remove the tag because it doesn't capture anything.
3. Expand the coverage of the tag to articles that we missed.
4. Rename the tag to better capture the intention.

To evaluate the effect of renaming a tag, e.g. _culture_ to _arts_, it is possible to run

```shell
./tagnostic.pl --agent=<script> -- culture arts
```

This uses the first argument (_culture_) to determine which articles would
receive the tag, and the second argument (_arts_) to determine in which order.
It might show something like

```
               UK interest rates cut for first time in over four years
               CrowdStrike sued by shareholders over global outage
               Gomez still open to Liverpool exit
               Nottingham Forest sign forward Silva
               GB Medal Hope Wightman pulls out of Olympics
               Can AI fix the broken concert ticketing system?
        arts   Video games strike rumbles on in row over AI
               Turbulence takes instant noodles off Korean Air menu
        arts   The BBC faces questions over why it did not sack Huw Edwards
        arts   Ancient Egypt to Taylor Swift: The historic roots of the 'cat lady'
Agreement: 0.02
Agreement (renamed): 0.14
```

In this case, renaming the culture tag would be an improvement – as judged by
embeddings, the word _arts_ captures the intention of the _culture_ tag better.

## Tagnostic requires separate agent script

If you tried copy-pasting the examples above, you would likely run into an error
saying something about <script> not being an executable file.

Tagnostic requires _you_ to write and supply an _agent script_, which is any
plain executable that supports three operations, taken as command-line
arguments:

- `list-content`

    The `list-content` operation should return one line for each piece of
    content, with the format `name,hash,a_tag,more_tags,further_tags`.

    The hash is only used as a cache key, which means it does not need
    cryptographic guarantees. It just needs to be likely to change when the
    content does.

- `embed-content <name>`

    The `embed-content` operation should make an embedding for the content that
    was referenced as `name` in the `list-content` command, and return it as a
    comma-separated list of numbers.

- `embed-tag <name>`

     The `embed-tag` operation shall make an embedding for the tag called
     `name`.

In other words, when Tagnostic runs, it tries to execute your agent script for
these operations. It looks a little like this:

```
  TAGNOSTIC                     AGENT SCRIPT
┌────────────┐                 ┌────────────┐
│            │                 │            │
│            │  list-content   │            │
│            ├────────────────>┤            │
│            │                 └────────────┘
│            │                 ┌────────────┐
│            │  embed-content  │            │
│            │     <name>      │            │
│            ├────────────────>┤            │
│            │                 └────────────┘
│            │                 ┌────────────┐
│            │    embed-tag    │            │
│            │     <name>      │            │
│            ├────────────────>┤            │
└────────────┘                 └────────────┘
```

The easiest way to create an agent script is as a plain shell script, following
roughly the structure

```shell
#!/bin/sh

case "${1:?}" in
    list-content)
        # CODE
        ;;
    embed-content)
        name=${2:?}
        # CODE
        ;;
    embed-tag)
        tag=${2:?}
        # CODE
        ;;
    *)
        echo "Unrecognised subcommand."
        ;;
esac
```

In my personal agent scripts, I have used Simon Willison's LLM CLI tool for
getting embeddings. An invocation like

```shell
llm embed -m 3-small -c "$tag" | sed 's/[][ ]//g'
```

will output an embedding for `$tag` in the format expected by Tagnostic,
assuming one has entered keys for OpenAI. The LLM CLI can also use the
SentenceTransformers library through the llm-sentence-transformers plugin to get
embeddings locally. (I would probably have preferred this approach if I wasn't
on a bandwidth-constrained connection when I'm writing this.)

For more information on embeddings through the LLM CLI tool, see
https://llm.datasette.io/en/stable/embeddings/cli.html.

For more inspiration including the full agent script I use on my site [Entropic
Thoughts](https://entropicthoughts.com/) see [the blog post introducing this
tool](https://entropicthoughts.com/determining-tag-quality).

## Included Claude agent

A ready-to-use agent script using the Anthropic API is included at
`agents/claude_agent.sh`. Instead of traditional embeddings, it asks Claude
Haiku to score content and tags on 30 semantic dimensions, producing vectors
that work with Tagnostic's cosine similarity. It uses prompt caching to keep
costs low.

Requirements: `curl`, `jq`, and an `ANTHROPIC_API_KEY` environment variable.

```shell
export ANTHROPIC_API_KEY="sk-..."
export TAGNOSTIC_CONTENT_DIR="/path/to/your/content"
./tagnostic.pl --agent=agents/claude_agent.sh -- --all
```

The `TAGNOSTIC_CONTENT_DIR` variable tells the agent where to find your content
files (markdown, HTML, org-mode, or plain text with YAML frontmatter tags). It
defaults to the current directory.

### Batch precomputation

For larger corpora, `batch_precompute.sh` submits all uncached items to the
Anthropic Message Batches API at 50% cost. Once the batch completes, Tagnostic
runs entirely from cache with no further API calls.

```shell
./batch_precompute.sh --agent=agents/claude_agent.sh
```

### Tag advisor

`tag_advisor.sh` is a wrapper that runs Tagnostic diagnostics and feeds the
results to Claude for actionable suggestions: tag renames, merges, splits,
removals, and re-tagging recommendations.

```shell
./tag_advisor.sh --agent=agents/claude_agent.sh --threshold=0.10
```

Tags scoring below the threshold (default 0.10) are analysed in detail and
sent to Claude Sonnet for advice.


## Contributing

Feel free to! There are no tests, but the entire program is 150 or so lines of
Perl code, and should be fairly legibly structured.i
