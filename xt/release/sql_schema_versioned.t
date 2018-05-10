#!perl

use 5.010;
use strict;
use warnings;

use Finance::Currency::FiatX;
use Test::More 0.98;
use Test::SQL::Schema::Versioned;
use Test::WithDB;

sql_schema_spec_ok(
    Finance::Currency::FiatX::_get_db_schema_spec("fiatx_"),
    Test::WithDB->new(
        driver => 'mysql',
    ),
);
done_testing;
