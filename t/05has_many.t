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
  ok( $limb->store, "stored" );

  ok( $limb->many, "limb has a tuits collection" );
  ok( !$limb->many->[0], "limb has no zeroth tuit" );

  ok( my $orange = CPTest->new( colour => "orange" ), "created orange CPTest");

  ok( $limb->many->push( $orange ), "added it to the collection" );

  is( $orange->owner->oid, $limb->oid, "CPTest now owned" );
  is( scalar @{$limb->many}, 1, "1 tuit" );
  ok( $limb->store, "stored" );
  is( $orange->owner->oid, $limb->oid, "CPTest now owned" );
  ok( $orange->_from_db, "CPTest now from the DB" );

  is( scalar @{$limb->many}, 1, "1 tuit" );
  ok( $limb->many->load );
  is( scalar @{$limb->many}, 1, "1 tuit" );
  is( ParentTest->load( $limb->oid )->many->count, 1, "1 tuit");

  ok( my $test2 = CPTest->new( colour => "blue" ), "new, blue CPTest" );

  ok( $limb->many->push($test2), "added to collection" );
  
  # store the limb, make sure it's propogated
  ok( $limb->store, "stored the limb" );
  ok( $orange->_from_db, "tuit was stored" );
  ok( $test2->_from_db, "tuit was stored" );

  is( $limb->many->count, 2, "ParentTest has 2 tuits" );

  ok( $limb->many->delete(0), "delete tuit1" );  

  ok( ! $orange->_from_db, "tuit no longer from db" );
  is( $limb->many->count, 1, "ParentTest has 1 tuit" );
  is( $limb->many->[0], $test2, "It's tuit2" );

  ##################################################
  # done
  ok(CPTest->drop_table, "dropped table");
  ok(ParentTest->drop_table, "dropped table");
});
