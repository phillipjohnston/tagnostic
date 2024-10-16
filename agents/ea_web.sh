#!/bin/sh

script_dir=$(dirname "$(readlink -f "$0")")
root_site_dir=/Users/phillip/src/ea/website-content

# Need to make a copy of this that does categories, not tags, so we can check category groupings too

case "$1" in

    list-content)
        find "$root_site_dir" -type f | while read -r fn; do

            # We don't want to run analyses on the following files and directories -
            # restricted to pages, glossary, blog posts, newsletters
            if echo "$fn" | grep -qE 'pages|courses|.git|README.md|TODO|e-books|reusable-blocks'; then
                continue
            fi
            tags=$(cat "$fn" | perl -lne '/tags:\s*$/ && ($in_tags = 1) or ($in_tags && /^\s+-\s+(.+)/ && push @tags, $1) } END { print join(",", @tags)' )

            # This line removes the root_site_dir path from the filename, giving us a relative
            # path.
            name=${fn#$root_site_dir/}
            # This variant would give us filename only
            #name=$(basename $fn)

            hash=$(sha256sum $fn | cut -d' ' -f 1)
            echo "$name,$hash,$tags"
        done
        ;;

    embed-content)
        name=${2:?}

        # We limit the content to a specific number of bytes to stay within
        # context window limits
        #
        # We use awk to bypass the frontmatter, which might skew
        # the tag result calculation.
        #
        # We also remove any lines consisting only of numbers
        # because they aren't helpful and become many tokens.
        cat "$root_site_dir/$name" \
            | awk '/^---$/ { fm = !fm; next } !fm' \
            | pandoc -f html -t plain \
            | tr -d '\n' \
            | grep -vE '^[0-9., -]+$' \
            | perl -CS -pe 'BEGIN{ binmode(STDIN, ":utf8"); } s/^(.{0,30000})\X*/$1/s' \
            | llm embed -m 3-small \
            | sed 's/[][ ]//g'
        ;;

    embed-tag)
        tag=${2:?}
        llm embed -m 3-small -c "$tag" \
            | sed 's/[][ ]//g'
        ;;

    *)
        echo "Unrecognised subcommand."
        ;;

esac
