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

  ok( my $limb = ParentTest->new->store, "new limb" );
  ok( my $oid = $limb->oid, "got oid" );

  is( $limb, ParentTest->load( $oid ), "ParentTest is unique" );

  ok(my $proxy = Class::Persist::Proxy->proxy($limb), "proxied limb");
  is( $proxy, $limb, "limb is now the proxy" );
  ok( $proxy->load, "loaded proxy" );
  is( $proxy, $limb, "limb is still the proxy" );

  $proxy = Class::Persist::Proxy->new( class => "ParentTest" , real_id => $oid );
  is( $proxy, $limb, "asked for proxy, got limb" );



  ok( my $cache = $limb->_object_cache, "got cache" );
  isa_ok( $cache, "Class::Persist::Cache" );

  ok( my $empty = Class::Persist::Proxy->new( _empty_proxy => 1 ), "created empty proxy" );
  ok( $empty->class( "ParentTest" ), "set class" );
  ok( $empty->real_id( $oid ), "set oid" );
  isnt( $empty, $limb, "it's not the limb object" );
  ok( my $stored = $cache->store( $empty ), "asked to store it" );
  is( $stored, $limb, "Stored thing _is_ limb" );

  # error checking
  eval { $cache->store("string") };
  isa_ok( $@, "Class::Persist::Error" );
  isa_ok( $@, "Class::Persist::Error::Cache" );
  is($@->text, "a scalar is not a Class::Persist object", "right error" );

  eval { $cache->store(["array"]) };
  isa_ok( $@, "Class::Persist::Error" );
  isa_ok( $@, "Class::Persist::Error::Cache" );
  is($@->text, "ARRAY is not a Class::Persist object", "right error" );

  eval { $cache->get() };
  isa_ok( $@, "Class::Persist::Error" );
  isa_ok( $@, "Class::Persist::Error::Cache" );
  is($@->text, "No id", "right error" );

  eval { $empty->load };
  ok( $@, "can't load empty in place" );
  isa_ok( $@, "Class::Persist::Error" );
  isa_ok( $@, "Class::Persist::Error::Cache" );
  is($@->text, "Object $limb already stored", "right error" );
  
  ok(CPTest->drop_table, "dropped table");
  ok(ParentTest->drop_table, "dropped table");

});
