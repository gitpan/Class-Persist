#!perl
use warnings;
use strict;
use Test::More no_plan => 1;
use FindBin;
use Data::Dumper;
use Devel::Peek;

use lib "$FindBin::Bin/lib";
use CPTest;
use ParentTest;

require "$FindBin::Bin/lib/setup_dbs.pl";

test_sub_with_dbs (undef, undef, sub {
  my ($dbh, $name) = @_;

  ok(ParentTest->create_table, "$name: created table ".ParentTest->db_table);
  ok(CPTest->create_table, "$name: created table ".CPTest->db_table);

  # create a simple limb object
  ok( my $limb = ParentTest->new, "new limb" );

  # set a simple property, and store
  ok( $limb->name( "named" ), "named" );
  is( $limb->name, "named", "dave" );
  ok( $limb->store, "stored" );

  # change it..
  ok( $limb->name( "stumpy" ), "oops. Meat grinder accident." );
  is( $limb->name, "stumpy", "yep, it's gone" );

  # ..and revert
  ok( $limb->revert, "medical science is wonderful" );
  is( $limb->name, "named", "dave" );

  ###############################################
  # now life gets more complicated
  ok( my $test = CPTest->new, "created tuit" );
  ok( $limb->one( $test ), "added tuit to limb" );
  ok( $test->colour("red"), "it's red" );
  
  # store the limb, make sure it's propogated
  ok( $limb->store, "stored the limb" );
  ok( $test->_from_db, "tuit was stored" );
  
  # now reset the CPTest
  ok( $test->colour("green"), "now it's green. Drive carefully." );

  # revert the limb
  ok( $limb->revert, "reverting limb" );
  is( $test->colour, "red", "tuit was reverted" );

  ###############################################
  # Ok, even further...
  ok( my $test2 = CPTest->new( colour => "blue" ), "new, blue tuit" );
  ok( $limb->one(undef), "remove the has_a relationship"); # TODO shouln't need to
  ok( $test->store );
  ok( $limb->many->push($test2), "add to collection" );
  ok( $limb->store, "store limb" );
  ok( $test2->_from_db, "tuit was stored" );
  ok( $test2->colour("maroon"), "maroon now." );
  ok( $limb->revert, "reverting limb" );
  is( $test2->colour, "blue", "tuit was reverted" );


  ##################
  # revert with unstored has_a
  
  ok($limb = ParentTest->new->store, "new parent");
  ok($test = CPTest->new, "new unstored child");
  ok( $limb->one( $test ), "part of limb" );
  is( $test->owner, $limb, "child is owned" );

  ok( $limb->revert, "reverted limb" );
  ok( !$limb->one, "no child now" );
  is( $test->owner, undef, "child is not owned" );

  ##################
  # revert with unstored has_many
  
  ok($limb = ParentTest->new->store, "new parent");
  ok($test = CPTest->new, "new unstored child");
  ok( $limb->many->push( $test ), "part of limb" );
  is( $test->owner, $limb, "child is owned" );

  ok( $limb->revert, "reverted limb" );
  ok( !$limb->many->[0], "no child now" );
  is( $test->owner, undef, "child is not owned" );


  ok(CPTest->drop_table, "dropped table");
  ok(ParentTest->drop_table, "dropped table");
});
