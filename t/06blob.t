#!perl
use warnings;
use strict;
use lib qw(lib);
use Test::More no_plan => 1;
use FindBin;

use lib "$FindBin::Bin/lib";
use BlobTest;

require "$FindBin::Bin/lib/setup_dbs.pl";

test_sub_with_dbs (undef, undef, sub {
  my ($dbh, $name) = @_;

  isa_ok( BlobTest->new, "Class::Persist::Blob" );
  isa_ok( BlobTest->new, "Class::Persist" );

  ok(BlobTest->create_table, "$name: created table ".BlobTest->db_table);

  ok( my $monkey = BlobTest->new, "Created a new monkey" );
  ok( $monkey->tail("Tail"), "added a tail" );
  ok( $monkey->bananas( 10 ), "given bananas" );
  ok( $monkey->store, "stored" );

  ok( my $new_monkey = BlobTest->load( $monkey->oid ), "loaded a copy" );
  is( $new_monkey->tail, $monkey->tail, "copy has the right tail" );
  is( $new_monkey->bananas, $monkey->bananas, "copy has bananas" );
  ok( $new_monkey->{ears} = 2, "Set private ears on copy" );
  ok( $new_monkey->store, "Store copy" );

  ok( $monkey->revert, "revert original" );
  is( $monkey->{ears}, undef, "original doesn't have private ears" );
});
