#!/bin/sh

script_dir=$(dirname "$(readlink -f "$0")")

case "$1" in

    list-content)
        find "$script_dir/../src/org" -type f | while read -r fn; do
            if grep -qE ':page:|:draft:' "$fn"; then
                continue
            fi
            tags=$(
                cat "$fn" \
                    | perl -lne '/FILETAGS: :([a-z:_]+):/ && print ($1 =~ tr/:/,/r)'
                )
            name=$(basename $fn)
            hash=$(sha256sum $fn | cut -d' ' -f 1)
            echo "$name,$hash,$tags"
        done
        ;;

    embed-content)
        name=${2:?}
        # The first 500 lines should be enough to be accurate
        # but without breaking any context window limits.
        #
        # We also remove any lines consisting only of numbers
        # because they aren't helpful and become many tokens.
        cat "$script_dir/../src/org/$name" \
            | grep -vE '^[0-9., -]+$' \
            | head -n 500 \
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
