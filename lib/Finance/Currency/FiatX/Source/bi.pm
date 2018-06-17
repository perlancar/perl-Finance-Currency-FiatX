package Finance::Currency::FiatX::Source::bi;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::ger;

sub get_all_spot_rates {
    require Finance::Currency::Convert::BI;
    my $res = Finance::Currency::Convert::BI::get_currencies();

    return $res unless $res->[0] == 200;

    my @recs;
    for my $to (sort keys %{ $res->[2]{currencies} }) {
        my $h = $res->[2]{currencies}{$to};
        push @recs, (
            {
                pair => "$to/IDR",
                type => "buy",
                price => $h->{buy},
                mtime => $res->[2]{mtime},
            },
            {
                pair => "$to/IDR",
                type => "sell",
                price => $h->{sell},
                mtime => $res->[2]{mtime},
            },
            {
                pair => "IDR/$to",
                type => "buy",
                price => 1/$h->{sell},
                note => "1/sell",
                mtime => $res->[2]{mtime},
            },
            {
                pair => "IDR/$to",
                type => "sell",
                price => 1/$h->{buy},
                note => "1/buy",
                mtime => $res->[2]{mtime},
            },
        );
    }

    [200, "OK", \@recs];
}

sub get_spot_rate {
    my ($from, $to, $type) = @_;

    return [412, "This source only provides buy/sell rate types"]
        unless $type =~ /\A(buy|sell)\z/;
    return [412, "This source only provides IDR/* or */IDR spot rates"]
        unless $from eq 'IDR' || $to eq 'IDR';

    require Finance::Currency::Convert::BI;
    my $res = Finance::Currency::Convert::BI::get_currencies();
    return $res unless $res->[0] == 200;

    my $h = $res->[2]{currencies}{$to} || $res->[2]{currencies}{$from};
    return [404, "Cannot find rate for $from/$to"] unless $h;

    my $rate = {
        pair => "$from/$to",
        mtime => $res->[2]{mtime},
        type => $type,
    };
    ;
    if ($from eq 'IDR') {
        if ($type eq 'buy') {
            $rate->{price} = 1/$h->{sell};
            $rate->{note} = "1/sell";
        } elsif ($type eq 'sell') {
            $rate->{price} = 1/$h->{buy};
            $rate->{note} = "1/buy";
        }
    } else {
        if ($type eq 'buy') {
            $rate->{price} = $h->{buy};
            $rate->{note} = "buy";
        } elsif ($type eq 'sell') {
            $rate->{price} = $h->{sell};
            $rate->{note} = "sell";
        }
    }

    [200, "OK", $rate];
}

sub get_historical_rate {
    return [501, "Getting historical rate not yet supported"];
}

1;
# ABSTRACT: Get currency conversion rates from BI (Bank Indonesia)

=head1 DESCRIPTION

Bank Indonesia is Indonesia's central bank.


=head1 SEE ALSO

L<https://www.bi.go.id>
