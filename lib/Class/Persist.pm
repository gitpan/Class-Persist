=head1 NAME

Class::Persist - Persistency framework for objects

=head1 SYNOPSIS

  package My::Person;
  use base qw( Class::Persist );
  Class::Persist->dbh( $dbh );
  __PACKAGE__->simple_db_spec(
    first_name => 'CHAR(30)',
    last_name  => 'CHAR(30)',
    address => "My::Address",  # has_a relationship
    phones => [ "My::Phone" ], # has_many relationship
  );

  my $person = My::Person->new( first_name => "Dave" );
  $person->addesss( My::Address->new );
  $person->store;


=head1 DESCRIPTION

Provides the framework to persist the objects in a DB in a Class::DBI
style. The main difference between Class::Persist and Class::DBI is that
Class::DBI provides an object wrapper around a row in a database,
typically a database that already exists. The purpose of Class::Persist
is to store an object, or a tree / collection of objects in a database,
without worrying too much about what the database looks like. The other
difference is that it's possible to have a Class::Persist object that
does B<not> come from a database - Class::DBI objects always represent an
existing db row.

Class::Persist is not Pixie or another 'magic' persistence layer - the
properties of your object go into real database columns, and you need to
know a bit about databases, with the attendant advantage that you can
use SQL to search the database for objects.

=head1 USAGE

In its simplest form, to make a package persistable, inherit from
Class::Persist, and call L<simple_db_spec> on your package name to tell
Class::Persist what bits of your object you would like to store, and
what sort of DB fields you would like to store them in. Use the
setup_DB_infrastructure and create_table methods to create the database
tables for your objects in the setup code for your application. Then,
call L<dbh> on the Class::Persist package to set the global database
connection for all Class::Persist objects, and your objects are now
persistable.

  package My::Foo;
  use base qw( Class::Persist );
  Class::Persist->dbh( $dbh );
  My::Foo->simple_db_spec( name => "CHAR(30)" );

If you need to have more than one Class::Persist database, you can
subclass Class::Persist through a middle class that defines your
application-specific database connection, and have your persistable
classes inherit from that:

  package My::Persistable;
  use base qw( Class::Persist );
  My::Persistable->dbh( $dbh );

  package My::Bar
  use base qw( My::Persistable );
  My::Bar->simple_db_spec( name => "CHAR(30)" );

Objects will be assigned a table name automatically based on their class
name - if you prefer to choose table names explicitly, use the
L<db_table> method.

  My::Bar->db_table( "table_bar" );

=head2 Subclassing

You can subclass other persistable objects to create new objects, which
share the properties of their superclasses, and can add fields. They are
stored in seperate database tables, but inherit the column types from
their superclass.

  package My::Baz;
  use base qw( My::Bar );
  My::Baz->simple_db_spec( height => "INT" );

=head2 Relationships

You can trivially define relationships with other classes by putting a
class name in the 'data type' part of the db spec.

  My::Wallace->simple_db_spec( bar => "My::Bar" );
  my $wallace = My::Wallace->new;
  my $bar = My::Bar->new;
  $wallace->bar( $bar );
  $wallace->store;

An object can have a listref of other persistable objects stored in a
property, by passing a listref with the property name as the data type.

  My::Grommit->simple_db_spec( bars => ["My::Bar"] );
  my $grommit = My::Grommit->new;
  my $bar = My::Bar->new;
  push @{ $grommit->bar }, $bar;

or

  $grommit->bar->push( $bar );

See the documentation for L<simple_db_spec> for more details of how to
define relationships.

=head2 Setup

To create the database tables for the objects you have defined, call
L<create_table> on each of them in turn.

  My::Foo->create_table;
  My::Bar->create_table;
  My::Baz->create_table;

If you subsequently change the layout of the database by changing the
object spec, you will have to either delete and re-create the tables,
losing all the data, or change the table definition yourself manually.

=head2 Storing and retrieving objects

All objects inheriting from Class::Persist have an 'oid' method that
returns the unique id of the object, this will be a UUID - a unique
non-guessable 36 character string. The simplest way to retrieve an
object is by its oid:

  my $bar = My::Bar->load( $oid );

Alternatively, the two-parameter version of load is useful if you can rely
on some other unique value in the object:

  my $bar = My::Bar->load( name => "The Founder's Arms" );

You can search for objects using methods of varying sophistication

  # get all the bars.
  my @bars = My::Bar->get_all;

  # get bars where the 'color' property is equal to 'Green'
  my @green_bars = My::Bar->search( color => "Green" );

  # get bars where the color contains an 'e'
  my @some_bars = My::Bar->sql("color like ?", "%e%");

See the L<search>, L<sql> and L<advanced_search> methods for
increasingly complicated ways of searching the database for objects.


=head1 OBJECT CREATION

The standard way of creating an object is with the new() method. new()
optionally takes a hash of key/value pairs to populate the initial state
of the object.

=head1 PROPERTIES

All Class::Persist subclasses inherit certain properties from the superclass.

=head2 creation_date()

A L<DateTime> object for when this object was originally created. Should
be considered read-only.

=head2 timestamp()

A L<DateTime> object that represents the last time this object was stored into
the database.

=head2 owner()

If the object is owned, ie it is the target of a has_a, has_many, etc
relationship, the owner method will return the object's owner.

=cut

package Class::Persist;
use strict;
use warnings;

use Class::ISA;
use DateTime;
use Scalar::Util qw(blessed);
use DBI qw(:sql_types);
use Storable qw();
use Error qw(:try);

use Class::Persist::Cache;
use Class::Persist::Proxy;
use Class::Persist::Collection;
use base qw(Class::Persist::Base);

our $VERSION = '0.30';

# This is the name of the DB field that contains the primary ID of the
# object. It's changable because postgres considered what we used to use
# a reserved word, and it was so hard changing it, I never want to do
# it again.
# TODO - it would be really cool if this was a Class::Data::Inheritable
# and classes could pick their own id field name. This might be (a) insane,
# and (b) very hard, however.
# better TODO - just make it 'id', damnit. It's portable.
our $ID_FIELD = "OI";

# Indicates yes/no if we're on a postgres db. note that the
# postgres stuff is untested by the developers for the most part. Patches with
# more tests that show up postgres portability issues most welcome
sub postgres {
  my $self = shift;
  my $dbh = $self->dbh();
  throw Class::Persist::Error::DB::Connection -text => "no dbh"
    unless defined $dbh;
  my $dbname = $dbh->{Driver}{Name};
  $dbname eq 'Pg';
}

our %SQL; # sql cache
our %SCHEME; # mapping class <=> db

# I like Class::Data::Inheritable. Every class can define its own dbh that will
# apply to itself and its subclasses. If they don't define it, they'll use
# the global Class::Persist one.
Class::Persist->mk_classdata('dbh');

# All persistable objects inherit from Class::Persist, and will inherit these
# database fields.
__PACKAGE__->simple_db_spec(
  $ID_FIELD => "CHAR(36) PRIMARY KEY",
  timestamp => "TIMESTAMP",
  creation_date => "DateTime",
  owner => "CHAR(36)",
);
__PACKAGE__->mk_accessors(qw( _from_db creation_date timestamp owner_class owner_oid ));

# Define the exceptions we will throw in various circumstances.
Class::Persist::Base->define_error_class("Class::Persist::Error::DB");
Class::Persist::Base->define_error_class($_, "Class::Persist::Error::DB") for (qw(
  Class::Persist::Error::DB::Connection
  Class::Persist::Error::DB::Request
  Class::Persist::Error::DB::NotFound
  Class::Persist::Error::DB::Duplicate
  Class::Persist::Error::DB::UTF8
  Class::Persist::Error::StoreReference
  Class::Persist::Error::Revert
));


=head1 RETRIEVING OBJECTS

=head2 load( id ), load( key => value )

Loads an object from the database. Can be used in two different ways.

=over 4

=item My::Class->load( $id )

Loads the unique item of the class My::Class with the oid $id.

=item My::Classs->load( foo => "Bar" )

Loads the first item of class My::Classs where the property 'foo' is
equal to 'bar'.

=back

=cut

sub load {
  my $class = shift;
  # If it is an instance call, replace by loaded object
  if (ref $class) {
    my $real_class = ref $class;
    my $self = $real_class->_load( $ID_FIELD => $class->oid ) or return;
    $class->_same_as($self) or return;
    return $class->_duplicate_from($self);
  }
  $class->_load_class(@_);
}

# This could probably do with a better name.
# The tracker class goes direct to this part of loading. Real (user) instance
# objects go through load as above.

sub _load_class {
  my $class = shift;
  # Class call

  # load by owner for might_have relationships
  if (blessed( $_[0] )) {
    my $self = $class->_load( owner => $_[0]->oid ) or return;
    $self->owner($_[0]);
    return $self;
  }

  $class->_load($ID_FIELD, @_);
}


sub _load {
  my $class   = shift;

  my $id      = pop
    or Class::Persist::Error::InvalidParameters->record(
      -text => "Need an id to load object") and return;

  my $idField = pop
    or Class::Persist::Error::InvalidParameters->record(
      -text => "Need an id to load object") and return;

  $idField = $Class::Persist::ID_FIELD if ($idField eq 'oid');

  my (@got) = $class->sql("$idField=?", $id);
  
  unless ( @got ) {
    Class::Persist::Error::DB::NotFound->record( -text => "can't load");
    return;
  }

  $got[0];
}

=head2 get_all()

Returns a list of all the objects of this class in the database.

=cut

sub get_all {
  my $class = shift;
  return $class->search();
}

=head2 search( column => "value" )

Takes a hash of attribute=>value pairs. Values of undef become IS NULL tests.
Returns a list of objects in the database of this class which match these
criteria.

  my $pears = Fruit->search( shape => 'pear' );

The special parameter 'order_by' will not be used as part of the search, but
will order the results by that column.

  my $sorted_pears = Fruit->search( shape => 'pear', order_by => 'size' );

=cut

sub search {
  my $class = shift;
  my $param = ref($_[0]) ? $_[0] : { @_ };

  $param->{ $Class::Persist::ID_FIELD } = delete $param->{oid}
    if exists $param->{oid};

  for (values(%$param)) {
    $_ = $_->oid if (blessed($_));
  }

  my $order_by = delete($param->{order_by});
  $order_by = $ID_FIELD if (defined($order_by) and $order_by eq 'oid'); # ick
  
  my $sql = "";
  if (keys(%$param)) {
    $sql = join( " AND ", map {
      defined($param->{$_}) ? "$_ = ?" : "$_ IS NULL"
    } keys(%$param) );
  } else {
    $sql = "1=1";
  }
  $sql .= ' ORDER BY '.$order_by if $order_by;

  return $class->sql( $sql, values(%$param) );
}


=head2 sql( sql, [placeholder values] )

Free-form search based on a SQL query. Returns a list of objects from the
database for each row of the passed SQL 'WHERE' clause. You can use placeholders
in this string, passing the values for the placeholders as the 2nd, etc, params

  Person->sql("name LIKE '%ob%' AND age > ? ORDER BY height", $min_age)

=cut

# implementation note - _ALL_ object access is done through this method.

sub sql {
  my $class = shift;
  my $query = shift;
  my $dbh   = $class->dbh;
  my $table = $class->db_table;
  my @fields = $class->db_fields_all;

  # We have to go through this game of selecting all the fields explicitly
  # (and in a known order) rather than simply using fetchrow_arrayref because
  # DBD::Pg appears not to be case-preserving the column names.
  # Without doing this tests will fail on Pg when attributes are not all lower
  # case.
  my $sql   = "SELECT " . join (',', @fields) . " FROM $table";

  if ($query) {
    $sql .= " WHERE $query";
  }

  my $r = $dbh->prepare_cached($sql)
    or throw Class::Persist::Error::DB::Request->throw(
      -text => "Could not prepare $sql - $DBI::errstr");

  my @placeholders = grep { defined($_) } @_;
  utf8::encode $_ foreach @placeholders;

  $r->execute( @placeholders )
    or Class::Persist::Error::DB::Request->throw(
      -text => "Could not execute $sql - $DBI::errstr");

  my @return;

  # Do this out here to avoid recreating hash each time.
  my %temp;
  my $binary = $class->binary_fields_all_hash();

  while (my $row = $r->fetchrow_arrayref()) {
    @temp{@fields} = @$row;
    # Do it this way round to avoid a bug in DBI, where DBI doesn't reset
    # the utf8 flag on the array it reuses for fetchrow_arrayref
    # We're now doing it here on copies of the data
    for (keys(%temp)) {
      next if $binary->{$_};
      unless (utf8::decode($temp{$_})) {
        Class::Persist::Error::DB::UTF8->throw(
          -text => "Non-utf8 data in column $_ returned by $sql");
      }
    }
    my $object;
    if ($class->_object_cache) {
      $object = $class->_object_cache->get( $temp{ $Class::Persist::ID_FIELD } );
    }
    if (! $object or $object->isa("Class::Persist::Proxy")) {
      $object = $class->new()
                      ->_populate(\%temp) # populate the object
                      ->_from_db(1); # and mark as from db
      $object = $class->_object_cache->store($object) if $class->_object_cache;
    }
    push(@return, $object);
  }

  $r->finish();

  return @return;
}

=head2 advanced_search( ... )

when search() isn't good enough, and even sql() isn't good enough, you
want advanced_search. You pass a complete SQL statement that will return
a number of rows. It is assumed that the left-most column will contain
oids. These oids will be inflated from the database and returned in a
list.

As with the sql method, you can use placeholders and pass the values as
the remaining parameters.

  People->advanced_sql('
    SELECT artist.oid FROM artist,track
    WHERE track.artist_name = artist.name
    AND track.length > ?
    ORDER BY artist.name',
  100 );

This will be slower than sql - there will be another SQL query on the db
for every row returned. That's life. There is much scope here for
optimization - the simplest thing to do might be to return a list of
proxies instead..

Also consider that the SQL statement you're passing will be just thrown
at the database. You can call Object->advanced_sql('DROP DATABASE
people') and bad things will happen. This is, of course, almost equally
true for the sql method, but it's easier to break things with this one.

=cut

sub advanced_search {
  my $class = shift;
  my $sql = shift;

  my $dbh   = $class->dbh;

  my $r = $dbh->prepare_cached($sql)
    or Class::Persist::Error::DB::Request->throw(
      -text => "Could not prepare $sql - $DBI::errstr");

  my @placeholders = grep { defined($_) } @_;
  utf8::encode $_ foreach @placeholders;

  $r->execute( @placeholders )
    or Class::Persist::Error::DB::Request->throw(
      -text => "Could not execute $sql - $DBI::errstr");

  my @return;

  # Do this out here to avoid recreating hash each time.
  my %row;
  while (my $row = $r->fetchrow_arrayref()) {
    my $oid = $row->[0];
    push( @return, $class->load($oid) );
  }

  $r->finish();

  return @return;
}


=head1 OBJECT METHODS

=head2 store()

Store the object in DB and all objects within, whether it is a new object or
an update. Storing an object will collapse all its relationships with other
Class::Persist object into proxies.

=cut

sub store {
  my $self = shift;

  $self->_check_store(@_) or return; # check_store records errors;

  $self->_store_might_have() or return;
  $self->_store_has_many() or return;

  if ($self->_from_db) {
    $self->_db_update() or return;
  }
  else {
    $self->_db_insert() or return;
  }
  $self->_from_db(1);

  return $self;
}

sub _store_might_have {
  my $self = shift;
  foreach my $key ( keys %{ $self->might_have_all } ) {
    next if $self->weak_reference_all->{$key}; # not the weak refs
    my $obj = $self->get($key) or next;
    next if $obj->isa('Class::Persist::Proxy');
    $obj->isa('Class::Persist')
      or Class::Persist::Error->throw(-text => "Object not a Class::Persist");
    $obj->owner( $self );
    $obj->store() or return;
    Class::Persist::Proxy->proxy($obj);
  }
  $self;
}

sub _store_has_many {
  my $self = shift;
  foreach my $key ( keys %{ $self->has_many_all } ) {
    next if $self->weak_reference_all->{$key}; # not the weak refs
    my $obj = $self->get( $key ) or die;
    $obj->isa('Class::Persist::Collection')
      or Class::Persist::Error->throw(-text =>
                                      "Object not a Class::Persist::Collection");
    $obj->owner( $self );
    $obj->store() or return;
  }
  $self;
}

# turn the oid of the owner, as stored in the DB, into an oid and a class
sub db_inflate_owner {
  my ($self, $db) = @_;
  return undef unless defined($db);

  # every proxy needs a classname, so it knows where to get its DBH.
  my $class = $self->get("owner_class");

  # Look in the object cache for something with the right id.
  if (!$class and $self->_object_cache) {
    my $object = $self->_object_cache->get( $db );
    if ($object) {
      if ($object->isa("Class::Persist::Proxy")) {
        $class = $object->class;
      } else {
        $class = ref($object);
      }
    }
  }

  # otherwise, we fall back to expensive stuff
  if (!$class) {
    $class = $self->_class_for_oid( $db );
  }

  unless ($class) {
    Class::Persist::Error::DB::NotFound->throw(
      -text => "Can't get class for owner $db");
  }

  $self->owner_class( $class );
  $self->owner_oid( $db );
}

# this is expensive, but relatively rare - most of the time we'll have
# been able to pull the owner out of the object cache, this is a last-
# resort method.
sub _class_for_oid {
  my ($self, $oid) = @_;
  for my $class (keys( %SCHEME )) {
    Class::Persist::Error->throw(-text => "No dbh for class $class" )
      unless $class->dbh;
    my $sth = $class->dbh->prepare(
      "SELECT COUNT(*) FROM ".$class->db_table." WHERE $ID_FIELD=?");
    $sth->execute($oid);
    if ($sth->fetchrow_arrayref->[0]) {
      return $class;
    }
  }
  Class::Persist::Error::DB::NotFound->throw(
    -text => "object $oid not found");
}

sub db_deflate_owner {
  my ($self) = @_;
  return $self->get("owner_oid");
}

sub owner {
  my $self = shift;
  if (@_) {
    my $owner = shift;
    # TODO - isn't _setting_ an owner from user code INCREDIBLY DANGEROUS?
    # we need to think about the whole re-parenting issue lots.

    if (defined($owner)) {

      Class::Persist::Error->throw( -text => "Not a class persist object" )
        unless blessed($owner) and $owner->isa("Class::Persist::Base");
  
      # setting a proxy as the owner? Inflate it.
      $owner = $owner->load if ($owner->isa("Class::Persist::Proxy"));
  
      # record the class of the owner, the oid of the owner only.
      # We can reconstruct a proxy that points at the owner very easily
      $self->set( owner_class => ref($owner) );
      $self->set( owner_oid => $owner->oid );

    } else {
      # we're un-setting the owner
      $self->set( owner_class => undef );
      $self->set( owner_oid => undef );
      
    }
    return $self;
  }

  # neither class nor oid? No owner, then.
  return undef unless ($self->owner_class or $self->owner_oid);
  
  # make a proxy for the owner from the stored class and oid. The Proxy
  # class takes care of returning the real thing if the object cache
  # knows about it.
  Class::Persist::Error->throw( -text => "No owner class" )
    unless $self->get("owner_class");
  Class::Persist::Error->throw( -text => "No owner oid" )
    unless $self->get("owner_oid");

  return Class::Persist::Proxy->new( class => $self->get("owner_class"),
                                     real_id => $self->get("owner_oid"),
                                  );
}

sub _check_store {
  my $self = shift;
  $self->validate()
    or Class::Persist::Error::InvalidParameters->record(
      -text => "validation of $self failed") and return;
  $self->unique()
    or Class::Persist::Error::DB::Duplicate->record(
      -text =>  "duplicate of $self found") and return;
  1;
}



=head2 delete()

Deletes the object and returns true if successful.
It will delete recursively all objects within.

=cut

sub delete {
  my $self = shift;
  unless ($self->_from_db) {
    Class::Persist::Error->record( -text => "Can't delete a non stored object");
    return;
  }

  # recursively delete the members of the object.
  foreach my $method ($self->_all_relationships) {
    next if $self->weak_reference_all->{$method}; # not the weak ones
    my $obj = $self->get( $method ) or next;
    $obj->delete() or return;
  }

  # now delete me.
  $self->deleteThis();
}


=head2 deleteThis()

Deletes the object from the DB, and returns true if successful.
Does not delete recursively any objects within, so this method
will leave orphans.

=cut

sub deleteThis {
  my $self  = shift;
  my $sql   = "DELETE FROM ".$self->db_table." WHERE $ID_FIELD=?";
  my $r = $self->dbh->prepare_cached($sql)
    or Class::Persist::Error::DB::Request->throw(
      -text => "Could not prepare $sql - $DBI::errstr");
  $r->execute($self->oid)
    or Class::Persist::Error::DB::Request->throw(
      -text => "Could not execute $sql - $DBI::errstr");
  $r->finish;
  $self->_from_db(0);
}

=head2 revert()

revert an object back to its state in the database. You will lose any changes
you've made to it since the last store. This is recursive - all children of the
object will be reverted as well.

Throws a Class::Persist::Error::Revert if the object you're trying to revert
isn't stored in the database.

=cut

sub revert {
  my $self = shift;
  Class::Persist::Error::Revert->throw( -text => "Can't revert a non stored object")
    unless $self->_from_db;

  # recursive
  foreach my $method ($self->_all_relationships) {
    next if $self->weak_reference_all->{$method}; # not the weak ones
    my $obj = $self->get( $method ) or next;
    try {
      $obj->revert() or return;
    } catch Class::Persist::Error::Revert with {
      # this happens if the object isn't in the DB. But we're reverting
      # _us_, so the DB state here must be that we don't have a relationship
      # with that object.
      $self->$method(undef);
    }
  }

  $self->revertThis;
}

=head2 revertThis()

Revert only this object to its DB state, not any of its children.

=cut

sub revertThis {
  my $self = shift;

  # I shouldn't do this, instead we need a way of forcing an actual load of the
  # DB object.
  $self->_object_cache->remove($self);

  my $reverted = ref($self)->_load( $ID_FIELD => $self->oid )
    or Class::Persist::Error::DB->throw(-text =>
                                        "No object with that oid in DB");

  # load will have put $reverted in the store. We don't want that - we want
  # _us_ in there.
  $self->_object_cache->remove($reverted);

  return $self->_duplicate_from($reverted);
}

=head2 clone( new_owner )

Deep-clones the object - any child objects will also be cloned. All new objects
will have new oids, and will not be stored in the database. Unlike delete
and revert, clone is B<not> depth-first.

new_owner will own the newly cloned object, if passed. If not, the new
object will have no owner.

=cut

sub clone {
  my ($self, $new_owner) = @_;

  # clone first, unlike all the other recursive code. Damn.
  my $clone = $self->cloneThis( $new_owner ) or return;

  # now clone recusively.
  foreach my $method ($self->_all_relationships) {
    next if $self->weak_reference_all->{$method}; # not the weak ones
    my $obj = $self->get( $method ) or next;
    my $c = $obj->clone( $clone ) or return;
    $clone->set( $method => $c );
  }

  return $clone;
}

=head2 cloneThis( [new_owner] )

Clones just this Class::Persist object, not any of its children.

new_owner will own the newly cloned object, if passed. If not, the new
object will have no owner.

=cut

sub cloneThis {
  my ($self, $new_owner) = @_;
  # slightly nasty, we make a shallow copy of the object first,
  # then delete the references to the things we're cloning 'properly',
  # deep-clone the copy, then replace the relationships (in case we really
  # do want a shallow-copy of the object... )
  my $copy;
  %$copy = %$self;
  delete $copy->{$_} for $self->_all_relationships;
  my $clone = Storable::dclone( $copy );
  bless $clone, ref($self);
  $copy->{$_} = $self->{$_} for $self->_all_relationships;

  # now the copy needs a new identity
  $clone->oid( $clone->_generate_oid() );
  # if we had an owner before, replace it with the new one.
  $clone->owner( $new_owner ) if $clone->owner;
  # new objects aren't from the db
  $clone->_from_db(0);
  # and into the cache we go
  $clone->_object_cache->store($clone);
}
  
=head2 validate()

Returns true if the object is in a good, consistent state and can be
stored. The default implementation just returns true - Override this
method if you want to make sure your objects are consistent before
storing. Returning 0 from this will cause the store() method to fail.

=cut

sub validate { 1 }


=head2 unique()

Returns true if the current object is unique, ie there is no other row in
the database that has the same value as this object. The query that is
used to check for uniqueness is defined by the L<unique_params> method.

Only checked for unstored objects - objects that have come from the database
are presumed to be unique.

=cut

# TODO - _WHY_ are they presumed to be unique? We can change them, can't we?

sub unique {
  my $self = shift;
  return 1 if $self->_from_db; # shortcut - no need to test if obj is from db
  my $dbh = $self->dbh;
  my @params = $self->unique_params;
  ! ($dbh->selectrow_array(shift @params, undef, @params))[0];
}



sub _same_as {
  my $self  = shift;
  my $other = shift;
  foreach my $key ($self->db_fields) {
    next if ($key eq $ID_FIELD);
    next if ( !$self->get($key) and !$other->get($key) );
    next if ref($self->get($key));
    next if ($self->get($key) eq $other->get($key));
    Class::Persist::Error::InvalidParameters->record(
      -text => "Parameter $key mismatch");
    return;
  }
  return 1;
}



=head1 RELATIONSHIPS AND CLASS SETUP

Classes can have relationships with each other. The simplest way to define
a class and its relationships is with the L<simple_db_spec> method, but if
you want more control you can use the more specific functions.

=head2 simple_db_spec( column => "type", ... )

The simplest of specifying the database spec, combining the field list,
has_a and has_many relationships and the database spec in one command.

  Person::Foot->simple_db_spec(
    digits => 'INT',
    name => 'CHAR(10)',
    leg => 'Person::Leg',
    hairs => [ 'Person::Leg::Hair' ],
    grown_on => "DateTime",
  );

For each column as the keys of the passed hash, specify a simple DB field
with a DB type, a has_a relationship with a class name, and a has_many
relationship with a listref continain a single element - the class name.

This will also automatically create a name for the database table, if you
don't want to supply one yourself. The name will be based on the package name.

Any fields defined as BLOB, LONGBLOB or similar types will automatically be
declared as binary fields - see L<binary_fields>.

Finally, defining a field type as 'DateTime' will let you store a DateTime
object in that field, which will be stringified to yyyy-mm-ddThh::mm::ss
in the database column.

=cut

sub simple_db_spec {
  my $class = shift;
  my %spec = ref($_[0]) ? %{$_[0]} : @_;
  die "simple_db_spec is a class method" if ref($class);

  # make up a table name if needed
  unless ($class->db_table) {
    my $table = lc($class);
    $table =~ s/::/_/g;
    $class->db_table( $table );
  }

  # walk the spec, interpret minilanguage
  # class names are turned into has_a relationships,
  # listrefs become has_many relationships.
  # DateTime is 'magic'.
  my @simple;
  for my $col (keys %spec) {

    # For things like 'NOT NULL', etc, we get the name seperately.
    my ($name, $extra) = (split(/\s+/, $spec{$col}, 2), "")
      if ($spec{$col} and !ref($spec{$col}) );

    if (ref($spec{$col}) eq 'ARRAY') {
      my $def = shift @{ $spec{$col} };
      my ($name, $extra) = (split(/\s+/, $def, 2), "");
      $name =~ s/::$//;
      $class->has_many( $col, $name, @{ $spec{$col} } );
      delete $spec{$col};

    } elsif ($name eq 'DateTime') {
      $class->_add_datetime_magic($col);
      push @simple, $col;
      $spec{$col} = "DATETIME $extra";

    } elsif ($name =~ /::/) {
      $name =~ s/::$//;
      $class->has_a( $col => $name );
      $spec{$col} = "CHAR(36) $extra";

    } else {
      push @simple, $col;
    }
  }

  $class->db_fields(@simple);
  $class->db_fields_spec( map { "$_ $spec{$_}" } keys %spec );

  # BLOB, LONGBLOB, etc, get the binary flag set automatically.
  my @binary;
  for (keys(%spec)) {
    push @binary, $_ if $spec{$_} =~ /^\w*BLOB/;
  }
  $class->binary_fields(@binary) if @binary;

}

=head2 db_table( [table] )

Get or set the name of the table that this class will be stored in. If you
don't set it explicitly, and use L<simple_db_spec>, a table name based on
the package name will be generated automatically for you. Alternatively, you
can set it specifically.

If you don't use the simple_db_spec method, you must explicitly set a table
name.

=cut

sub db_table {
  my $self  = shift;
  my $class = ref($self) || $self;
  if (my $table = shift) {
    $SCHEME{$class}->{table} = $table;
  }
  $SCHEME{$class}->{table};
}

=head2 db_fields( @fields )

Instead of using simple_db_spec, you can tell Class::Persist which columns
in the table are to store properties, and set up the relationships manually,
using db_fields, L<has_a>, L<has_many>, etc.

db_fields defines the fields in the DB that will store scalar values.

  My::Foo->db_fields(qw( foo bar baz ));

Only define the fields that this particular subclass adds using this
function - the L<db_fields_all> function can be used to get a list of
all fields that the object will provide, those from this class and all
its superclasses.

=cut

sub db_fields {
  my $self  = shift;
  @{$self->_fields_access('fields', @_) || []};
}

=head2 db_fields_all()

Returns a list of all db fields that this class and all its superclasses use.

=cut

sub db_fields_all {
  my $self  = shift;
  @{$self->_fields_access_all('fields', 'has_a', @_)};
}

=head2 binary_fields( @fields )

By default, all properties of a Class::Persist object are assumed to
contain a UTF8 string. If you want to put binary data into the database,
you must explicitly declare a field to contain binary data using this
functions.

  My::Foo->db_field(qw( foo bar baz ));
  My::Foo->binary_fields(qw( foo ));

=cut

sub binary_fields {
  my $self  = shift;
  @{$self->_fields_access('binary', @_)};
}


=head2 binary_fields_all()

returns all binary fields of this object and its superclasses.

=cut

sub binary_fields_all {
  my $self  = shift;
  @{$self->_fields_access_all('binary', undef, @_)};
}

sub binary_fields_all_hash {
  my $self  = shift;
  $self->_fields_access_all_hash('binary', undef, @_);
}


=head2 has_a( $method => $class )

Class method. Defines a has_a relationship with another class.

  Person::Body->has_a( head => "Person::Head" );
  my $nose = $body->head->nose;

Allows you to store references to other Class::Persist objects. They will
be serialised when stored in the database.

=cut

sub has_a {
  my $self  = shift;
  $self->_add_has_a_magic( @_ );
  $self->_scheme_access_this ('has_a', @_);
}


=head2 has_a_all()

Returns a hashref of all the has_a relationships a given class has, from
itself and its superclasses.

=cut

sub has_a_all {
  my $self  = shift;
  $self->_scheme_access_all ('has_a', @_);
}

=head2 weak_reference( one, two, three )

Sets the list of references from this object that should be considered
'weak'. Weak references will not be recursed into when storing, deleting,
etc, and objects on the other end of them won't have their 'owner'
fields set. This lets you use a field to point into some other part of
an object tree without worrying about nasty loops.

=cut

sub weak_reference {
  my $self  = shift;
  $self->_fields_access('weak_ref', @_);
}

=head2 weak_reference_all

Returns a hashref, the keys of which are the fields with weak references
of this class and it's superclasses.

=cut

sub weak_reference_all {
  my $self  = shift;
  $self->_fields_access_all_hash('weak_ref', @_);
}

=head2 has_many( $method => $class )

Class method. Defines a one to many relationship with another class.

  Person::Body->has_many( arms => 'Person::Arm' );
  my $number_of_arms = $body->arms->count;

Allows you to manipulate a number of other Class::Persist objects that are
associated with this one. This method will return a
L<Class::Persist::Proxy::Container> that handles the child objects, it
provides push, pop, count, etc, methods to add and remove objects from the
list.

  my $left_arm = Person::Arm->new;
  $body->arms->push( $left_arm );

=cut

sub has_many {
  my $self  = shift;
  $self->_scheme_access_this ('has_many', @_);
}


=head2 has_many_all()

Returns a hashref of all the has_many relationships a given class has, from
itself and its superclasses.

=cut

sub has_many_all {
  my $self  = shift;
  $self->_scheme_access_all ('has_many', @_);
}

=head2 might_have( $method => $class )

Call on a class to define a might_have relationship between that class
and another class:

  My::Bar->might_have( jukebox => My::Jukebox );

A might_have relationship differs from a has_a relationship in that, for
has_a, there is a field in the parent table that points to the child
object. For might_have, the owner field of the child object points to
the parent, and the child object will have an 'owner' accessor that
points at the parent.

TODO - logically, has_a relationships should B<also> provide an owner
method to the child class.

Objects on the other end of this relationship will be stored when the
parent object is stored.

=cut

sub might_have {
  my $self  = shift;
  $self->_scheme_access_this ('might_have', @_);
}

=head2 might_have_all()

For a given class, returns (not sets) a hashref of all of its might_have
relationships, including those of its parent classes.

=cut

sub might_have_all {
  my $self  = shift;
  $self->_scheme_access_all ('might_have', @_);
}

=head2 unique_params()

SQL query and binding params used to check unicity of object in DB

=cut

sub unique_params {
  my $self = shift;
  my $table = $self->db_table;
  ("SELECT 1 FROM $table WHERE $ID_FIELD=?", $self->oid);
}

=head2 db_fields_spec()

SQL to specificy the database columns needed to store the attributes of this
class - all parent class(es) columns are aggregated and used to build an SQL
create table statement. Override this to specify the columns used by your class,
if you want Class::Persist to be able to create your table for you.
Remember to call the superclass db_fields_spec as well, though.

  sub db_fields_spec(
    shift->SUPER::db_fields_spec,
    'Colour VARCHAR(63)',
    'Mass VARCHAR(63)',
  );


=cut

sub db_fields_spec {
  my $self  = shift;
  @{$self->_fields_access('db_fields_spec', @_) || []};
}

=head2 db_fields_spec_all()

=cut

sub db_fields_spec_all {
  my $self  = shift;
  my $class = ref($self) || $self;

  unless ( $SCHEME{$class}->{all}->{db_fields_spec} ) {
    my @list;
    foreach my $isa ( reverse $class, Class::ISA::super_path($class) ) {
      $isa->can('db_fields_spec') or next;
      push @list, $isa->db_fields_spec;
    }
    my %unique;
    @unique{@list} = ();
    $SCHEME{$class}->{all}->{db_fields_spec} = [sort keys %unique];
  }

  @{ $SCHEME{$class}->{all}->{db_fields_spec} };
}


=head1 DATABASE MANAGEMENT

=head2 create_table()

Create the table for this class in the database.

=cut

sub create_table {
  my $self  = shift;
  my $table = $self->db_table     or die "No table name";
  my $dbh   = $self->dbh          or die "No dbh when creating $table";
  my $sql   = $self->_db_table_sql or die "No table sql for $table";
  $sql = "CREATE TABLE $table $sql";
  $dbh->do($sql) or die "Could not execute $sql - $DBI::errstr";
}

=head2 drop_table()

Drop the table for this class.

=cut

sub drop_table {
  my $class  = shift;
  my $dbh   = $class->dbh;
  my $table = $class->db_table or die "No table name";
  # XXX can't portably IF EXISTS
  if ($class->postgres) {
    $dbh->do("DROP TABLE $table");
  } else {
    $dbh->do("DROP TABLE IF EXISTS $table");
  }
  return 1;
}

sub init {
  my $self = shift;
  $self->SUPER::init(@_) or return;
  $self->creation_date( DateTime->now ) unless ( $self->creation_date );
  return $self->_setup_relationships;
}

# the base class populate populates an object from a hash. We extend it
# to fill in the placeholders for the has_many, etc, relationships.
sub _populate {
  my $self = shift;
  $self->SUPER::_populate(@_);
  return $self->_setup_relationships;
}

# put placeholders in the has_many, etc, slots.
# called after init and populate.
sub _setup_relationships {
  my $self = shift;

  my $methods = $self->might_have_all;
  foreach my $method (keys %$methods) {
    my $class = $methods->{ $method };
    my @oids = @{ $self->_oids_for_owner( $class, $self->oid ) };
    next unless @oids;
    Class::Persist::Error->throw( -text => "Too many objects for might_have relationship" )
      if (scalar(@oids) > 1);
    my $proxy = Class::Persist::Proxy->new( class => $methods->{$method},
                                            real_id => $oids[0],
                                          );
    $self->set( $method => $proxy );
  }

  $methods = $self->has_many_all;
  foreach my $method (keys %$methods) {
    my $proxy = Class::Persist::Collection->new();
    $proxy->element_class( $methods->{$method} );
    $proxy->owner( $self );
    $self->set( $method => $proxy );
  }

  return $self;
}

# insert the object into a database
sub _db_insert {
  my $self = shift;
  $self->_db_insert_or_update($self->_db_insert_sql);
}

# update an existing object in the database
sub _db_update {
  my $self = shift;
  $self->_db_insert_or_update($self->_db_update_sql, $self->oid);
}

sub _db_insert_or_update {
  my ($self, $sql, $oid) = @_;
  my $dbh = $self->dbh;

  my $sth = $dbh->prepare_cached($sql)
    or Class::Persist::Error::DB::Request->throw(
      -text => "Could not prepare $sql - $DBI::errstr");

  my $param = 1;
  my @fields = $self->db_fields_all;
  my $binary = $self->binary_fields_all_hash();

  # The postgres 'random binary data' SQL bind type is not the same as
  # the rest of the world. Here, $blobby will be whatever bind type we
  # need for binary data, and $normal will be whatever everything else
  # wants.
  my $blobby = $self->postgres ? {pg_type => DBD::Pg::PG_BYTEA()} : SQL_BLOB;
  my $normal = undef;

  for my $field (@fields) {
    my $value = $self->_get_db_value($field);
    utf8::encode($value) unless ($binary->{$field} or !defined($value));
    {
      no warnings 'uninitialized'; # for inserting nulls
      $sth->bind_param( $param, $value, $binary->{$field} ? $blobby : $normal );
    }
    $param++;
  }

  $sth->bind_param( $param, $oid ) if $oid;

  {
    no warnings 'uninitialized'; # for inserting nulls
    $sth->execute;
  }

  $sth->finish;
}

sub _db_insert_sql {
  my $self = shift;

  my $table = $self->db_table;
  my $sql = $SQL{$table}->{insert};
  unless ($sql) {
    my @fields  = $self->db_fields_all;
    my $columns = join(',', @fields);
    my $holders = join(',', ('?') x scalar(@fields));
    $sql = "INSERT INTO $table ($columns) VALUES ($holders)";
    $SQL{$table}->{insert} = $sql;
  }
  $sql;
}

sub _db_update_sql {
  my $self = shift;

  my $table = $self->db_table;
  my $sql = $SQL{$table}->{update};
  unless ($sql) {
    my @fields = $self->db_fields_all;
    my $set = join(',', map { "$_=?" } @fields);
    $sql = "UPDATE $table SET $set WHERE $ID_FIELD=?";
    $SQL{$table}->{update} = $sql;
  }
  $sql;
}

sub _db_table_sql {
  my $self = shift;

  my $blob = $self->postgres ? 'bytea' : 'longblob';
  my $datetime = $self->postgres ? 'char(19)' : 'datetime';
  my @spec = $self->db_fields_spec_all;
  # Rewrite columns ending "blob" to a useful blobby type for this database.
  # Given that Postgresql doesn't do blob. Grrr.
  foreach (@spec) {
    s/^(\S+\s+)(\w*blob)/$1$blob/i;
    s/^(\S+\s+)(datetime)/$1$datetime/i;
  }
  "(". join(', ', @spec) .")";
}


=head1 STORING MORE COMPLEX OBJECTS

It may be that you want to put a complex object, say a hashref, into a db
field. for a given db field name, there are two hooks: db_inflate_{name} and
db_deflate_{name} that are called when we inflate/deflate an object from the
database.

db_inflate_{name}(db_value) is called when we inflate from the database, and
is passed as its only parameter the value of the DB column - this is undef
if the column value is NULL. The function should set up the object according
to this db field - this will probably entail calling 'set(field,val)'.

db_deflate_{name} is called when we want to store the object back in to the
db, and should return the value that should go into the DB column {name}.

An example is probably best here.

  package Example;
  
  __PACKAGE__->simple_db_spec(
    hash => "text", # we'll deflate a hash here
  );

  sub db_inflate_hash {
    my ($self, $db_value) = @_;
    
    # empty db column means empty hash
    return $self->set( hash => {} ) unless $db_value;

    # values in the db are key\tvalue\tkey\tvalue
    my (%hash) = split(/\t/, $db_value);

    # store the inflated hash in the object
    return $self->set( hash => \%hash );
  }
  
  sub db_deflate_hash {
    my $self = shift;
    
    # get the hash from the object
    my %hash = %{ $self->get('hash') }

    # no hash? put nothing in the db
    return undef unless %hash;

    # store the hash in the DB as tab-seperated key/value pairs
    return join("\t", @%hash);
  }

(Obviously this is a simple example - we should do something smarter to
make sure there are no blessed objects in the hash, etc, etc.)

This object will now have a db-persisted hashref in its 'hash' slot.

These hooks are only supported for 'normal' db fields - defined with the
L<db_fields()> accessor or declared as simple types in L<simple_db_spec()>.
Using them to hook has_a, has_many or other complex relationships is not
advised.



=cut


# because classes can inherit properties off their superclasses, but we don't
# want to have to put lots of SUPER::s in the definitions, we have a hash that,
# for a given property name, say 'has_many', stores the value of that property
# for a class.

# The $class->_scheme_access_this( $property, .. )  method is an accessor for
# the property as set for a specific class.

# the $class->_scheme_access_all( $property, .. ) method returns the
# amalgamation of all the properties for a given class and all its
# superclasses.

# Does that make any sense?

sub _scheme_access_this {
  my ($self, $what, $method, $target) = @_;
  my $class = ref($self) || $self;
  # Ensure that $SCHEME{$class}->{this}->{$what} (not some temporary lexical)
  # is autovivified - that's why it's longhand.
  if ($method) {
    $SCHEME{$class}->{this}->{$what}->{$method} = $target;
    delete $SCHEME{$class}->{all}; # invalidate the cache
  }
  $SCHEME{$class}->{this}->{$what}->{$method};
}

sub _scheme_access_all {
  my ($self, $what) = @_;
  my $class = ref($self) || $self;
  # The hash ref of the part of the structure we are interested in.
  unless ( $SCHEME{$class}->{all}->{$what} ) {
    my @pairs;
    $SCHEME{$class}->{all}->{$what} = {};
    foreach my $isa ( reverse $class, Class::ISA::super_path($class) ) {
      exists $SCHEME{$isa} or next;
      my $methods = $SCHEME{$isa}->{this}->{$what} or next;
      push @pairs, %$methods;
    }
    %{$SCHEME{$class}->{all}->{$what}} = @pairs;
  }

  $SCHEME{$class}->{all}->{$what};
}

sub _fields_access {
  my ($self, $what, @fields)  = @_;
  my $class = ref($self) || $self;
  if (@fields) {
    $SCHEME{$class}->{this}->{$what} = \@fields;
    delete $SCHEME{$class}->{all};
  }
  $SCHEME{$class}->{this}->{$what};
}

sub _fields_access_all {
  my ($self, $what, $bonus_hash, @fields)  = @_;
  my $class = ref($self) || $self;

  return $SCHEME{$class}->{all}->{$what}
    unless (@fields or !$SCHEME{$class}->{all}->{$what});

  # We're going to be updating in some way.
  if (@fields) {
    $SCHEME{$class}->{this}->{$what} = \@fields;
  }
  else {
    # $SCHEME{$class}->{all}->{$what} must be false.

    # @fields has to be ()
    foreach my $isa ( reverse $class, Class::ISA::super_path($class) ) {
      exists $SCHEME{$isa} or next;
      if (my $fields = $SCHEME{$isa}->{this}->{$what}) {
        push @fields, @$fields;
      }
      if ($bonus_hash and my $fields = $SCHEME{$isa}->{this}->{$bonus_hash}) {
        push @fields, keys %$fields;
      }
    }
  }

  my %unique;
  # This is assigning to a hash slice. Fill it with 1s
  @unique{ @fields } = (1) x @fields;

  $SCHEME{$class}->{all_hash}->{$what} = \%unique;
  $SCHEME{$class}->{all}->{$what} = [sort keys %unique];
}

sub _fields_access_all_hash {
  my ($self, $what, $bonus_hash)  = @_;
  my $class = ref($self) || $self;
  return $SCHEME{$class}->{all_hash}->{$what} ||
    do {
      $self->_fields_access_all($what, $bonus_hash);
      $SCHEME{$class}->{all_hash}->{$what};
    }
}

# every column that might contain a relationship object
sub _all_relationships {
  my $self = shift;
  my $might_have = $self->might_have_all;
  my $has_many   = $self->has_many_all;
  my $has_a      = $self->has_a_all;
  return ( keys(%$might_have), keys(%$has_many), keys(%$has_a) );
}

1;
__END__

=head1 STORAGE IMPLEMENTATION DETAILS

The L<binary_fields> accessor is there for a reason - there is a very strong
implicit assumption that everything you want to put into Class::Persist is
either a text string, in which case it will be stored in the database as
a series of UTF8 octets, or a lumb of binary data, in which case it will
go into the DB as-is, but you must flag it as such. Class::Persist does not
use any db-specific character set tools, such as the utf-8 support in
mysql 4.1, because I want to do things the same across all databases where
possible - in this case, that meast that we assume the DB stores the exact
bytes that we give it, and will give them back. Class::Persist handles the
encoding and decoding from utf8, so you can store any valid perl string and
will get back something that is at least equivalent.

=head1 BUGS

The API isn't yet stabilised, so please keep an eye on the Changes file
where incompatible changes will be noted.

Storing B<invalid> perl strings in the database, for instance using C<_utf8_on>
to flip the utf8 bit on a non-utf8 string, will break. Horribly. Don't Do
It.

Making recursive loops in the object tree is very easy. However, it'll lead
to recursive storing and pain. Again, not a good idea. It'll be fixed soon,
I hope.

an object with more than parent-child relationship with a particular subclass
is going to act very strangely, ie a has_a => "Some::Class" and a
has_many => "Some::Class". Not sure what to do about that one.


=head1 AUTHORS

=over

=item Nicholas Clark <nclark@fotango.com>

=item Pierre Denis   <pdenis@fotango.com>

=item Tom Insam      <tinsam@fotango.com>

=item Richard Clamp  <richardc@unixbeard.net>

=back

This module was influnced by James Duncan and Piers Cawley's Pixie object
persistence framework, and Class::DBI, by Michael Schwern and Tony Bowden
(amongst many others), as well as suggestions from various people within
Fotango.

=head1 COPYRIGHT

Copyright 2004 Fotango.  All Rights Reserved.

This module is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

# Local Variables:
# mode: CPerl
# cperl-indent-level: 2
# indent-tabs-mode: nil
# End:
