#!perl
use warnings;
use strict;
use Test::More no_plan => 1;
use FindBin;

use lib "$FindBin::Bin/lib";
use CPTest;

require "$FindBin::Bin/lib/setup_dbs.pl";

test_sub_with_dbs (undef, undef, sub {
  my ($dbh, $name) = @_;
  Class::Persist->dbh($dbh);

  ok(CPTest->create_table, "$name: created table ".CPTest->db_table);

  foreach my $ord (78, 175, 175, 256) {
    ok(my $test = CPTest->new, "created new test object");

    ok($test->colour(chr $ord), "set Name");
    ok($test->store, "stored object");

    my @all = CPTest->get_all;
    is(scalar(@all), 1, "One object in the database");

    my $got = $all[0];
    my $colour = $got->colour();
    is(length $colour, 1, "1 char");
    is(ord $colour, $ord, "1 char is chr $ord");

    $got->colour(" " . chr $ord);
    ok($got->store, "update stored object");

    @all = CPTest->get_all;
    is(scalar(@all), 1, "Still object in the database");

    $got = $all[0];
    $colour = $got->colour();
    is(length $colour, 2, "2 char");
    is(ord $colour, ord " ", "1st char is a space");
    is(ord (substr $colour, 1), $ord, "2nd char is chr $ord");
    $test->delete();
  }

  my $latin = "bl".chr(233)."u"; # e-acute;
  my $unicode = "bl".chr(195).chr(169)."u";
  use Encode; Encode::_utf8_on($unicode);

  ok( my $test = CPTest->new( colour => $latin ), "created utf8 object" );
  ok( $test->store, "stored" );
  ok( CPTest->load( colour => $latin ), "retrieved based on colour" );
  ok( CPTest->load( colour => $unicode ), "retrieved based on colour" );

  use Storable qw( nfreeze thaw );
  my $brain = { pie => 'tasty', buffy => 'pony' };
  ok( my $frozen = nfreeze( $brain ), "frozen" );
  ok( $test->bin( $frozen ), "set binary" );
  ok( $test->store, "stored" );
  ok( $test->revert, "reverted" );
  ok( my $extracted = thaw( $test->bin ), "thawed binary" );
  is_deeply( $brain, $extracted, "the hashes are the same" );

  ok( CPTest->drop_table );

});
