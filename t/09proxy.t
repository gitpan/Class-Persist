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
  isa_ok( $limb, "ParentTest" );
  ok( my $oid = $limb->oid, "got oid" );

  ok(my $proxy = Class::Persist::Proxy->proxy($limb), "proxied limb");

  isa_ok( $proxy, "Class::Persist::Proxy" );
  is( $proxy->oid, $oid, "same oid");
  is( $proxy, $limb, "it's still the same object, even" );

  # bad method calls on the proxy should look exactly like bad method calls
  # on the real object.
  ok(! eval { $proxy->bob }, "Can't call bob");
  my $error = $@;
  like($error, qr/Can't locate object method "bob"/, "Throws the right sort of error");

  ok(! eval { $limb->bob }, "Can't call bob on real objecct");
  my $error2 = $@;
  $error =~ s/\d+\.?$//; # trim line number
  $error2 =~ s/\d+\.?$//; # trim line number
  is($error, $error2, "Throws the same error");

  # limb was inflated by the bad call
  isa_ok( $proxy, "ParentTest" );
  is( $proxy->oid, $oid, "same oid");

  # add a child to test recursiveness
  ok( my $test = CPTest->new, "Created a tuit" );
  ok( $limb->one( $test ), "Added tuit to limb" );
  ok( $limb->store, "Stored limb" );
  
  # CPTest is still a tuit, even after the store.
  isa_ok( $limb->one, "CPTest");
  ok(Class::Persist::Proxy->proxy($limb), "proxied limb");

  ok( Class::Persist::Cache->instance->proxy_all, "proxied the cache" );

  # inflating the limb doesn't inflate it's children
  isa_ok( $limb, "Class::Persist::Proxy");
  isa_ok( $limb->one, "Class::Persist::Proxy");
  isa_ok( $limb, "ParentTest");

  # error checking
  eval { Class::Persist::Proxy->new };
  isa_ok( $@, "Class::Persist::Error" );
  isa_ok( $@, "Class::Persist::Error::Proxy" );
  is($@->text, "Proxies need class and real_id", "right error" );

  eval { Class::Persist::Proxy->new( class => "xxx", real_id => 1 ) };
  isa_ok( $@, "Class::Persist::Error" );
  isa_ok( $@, "Class::Persist::Error::Proxy" );
  is($@->text, "Class xxx does not exist", "right error" );

  my $p = Class::Persist::Proxy->new( class => "ParentTest", real_id => 1 );
  eval { $p->load };
  isa_ok( $@, "Class::Persist::Error" );
  isa_ok( $@, "Class::Persist::Error::Proxy" );
  is($@->text, "Can't load object with class ParentTest, oid 1", "right error" );

  eval { Class::Persist::Proxy->proxy( "string" ) };
  isa_ok( $@, "Class::Persist::Error" );
  isa_ok( $@, "Class::Persist::Error::Proxy" );
  is($@->text, "object to proxy should be a Class::Persist, not a scalar", "right error");


  ok(CPTest->drop_table, "dropped table");
  ok(ParentTest->drop_table, "dropped table");

});
