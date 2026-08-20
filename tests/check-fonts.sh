#!/bin/sh

set -eu

contains() {
    font=$1
    shift
    charset=$(fc-query --format='%{charset}' "$font")
    perl -e '
        my ($ranges, @wanted) = @ARGV;
        my @ranges = map {
            my ($lo, $hi) = split /-/, $_, 2;
            [hex($lo), hex(defined($hi) ? $hi : $lo)]
        } split /\s+/, $ranges;
        for my $hex (@wanted) {
            my $cp = hex($hex);
            my $found = grep { $_->[0] <= $cp && $cp <= $_->[1] } @ranges;
            die "missing U+$hex\n" unless $found;
        }
    ' "$charset" "$@"
}

contains assets/fonts/NotoSans.ttf 00D7 00B7 2022
contains assets/fonts/NotoSansSymbols2-Regular.otf 25AA 25B2 25B6 25BD 25C0 25CF 2713
contains assets/fonts/NotoSansSymbols.ttf 266B

echo "bundled font coverage tests passed"
