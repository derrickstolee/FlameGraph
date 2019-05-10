#!/usr/bin/env perl

=head1 NAME

stackcollapse-git-tr2-event.pl - collapse git tr2 events into single lines.

=head1 SYNOPSIS

    # First, check if your git version supports trace2 output. This
    # should all emit JSON:
    GIT_TR2_EVENT=/dev/stderr git version >/dev/null
    GIT_TR2_EVENT=/dev/stderr git status >/dev/null
    GIT_TR2_EVENT=/dev/stderr git gc >/dev/null

    # Simple use:
    ./stackcollapse-git-tr2-event.pl <infile >outfile

    # Debug output
    ./stackcollapse-git-tr2-event.pl --debug=1 <infile >outfile
    ./stackcollapse-git-tr2-event.pl --debug=2 <infile >outfile
    ./stackcollapse-git-tr2-event.pl --debug=3 <infile >outfile

    # Dump the pre-summarized normalized output we use
    # internally. It's *not* stable, but can help to write custom
    # aggregations.
    ./stackcollapse-git-tr2-event.pl --dump-raw <infile >outfile

    # On in git.git's "t" directory, run the whole test suite:
    rm /tmp/git.events; time GIT_TR2_EVENT=/tmp/git.events GIT_TR2_EVENT_NESTING=10 prove -j$(parallel --number-of-cores) t[0-9]*.sh

    # Then, with FlameGraph.git checked out besides it run e.g. this
    # in the root of git.git:
    time (pv /tmp/git.events | perl ../FlameGraph/stackcollapse-git-tr2-event.pl >out.folded); time perl ../FlameGraph/flamegraph.pl --title="FlameGraph of time in Git's test suite" --subtitle="Time in microseconds. See https://github.com/avar/FlameGraph/tree/stackcollapse-git-tr2-event" --height 32 --countname microseconds --nametype command <out.folded >out.folded.tmp && mv out.folded.tmp ~/www/noindex/git-tests.svg

=head1 COPYING

Copyright 2019 Ævar Arnfjörð Bjarmason (avarab@gmail.com). All
rights reserved.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or (at
your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307,
USA.

(http://www.gnu.org/copyleft/gpl.html)

=cut

use v5.10.0;
use strict;
use warnings;
use JSON::XS qw(decode_json);
use Date::Parse qw(str2time);
use Cwd qw(abs_path);
use Pod::Usage;
use Getopt::Long;

GetOptions(
    'help|?'   => \my $help,
    'man'      => \my $man,
    'debug=i'  => \(my $debug = 0),
    'dump-raw' => \my $dump_raw,
) or pod2usage(2);
pod2usage(1) if $help;
pod2usage(-exitstatus => 0, -verbose => 2) if $man;

my %abs_path;
my %events;
LINE: while (my $line = <>) {
    chomp $line;
    my $event;
    eval {
        $event = decode_json($line);
        1;
    } or do {
        my $error = $@;
        # Skip encoding issues for now...
        next LINE;
    };

    my $sid = $event->{sid} || die "PANIC: No sid in <$line> <" . mydump($event) . ">";
    my $es = ($events{$sid} ||= {});
    my $type = $event->{event};

    #local $SIG{__WARN__} = sub {
    #    my ($warn) = @_;
    #    say STDERR "Noes <$warn> on event: <" . mydump([$sid, $event, $es]) . ">";
    #    return;
    #};

    my $unhandled;
    if ($type eq 'version') {
        die "PANIC: Have event $sid twice!" if keys %$es;
        $es->{version} = $event->{exe};
    } elsif ($type eq 'start') {
        $es->{start_epoch} = str2time($event->{time});
        $es->{argv} = $event->{argv};
    } elsif ($type eq 'cmd_name') {
        $es->{cmd_name} = $event->{name};
        $es->{hierarchy} = $event->{hierarchy};
    } elsif ($type eq 'def_repo') {
        my $worktree = $event->{worktree};
        # abs_path() returns undef if the directory has gone away
        $worktree = ($abs_path{$worktree} ||= (abs_path($worktree) || $worktree));
        $es->{worktree} = $worktree;
    } elsif ($type eq 'exit') {
        $es->{exit_epoch} = str2time($event->{time});
        $es->{exit_code} = $event->{code};
    } elsif ($type eq 'signal') {
        $es->{signal_epoch} = str2time($event->{time});
        $es->{signal_signo} = $event->{signo};
    } elsif ($type eq 'atexit') {
        # Happens after 'exit', but we get the info we need
        # there. Ignore for now. More inclusive technically, but so is
        # "version" and I use "start" instead.
    } elsif ($type eq 'region_enter' or
             $type eq 'region_leave') {
        my $nesting = $event->{nesting};
        my $category = $event->{category};
        my $label = $event->{label};

        # For the purposes of logging we handle these as
        # "subprocesses". We must delimit by something not "/" because
        # git uses that ($; seems obvious...)
        my $fake_hierarchy = "REGION:" . ("$category/$label" =~ s[/][$;]gr);
        my $fake_sid = $sid . '/' . $fake_hierarchy;
        my $es_fake = ($events{$fake_sid} ||= {});

        $es_fake->{hierarchy} = $fake_hierarchy;
        $es_fake->{sid} = $sid;
        $es_fake->{"${type}_count"}++;

        # We'll get many of these enter/leave, so the "fake"
        # start/exit times are arrays. Fixed up later.
        my $epoch_key = $type eq 'region_enter'
                        ? 'start_epoch'
                        : $type eq 'region_leave'
                        ? 'exit_epoch'
                        : die "BUG: Unknown type <$type>";
        push @{$es_fake->{$epoch_key}}, str2time($event->{time});
    } elsif ($type eq 'data') {
        # TODO(maybe): I don't see what I can do in a useful fashion
        # with these "data" points. I *guess* I could fake up the
        # aggregate times I spend from encountering one of these until
        # the end of the process, but it won't be mutually exclusive.
    } elsif ($type eq 'child_start' or
             $type eq 'child_exit') {
        # TODO(maybe): Pull the same trick I do with "regions" to add
        # these to the "stack". To them from regions? Also these
        # children have an "argv"...
    } elsif ($type eq 'exec') {
        # TODO(maybe): See child_start/child_exit above.x
    } elsif ($type eq 'cmd_mode') {
        # TODO: There's many of these in theory, but in practice...?
        push @{$es->{cmd_mode}}, $event->{name};
    } elsif ($type eq 'error') {
        # TODO(maybe): group errors encountered somehow?
    } elsif ($type eq 'alias') {
        $es->{alias} = $event->{alias};
        $es->{alias_argv} = $event->{argv};
    } elsif ($debug) {
        $unhandled = 1;
    }

    if ($debug > 1 and $unhandled or $debug > 2) {
        say STDERR $line;
        say STDERR mydump($event);
    }
}

# Fake up the region enter/leave events as if though they're
# subprocesses
FAKE: for my $key (keys %events) {
    my $es = $events{$key};
    next unless my $sid = $es->{sid};

    unless (exists $es->{exit_epoch}) {
        # TODO: There are legitimate missing region_leave events,
        # e.g. if we just die. Some are bugs in git.
        delete $events{$key};;
        next FAKE;
    }

    if (@{$es->{exit_epoch}} < @{$es->{start_epoch}}) {
        # I have not run into this, but the same "missing region_leave
        # events" might happen here
        delete $events{$key};
        next FAKE;
    } elsif (@{$es->{exit_epoch}} > @{$es->{start_epoch}}) {
        die "BUG: More exits than starts? <" . mydump($es) . ">";
    }

    # Fake up the aggregate duration
    @{$es->{$_}} = sort { $a <=> $b } @{$es->{$_}} for qw(start_epoch exit_epoch);
    for my $i (0 .. $#{$es->{start_epoch}}) {
        my $start = $es->{start_epoch}->[$i];
        my $exit = $es->{exit_epoch}->[$i];

        $es->{duration_us} += sprintf "%d", 100_000 * ($exit - $start);
    }

    my $parent_hierarchy = $events{$sid}->{hierarchy};
    $es->{hierarchy} = $parent_hierarchy . '/' . $es->{hierarchy};
}

# We may not see events in order, so any inter-line calculations go
# here
MUNGE: for my $key (keys %events) {
    my $es = $events{$key};

    # Events that aborted on a signal. Fake it up
    if (not exists $es->{exit_code} and exists $es->{signal_signo}) {
        $es->{exit_epoch} = $es->{signal_epoch};
        $es->{exit_code} = $es->{signal_signo};
    }

    unless (exists $es->{duration_us}) { # See "FAKE" above
        if (exists $es->{start_epoch} and exists $es->{exit_epoch}) {
            $es->{duration_us} = sprintf "%d", 100_000 * ($es->{exit_epoch} - $es->{start_epoch});
        } else {
            # TODO: Some of these are bugs in git, some in my state
            # machine...
        }
    }

    # "git" errors do not have a hierarchy,
    # e.g. "GIT_TR2_EVENT=/dev/stderr git". Fake it.
    $es->{hierarchy} = '__error__' if not exists $es->{hierarchy} and $es->{exit_code};
}

# This is purely for the convenience of dumping them out in the
# approximate order they "should" appear in. I.e. ordered by parent
# process creation (first part of the key name) & down the line. I
# don't think the flamegraph code cares, but I manually inspect this
# output sometimes.
my @order = sort { $events{$a} cmp $events{$b} } keys %events;

if ($dump_raw) {
    say mydump(\%events);
    exit;
}

# "Stack" these. I consider "samples" to be "number of microseconds of
# runtime". Can be changed later if we have *actual* samples.
my %stack;
STACK: for my $key (@order) {
    my $es = $events{$key};

    # See TODO above about "git" errors.
    next STACK unless exists $es->{hierarchy};

    # I should always have this, but deal with incomplete data due to
    # testing with a "head -n X" of the data.
    next STACK unless exists $es->{duration_us};

    my $hierarchy = $es->{hierarchy} =~ s[/][;]gr;
    $stack{$hierarchy} += $es->{duration_us};
}

for my $key (sort { $a cmp $b } keys %stack) {
    my $key_human = $key =~ s[$;][/]gr;
    say "$key_human $stack{$key}";
}

sub mydump
{
    require Data::Dumper;
    no warnings 'once';
    local $Data::Dumper::Indent = 1;
    local $Data::Dumper::Terse  = 1;
    use warnings 'once';

    return Data::Dumper::Dumper(@_);
}
