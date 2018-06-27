package Finance::Currency::FiatX::Source::bca;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::ger;

use Role::Tiny;
with 'Finance::Currency::FiatX::Role::Source';

sub get_all_spot_rates {
    require Finance::Currency::Convert::KlikBCA;
    my $res = Finance::Currency::Convert::KlikBCA::get_currencies();

    return $res unless $res->[0] == 200;

    my @recs;
    for my $to (sort keys %{ $res->[2]{currencies} }) {
        my $h = $res->[2]{currencies}{$to};
        for (qw/buy sell/) {
            push @recs, (
                {
                    pair => "$to/IDR",
                    type => "${_}_er",
                    rate => $h->{"${_}_er"},
                    note => "$_ e-rate",
                    mtime => $res->[2]{mtime_er},
                },
                {
                    pair => "$to/IDR",
                    type => "${_}_ttc",
                    rate => $h->{"${_}_ttc"},
                    note => "$_ TTC (through-the-counter) rate",
                    mtime => $res->[2]{mtime_ttc},
                },
                {
                    pair => "$to/IDR",
                    type => "${_}_bn",
                    rate => $h->{"${_}_bn"},
                    note => "$_ bank notes rate",
                    mtime => $res->[2]{mtime_bn},
                },
            );
        }
        push @recs, (
            {
                pair => "$to/IDR",
                type => "buy",
                rate => $h->{buy_er},
                note => "=buy_er",
                mtime => $res->[2]{mtime_er},
            },
            {
                pair => "$to/IDR",
                type => "sell",
                rate => $h->{sell_er},
                note => "=sell_er",
                mtime => $res->[2]{mtime_er},
            },
            {
                pair => "IDR/$to",
                type => "buy",
                rate => $h->{sell_er} ? 1/$h->{sell_er} : 0,
                note => "=1/sell_er",
                mtime => $res->[2]{mtime_er},
            },
            {
                pair => "IDR/$to",
                type => "sell",
                rate => $h->{buy_er} ? 1/$h->{buy_er} : 0,
                note => "=1/buy_er",
                mtime => $res->[2]{mtime_er},
            },
        );
    }

    [200, "OK", \@recs];
}

sub get_spot_rate {
    my %args = @_;

    my $from = $args{from} or return [400, "Please specify from"];
    my $to   = $args{to} or return [400, "Please specify to"];
    my $type = $args{type} or return [400, "Please specify type"];

    return [501, "This source only provides buy/sell rate types"]
        unless $type =~ /\A(buy|sell)\z/;
    return [501, "This source only provides IDR/* or */IDR spot rates"]
        unless $from eq 'IDR' || $to eq 'IDR';

    require Finance::Currency::Convert::KlikBCA;
    my $res = Finance::Currency::Convert::KlikBCA::get_currencies();
    return $res unless $res->[0] == 200;

    my $h = $res->[2]{currencies}{$to} || $res->[2]{currencies}{$from};
    return [404, "Cannot find rate for $from/$to"] unless $h;

    my $rate = {
        pair => "$from/$to",
        mtime => $res->[2]{mtime_er},
        type => $type,
    };
    ;
    if ($from eq 'IDR') {
        if ($type eq 'buy') {
            $rate->{rate} = 1/$h->{sell_er};
            $rate->{note} = "1/sell_er";
        } elsif ($type eq 'sell') {
            $rate->{rate} = 1/$h->{buy_er};
            $rate->{note} = "1/buy_er";
        }
    } else {
        if ($type eq 'buy') {
            $rate->{rate} = $h->{buy_er};
            $rate->{note} = "buy_er";
        } elsif ($type eq 'sell') {
            $rate->{rate} = $h->{sell_er};
            $rate->{note} = "sell_er";
        }
    }

    [200, "OK", $rate];
}

sub get_historical_rates {
    return [501, "This source does not provide historical rates"];
}

1;
# ABSTRACT: Get currency conversion rates from BCA (Bank Central Asia)

=for Pod::Coverage ^(.+)$

=head1 DESCRIPTION

Bank Central Asia is one of the largest retail banks in Indonesia.


=head1 SEE ALSO

L<https://bca.co.id>
