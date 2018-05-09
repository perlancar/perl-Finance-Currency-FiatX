package Finance::Currency::FiatX;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::ger;

use List::Util qw(max);

our %SPEC;

our %args_db = (
    dbh => {
        schema => ['obj*'],
    },
    table_prefix => {
        schema => 'str*',
        default => 'fiatx_',
    },
);

our %args_caching = (
    max_age_cache => {
        summary => 'Above this age (in seconds), '.
            'we retrieve rate from remote source again',
        schema => 'posint*',
        default => 4*3600,
    },
    max_age_current => {
        summary => 'Above this age (in seconds), '.
            'we no longer consider the rate to be "current" but "historical"',
        schema => 'posint*',
        default => 24*3600,
    },

);

our %args_convert = (
    amount => {
        schema => 'num*',
        default => 1,
    },
    from => {
        schema => 'currency::code*',
        req => 1,
    },
    to => {
        schema => 'currency::code*',
        req => 1,
    },
    type => {
        summary => 'Which rate is wanted? e.g. sell, buy',
        schema => 'str*',
        default => 'sell', # because we want to buy
    },
    # XXX source
);

sub _get_db_schema_spec {
    my $table_prefix = shift;

    +{
        latest_v => 1,
        component_name => 'fiatx',
        provides => ["${table_prefix}rate"],
        install => [
            "CREATE TABLE ${table_prefix}rate (
                 time DOUBLE NOT NULL,
                 currency1 VARCHAR(10) NOT NULL,
                 currency2 VARCHAR(10) NOT NULL,
                 rate DECIMAL(21,8) NOT NULL,         -- multiplier to use to convert 1 unit of currency1 to currency2, e.g. currency1 = USD, currency2 = IDR, rate = 14000
                 source VARCHAR(10) NOT NULL,         -- e.g. KlikBCA
                 type VARCHAR(4) NOT NULL DEFAULT '', -- 'sell', 'buy', or empty
                 note VARCHAR(255)
             )",
            "CREATE INDEX ${table_prefix}rate_time ON ${table_prefix}rate(time)",
        ],
    };
}

sub _init {
    require SQL::Schema::Versioned;

    my ($args) = @_;
    $args->{table_prefix} //= 'fiatx_';
    $args->{max_age_cache} //= 4*3600;
    $args->{max_age_current} //= 24*3600;
    $args->{amount} //= 1;

    my $db_schema_spec = _get_db_schema_spec($args->{table_prefix});

    my $res = SQL::Schema::Versioned::create_or_update_db_schema(
        dbh => $args->{dbh}, spec => $db_schema_spec,
    );
    $res->[0] == 200 or die "Can't initialize FiatX's database schema: $res->[1]";
}

$SPEC{convert_fiat_currency} = {
    v => 1.1,
    summary => 'Convert fiat currency using current rate',
    args => {
        %args_db,
        %args_caching,
        %args_convert,
    },
};
sub convert_fiat_currency {
    my %args = @_;

    _init(\%args);
    my $dbh = $args{dbh};
    my $table_prefix = $args{table_prefix};
    my $max_age_cache = $args{max_age_cache};
    my $max_age_current = $args{max_age_current};

    my $from   = $args{from};
    my $to     = $args{to};
    my $amount = $args{amount};

    # in case user does this
    if ($from eq $to) {
        return [200, "OK (no conversion)", $amount];
    }

    my $now = time();

    my $sth_insert = $dbh->prepare(
        "INSERT INTO ${table_prefix}rate (time, currency1,currency2,rate,type, source,note) VALUES (?, ?,?,?,?, ?,?)"
    );

    my $code_query_db = sub {
        return $dbh->selectrow_hashref(
            "SELECT * FROM ${table_prefix}rate WHERE time >= ? AND currency1=? AND currency2=?".
                ($args{type} ? " AND type=?" : "").
                " ORDER BY time,source,type DESC LIMIT 1", {},
            $now - max($max_age_cache, $max_age_current),
            $from, $to,
            ($args{type} ? ($args{type}) : ()),
        );
    };

    # try local database
    my $row = $code_query_db->();
    if ($row && $now - $row->{time} <= $max_age_cache) {
        # data from local database is recent enough (< max_age_cache),
        # return it
        return [200, "OK (cached)", $amount * $row->{rate}, {
            'func.raw' => $row,
        }];
    }

    # try retrieving rate from remote sources
    my $remote_fail;
  TRY_REMOTE:
    {
      TRY_KLIKBCA:
        {
            my $fre = qr/\A(AUD|EUR|SGD|USD)\z/;
            my $fcur; # foreign currency
            if ($from eq 'IDR' && $to =~ $fre) {
                $fcur = $to;
            } elsif ($to eq 'IDR' && $from =~ $fre) {
                $fcur = $from;
            } else {
                last;
            }
            require Finance::Currency::Convert::KlikBCA;
            log_trace "Getting $fcur-IDR exchange rate from KlikBCA ...";
            my $res = Finance::Currency::Convert::KlikBCA::get_currencies();
            unless ($res->[0] == 200) {
                log_warn "Couldn't get exchange rate from KlikBCA: $res->[0] - $res->[1]";
                last TRY_KLIKBCA;
            }
            my ($sell_er, $buy_er) = ($res->[2]{currencies}{$fcur}{sell_er}, $res->[2]{currencies}{$fcur}{buy_er});
            if (!$sell_er || !$buy_er) {
                log_warn "sell_er and/or buy_er prices are zero or not found, skipping using KlikBCA prices";
                last TRY_KLIKBCA;
            }
            log_trace "Got $fcur-IDR rates from KlikBCA: sell_er=%s=%.8f, buy_er=%.8f", $sell_er, $buy_er;

            my $now = time();
            $sth_insert->execute(
                $now,
                $fcur, "IDR", $sell_er, "sell",
                "KlikBCA", "sell_er",
            );
            $sth_insert->execute(
                $now,
                $fcur, "IDR", $buy_er, "buy",
                "KlikBCA", "buy_er",
            );
            $sth_insert->execute(
                $now,
                "IDR", $fcur, 1/$sell_er, "buy",
                "KlikBCA", "1/sell_er $fcur-IDR",
            );
            $sth_insert->execute(
                $now,
                "IDR", $fcur, 1/$buy_er, "sell",
                "KlikBCA", "1/buy_er $fcur-IDR",
            );
            last TRY_REMOTE;
        } # TRY_KLIKBCA

      TRY_GMC:
        {
            my $fre = qr/\A(AUD|CNY|EUR|GBP|HKD|JPY|MYR|SAR|SGD|USD)\z/;
            my $fcur; # foreign currency
            if ($from eq 'IDR' && $to =~ $fre) {
                $fcur = $to;
            } elsif ($to eq 'IDR' && $from =~ $fre) {
                $fcur = $from;
            } else {
                last;
            }
            require Finance::Currency::Convert::GMC;
            log_trace "Getting $fcur-IDR exchange rate from GMC ...";
            my $res = Finance::Currency::Convert::GMC::get_currencies();
            unless ($res->[0] == 200) {
                log_warn "Couldn't get exchange rate from GMC: $res->[0] - $res->[1]";
                last TRY_GMC;
            }
            my ($sell, $buy) = ($res->[2]{currencies}{$fcur}{sell}, $res->[2]{currencies}{$fcur}{buy});
            if (!$sell || !$buy) {
                log_warn "sell and/or buy prices are zero or not found, skipping using GMC prices";
                last TRY_GMC;
            }
            log_trace "Got $fcur-IDR rates from GMC: sell=%s=%.8f, buy=%.8f", $sell, $buy;

            my $now = time();
            $sth_insert->execute(
                $now,
                $fcur, "IDR", $sell, "sell",
                "GMC", "sell",
            );
            $sth_insert->execute(
                $now,
                $fcur, "IDR", $buy, "buy",
                "GMC", "buy",
            );
            $sth_insert->execute(
                $now,
                "IDR", $fcur, 1/$sell, "buy",
                "GMC", "1/sell $fcur-IDR",
            );
            $sth_insert->execute(
                $now,
                "IDR", $fcur, 1/$buy, "sell",
                "GMC", "1/buy $fcur-IDR",
            );
            last TRY_REMOTE;
        } # TRY_GMC

        # TODO: TRY_ECBDAILY for EUR
        $remote_fail = 1;
    } # TRY

    if ($remote_fail) {
        # return stale data that is still regarded as current
        if ($row) {
            return [200, "OK (older cache)", $amount * $row->{rate}, {
                'func.raw' => $row,
            }];
        } else {
            return [412, "Couldn't query remote source or any recent cached rates"];
        }
    } else {
        $row = $code_query_db->();
        return [500, "Something weird is going on, data in database seems to vanish"]
            unless $row;
        return [200, "OK (queried from remote)", $amount * $row->{rate}, {
            'func.raw' => $row,
        }];
    }
}

1;
# ABSTRACT:

=head1 SYNOPSIS

See L<fiatx> from L<App::fiatx> for an example on how to use this module.


=head1 DESCRIPTION

FiatX is a library/application to convert one fiat currency to another using
several backend modules (C<Finance::Currency::Convert::*>) and store the rates
in L<DBI> database.


=head1 SEE ALSO

C<Finance::Currency::Convert::*> modules.
