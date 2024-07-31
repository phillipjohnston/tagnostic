#!/usr/bin/perl

use v5.16;
use strict;
use warnings;
use Getopt::Long;
use Data::Dumper;
use Carp;

# --------------------------------------
#     CLI argument processing
# --------------------------------------
sub usage {
    my ($msg) = @_;
    say 'Usage: ./tagnostic.pl --agent=<script> -- <tag_name|--all>';
    say $msg if $msg;
    exit 1;
}

GetOptions("agent=s" => \my $agent_bin);
$agent_bin or usage 'Missing --agent=<script>';
my $tag = shift @ARGV or usage 'Must specify tag_name or --all.';


# --------------------------------------
#     Embedding cache
# --------------------------------------
my %embedding_memory_cache;

sub embedding_cache {
    my ($key, $get_embedding) = @_;
    my $embedding_cache_fn = '/tmp/tagnostic_cache';

    my $embedding;
    $embedding = $embedding_memory_cache{$key};
    
    # If we don't have the embedding in memory yet.
    if (! $embedding) {

        # Create the cache file if it does not exist.
        open(my $cache_touch, '>>:encoding(UTF-8)', $embedding_cache_fn);
        close($cache_touch);

        # Read all embeddings from cache file.
        #
        # This used to read just the one we are looking for, but
        # random access into a file is slow even compared to
        # re-filling the cache hash on every cache miss.
        open(my $cache_read, '<:encoding(UTF-8)', $embedding_cache_fn);
        while (<$cache_read>) {
            my ($k, $v) = split ':';
            $embedding_memory_cache{$k} = $v;
        }
        close($cache_read);

        $embedding = $embedding_memory_cache{$key};
    }

    # If we don't have it, get a fresh embedding and store it in cache.
    if (! $embedding) {
        $embedding = $get_embedding->();
        if ($embedding) {
            open(my $cache_write, '>>:encoding(UTF-8)', $embedding_cache_fn);
            printf $cache_write "%s:%s\n", $key, $embedding;
            close($cache_write);
        }
    }

    if (! $embedding) {
        croak "Failed to get embedding for $key";
    }

    # Return embedding values.
    $embedding_memory_cache{$key} = $embedding;
    return [split ',', $embedding];
}



# --------------------------------------
#     Interaction with agent script
# --------------------------------------
sub get_content {
    my @all;

    open(my $fd, '-|', $agent_bin, 'list-content');
    while (<$fd>) {
        chomp;
        my ($name, $hash, @tags) = split ',';
        push @all, { name => $name, hash => $hash, tags => \@tags };
    }
    close($fd);

    return @all;
}

sub get_content_embedding {
    my ($content) = @_;
    my $key = sprintf "content_%s_%s", $content->{name}, $content->{hash};
    embedding_cache $key, sub {
        qx( $agent_bin embed-content $content->{name} );
    };
}

sub get_tag_embedding {
    my ($tag) = @_;
    embedding_cache "tag_$tag", sub {
        qx( $agent_bin embed-tag $tag );
    };
}



# --------------------------------------
#     Relevance determinations
# --------------------------------------
sub tag_application_count {
    my ($tag, @content) = @_;
    my $count = 0;
    for (@content) {
        $count++ if grep { $_ eq $tag } @{$_->{tags}};
    }
    $count;
}

sub cosine_difference {
    my ($va, $vb) = @_;

    # Get lengths and make sure they are equal.
    my ($na, $nb) = map { scalar(@$_) } ($va, $vb);
    croak 'Must be equal length.' unless $na == $nb;

    # Compute inner (dot) product.
    my $inner = 0;
    $inner += $va->[$_] * $vb->[$_] for 0..$#{$va};

    $inner/($na * $nb);
}

sub tag_relevance_order {
    my ($tag, @content) = @_;
    my $tag_values = get_tag_embedding $tag;
    my @dists = map {
        cosine_difference($tag_values, get_content_embedding $_)
    } @content;

    @content[sort { $dists[$a] <=> $dists[$b] } 0..$#content];
}

sub point_biserial {
    my ($tag, @reordered) = @_;

    my @tagged = map { !! grep { $_ eq $tag } @{$_->{tags}} } @reordered;

    my @tagged_ranks = grep { !! $tagged[$_] } 0..$#reordered;

    my $n_tagged = scalar(@tagged_ranks);
    my $n_other = scalar(@reordered) - $n_tagged;
    return -1 if $n_tagged == 0;

    my $m_tagged = 0;
    $m_tagged += $_ for @tagged_ranks;
    $m_tagged /= $n_tagged;

    my $m_other = 0;
    $m_other += $_ for grep { ! $tagged[$_] } 0..$#reordered;
    $m_other /= $n_other;

    # Let's assume we have enough content to make this approximation.
    my $st = (scalar(@reordered) - 1) / sqrt(12);

    ($m_tagged - $m_other) / $st
            * sqrt( $n_tagged * $n_other / (scalar @reordered)**2 );
}



# --------------------------------------
#     Print diagnostics
# --------------------------------------

sub truncstr {
    my ($n, $s) = @_;
    length $s > $n ? substr($s, 0, $n-3) . '...' : $s;
}

sub diagnose_all {
    my (@content) = @_;

    my %all_tags;
    for (@content) {
        my @tags = @{$_->{tags}};
        $all_tags{$_} = 1 for @tags;
    }

    my @points = map {
        my $tag = $_;
        [$tag, point_biserial($tag, tag_relevance_order($tag, @content))];
    } keys %all_tags;
    for (sort { $points[$a][1] <=> $points[$b][1] } 0..$#points) {
        my ($name, $point) = @{$points[$_]};
        next unless $name;
        my $count = tag_application_count($name, @content);
        printf "%5.2f %5d %20s\n", $point, $count, $name;
    }
}

sub diagnose_tag {
    my ($tag, $rename, @content) = @_;

    my @reordered = tag_relevance_order $rename // $tag, @content;
    for my $c (@reordered) {
        my ($tagged) = grep { $_ eq $tag } @{$c->{tags}};
        printf "%15s %s\n",
            $tagged ? truncstr(15, $rename // $tagged) : "",
            truncstr(60, $c->{name});
    }
    printf "Agreement: %5.2f\n", point_biserial($tag, tag_relevance_order $tag, @content);
    if ($rename) {
        printf "Agreement (renamed): %5.2f\n", point_biserial($tag, @reordered);
    }
}


# --------------------------------------
#     Entry point, branching on tag
# --------------------------------------
sub main {
    my @content = get_content;

    if ($tag eq '--all') {
        diagnose_all @content;
    } else {
        my $rename = shift @ARGV;
        diagnose_tag $tag, $rename, @content;
    }
}

main;
