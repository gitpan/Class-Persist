#!perl
use warnings;
use strict;
use Test::More no_plan => 1;
use FindBin;
use Data::Dumper;
use Devel::Peek;

use lib "$FindBin::Bin/lib";
use CPTest;

require "$FindBin::Bin/lib/setup_dbs.pl";

test_sub_with_dbs (undef, undef, sub {
  my ($dbh, $name) = @_;

  ok(CPTest->create_table, "$name: created table ".CPTest->db_table);

  ok(my $orange = CPTest->new, "created new test object");
  ok(!$orange->_from_db(), "new test object is not from DB");
  ok($orange->colour('Orange'), "set colour");
  ok($orange->store, "stored object");
  ok($orange->_from_db(), "new test object should now report itself as from DB");
  my $id = $orange->oid();

  ok( ! $orange->owner, "Test not owned by anything" );

  is( $orange->oid, CPTest->load($id)->oid,
    "Loaded object oid is the same as the current object oid");

  is(scalar(CPTest->get_all), 1, "Now one object in the database");

  ok(my $purple = CPTest->new, "created another new test object");
  ok(!$purple->_from_db(), "new test object is not from DB");
  ok($purple->colour('Purple'), "set colour");
  ok($purple->store, "stored object");

  ok($purple->colour([ "purple" ]), "set colour to a list");
  eval { $purple->store };
  ok($@, "error storing object");

  ok($purple->revert, "reverted" );

  is(scalar(CPTest->get_all), 2, "Now two objects in the database");

  ok(my @get = CPTest->search( colour => 'Purple' ), "got search results");
  is(@get, 1, "there's only one result");
  is($purple, $get[0], "it's the purple CPTest");

  is(@get = CPTest->search( colour => 'Grey' ), 0, "No grey many");
  is(@get = CPTest->sql( 'colour = ?', 'Purple' ), 1, "There's a purple one, sure..");
  is(@get = CPTest->sql( 'colour = ?', 'Grey' ), 0, "..but no grey many");

  ok($purple->delete(), "Delete the purple CPTest");
  ok(!($purple->_from_db()), "not longer from DB");
  
  is(scalar(CPTest->get_all), 1, "Now one object in the database");

  ok(@get = CPTest->search( oid => $id ), "got search results for $id");
  is(@get, 1, "there's only one result");

  is(@get = CPTest->advanced_search(
    "SELECT $Class::Persist::ID_FIELD from ".CPTest->db_table.' WHERE colour = ?', 'Grey'
  ), 0, "still no grey many though");

  ok( my $invisible = CPTest->new(), "created invisible CPTest" );
  ok( $invisible->store, "and stored it" );
  is( scalar( CPTest->search( colour => undef ) ), 1, "It can't hide from us, though." );

  ok( $orange->clock( DateTime->now ), "ParentTest clock set to now" );
  ok( $orange->store, "stored" );
  isa_ok( $orange->clock, "DateTime", "Clock still a datetime" );

  sleep 2; # so that now becomes then.
  ok( my $clock = CPTest->load( $orange->oid )->clock, "got the clock");
  isa_ok( $clock, "DateTime");
  ok( $clock < DateTime->now, "what was then now is now then" );

  ok(CPTest->drop_table, "dropped table");
});
