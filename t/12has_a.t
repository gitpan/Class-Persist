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

  # create a simple Parent object
  ok( my $parent = ParentTest->new, "new Parent" );
  ok( $parent->store, "stored" );

  ok( !$parent->one, "Parent has no has_a child" );

  ok( my $orange = CPTest->new( colour => "orange" ), "created orange CPTest");

  ok( $parent->one( $orange ), "added it to the has_a field" );

  is( $orange->owner, $parent, "child now owned" );
  ok( $parent->store, "stored" );
  is( $orange->owner, $parent, "child now owned" );
  ok( $orange->_from_db, "child from db" );

  Class::Persist::Cache->instance->proxy_all;

  TODO: {
    local $TODO = "multiple child relationships with a class break";
    is( scalar @{$parent->many}, 0, "no tuits in has_many relationship" );
  }


  ok(CPTest->drop_table, "dropped table");
  ok(ParentTest->drop_table, "dropped table");
});
