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

# weaken the reference in the ParentTest class
ParentTest->weak_reference(qw( one ));

require "$FindBin::Bin/lib/setup_dbs.pl";

test_sub_with_dbs (undef, undef, sub {
  my ($dbh, $name) = @_;

  ok(ParentTest->create_table, "$name: created table ".ParentTest->db_table);
  ok(CPTest->create_table, "$name: created table ".CPTest->db_table);

  ok( my $orange = CPTest->new( colour => "Orange" ), "created CPTest" );
  is ($orange->colour(), 'Orange', "And it's orange");
  ok(!$orange->_from_db(), "from DB");

  ok( my $parent = ParentTest->new );
  ok( $parent->one( $orange ), "added orange" );
  
  is( $orange->owner, undef, "orange not owned" );

  ok( $parent->store );

  ok( $parent->_from_db, "parent from db" );
  ok( !$orange->_from_db, "orange not from db" );

  ok(CPTest->drop_table, "dropped table");
});
