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
  ok( $limb->name( "arm" ), "Call it an arm" );
  is( $limb->name, "arm", "arms are great" );
  ok( $limb->store, "stored" );

  ok( my $limb2 = $limb->clone, "cloned the arm. Medicine is wonderful." );

  isnt( $limb, $limb2, "not the same object" );
  isnt( $limb->oid, $limb2->oid, "not the same oid" );
  is( $limb2->name, $limb->name, "has same properties" );

  ###############################################
  # now life gets more complicated
  ok( my $red = CPTest->new( colour => "red" ), "created red CPTest" );
  ok( $limb->one( $red ), "added tuit to limb" );
  
  # store the limb, make sure it's propogated
  ok( $limb->store, "stored the limb" );
  ok( $red->_from_db, "tuit was stored" );
  
  ok( $limb2 = $limb->clone, "cloned" );
  ok( !$limb2->_from_db, "clone not from the DB" );

  ok ($limb2->one, "clone has a tuit" );
  ok( !$limb2->one->_from_db, "cloned tuit not from the DB" );
  isnt( $limb->one->oid, $limb2->one->oid, "a different tuit" );
  is( $limb->one->colour, $limb2->one->colour, "but the same colour" );

  ###############################################
  # Ok, even further...
  ok( my $red2 = CPTest->new( colour => "blue" ), "new, blue CPTest" );
  ok( $limb->many->push($red2), "add to collection" );
  ok( $limb->store, "store limb" );
  ok( $red2->_from_db, "tuit was stored" );
  ok( $red2->colour("maroon"), "maroon now." );

  ok( $limb2 = $limb->clone, "cloned" );

  ok ($limb2->many, "clone has a tuit collection" );
  is( $limb2->many->count, 1, "1 tuit" );
  ok( !$limb2->many->[0]->_from_db, "cloned tuit not from the DB" );
  isnt( $limb->many->[0]->oid, $limb2->many->[0]->oid, "a different tuit" );
  is( $limb->many->[0]->colour, $limb2->many->[0]->colour, "but the same colour" );

  is( $limb->many->[0]->owner, $limb, "limb tuit[0] has rifght owner" );
  is( $limb2->many->[0]->owner, $limb2, "limb2 tuit[0] has right owner" );
  


  ##################################################
  # done
  ok(CPTest->drop_table, "dropped table");
  ok(ParentTest->drop_table, "dropped table");
});
