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

  ok(CPTest->create_table, "$name: created table ".CPTest->db_table);

  ok( my $orange = CPTest->new( colour => "Orange" )->store, "created CPTest" );
  is ($orange->colour(), 'Orange', "And it's orange");
  ok($orange->_from_db(), "from DB");

  # revert the object, so it's initial state is set up from the DB.
  ok( $orange->revert ); # TODO shoulnd't have to do this.

  is( $orange->peel, "Not Peeled", "Orange not yet peeled" );
  ok( $orange->peel("Fredded"), "Fredded orange" );
  ok( $orange->store, "Stored orange" );
  ok( $orange->revert, "reverted object from database" );
  is( $orange->peel, "Not Peeled", "Orange is not peeled in the DB" );
  ok( $orange->store, "stored" );

  # Pg isn't case preserving.
  ok(my $sth = CPTest->dbh->prepare("SELECT * FROM ".CPTest->db_table." WHERE OI=?"), "getting raw object from DB");
  ok($sth->execute($orange->oid), "executed");
  is($sth->fetchrow_hashref->{peel}, "0", "DB value is '0'");

  ok( $orange->peel("Peeled"), "Peeled orange" );
  is( $orange->peel, "Peeled", "Orange peeled" );
  ok( $orange->store, "Stored orange" );
  is( CPTest->load( $orange->oid )->peel, "Peeled", "Orange is peeled in the DB" );

  ok($sth = CPTest->dbh->prepare("SELECT * FROM ".CPTest->db_table." WHERE OI=?"), "getting raw object from DB");
  ok($sth->execute($orange->oid), "executed");
  is($sth->fetchrow_hashref->{peel}, "1", "DB value is '1'");

  ok(CPTest->drop_table, "dropped table");
});
