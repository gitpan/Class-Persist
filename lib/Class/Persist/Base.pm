=head1 NAME

Class::Persist::Base - base class for all Class::Persist objects

=head1 DESCRIPTION

This base class implements features common to all Class::Persist objects -
the accessors creation methods,

=cut

package Class::Persist::Base;
use warnings;
use strict;
use UNIVERSAL::require;
use Data::Dumper;
use Data::UUID;
use Error;
use Scalar::Util qw( blessed );

use base qw( Class::Accessor::Chained Class::Data::Inheritable );

sub define_error_class {
  my $class = shift;
  my $error = shift;
  my $superclass = shift || "Class::Persist::Error";
  {
    no strict 'refs';
    @{ $error ."::ISA" } = ($superclass);
  }
}

Class::Persist::Base->define_error_class( "Class::Persist::Error" => "Error" );
sub Class::Persist::Error::stringify { "[".ref($_[0])."] - ".$_[0]->stacktrace }

Class::Persist::Base->define_error_class($_) for (qw(
  Class::Persist::Error::New
  Class::Persist::Error::TimeOut
  Class::Persist::Error::Multiple
  Class::Persist::Error::DateTime
  Class::Persist::Error::InvalidParameters
  Class::Persist::Error::Method
));

=head1 OBJECT CREATION

=head2 new( key => value, key => value, ... )

new creates and returns a new object. Any parameters are passed to the init
method.

=cut

sub new {
  my $class = shift;
  $class = ref($class) || $class;
  my $self = bless {}, $class;
  $self->init(@_) or return;
  return $self;
}


=head2 init

the init method is called by new() after it creates an object. The init
assumes the passed parameters are a hash, takes the keys, and
calls the methods with the names of the keys, passing the values. The
common use for this is to pass initial values for all the accessor methods
when calling new():

  my $object = Your::Subclass->new( foo => 'bar' );

override the init method in your subclass if you need to perform setup, but
remember to call the init method of the superclass first, and return undef if
it fails:

  sub init {
    my $self = shift;
    $self->SUPER::init(@_) or return;

    ...
    return 1;
  }

Return 1 to indicate your init was successful, and the new method will return
the object. Returning a false value will cause new() to fail.

=cut

sub init {
  my $self = shift;
  my $params;
  if (ref( $_[0] )) {
    $params = $_[0];
  } else {
    throw Class::Persist::Error::InvalidParameters (
      -text => "Bad number of parameters")
        unless (scalar(@_) % 2 == 0);
    $params = { @_ };
  }
  if ($params) {
    my $errors = {};
    foreach my $method (keys %$params) {
      if ( my $can = $self->can($method) ) {
        next unless defined( $params->{$method} );

        my $result = eval { $can->($self, $params->{$method}) };
        if (UNIVERSAL::isa($@, "Class::Persist::Error::InvalidParameters")) {
          $errors->{$method} = $@->text;
        } elsif ($@) { die $@; }

        if (!$result) {
          $errors->{$method} ||= "Method $method didn't return a true value";
        }

      } else {
        $errors->{$method} = "Method $method doesn't exist";
      }
    }
    if (%$errors) {
      throw Class::Persist::Error::Multiple
        -text => "Error calling init for ".ref($self)." - ".Dumper($errors),
        -errors => $errors;
    }
  }
  if ($self->isa("Class::Persist")) {
    # store newly created Class::Persist objects
    $self->_object_cache->store($self) if $self->_object_cache;
  }
  1;
}

=head1 METHODS

=head2 oid

A UUID that uniquely identifies this object in the world. It would be bad to
change this unless you know what you are doing. It's probably bad even if you
do know what you're doing.

=cut

# The ID_FIELD is programmatic because we've got a lot of existing code that
# expects 'oid' that we don't want to change, but in Pg 'oid' is a reserved
# system column name, so it can't be that there.

sub oid {
  my $self = shift;
  return $self->set($Class::Persist::ID_FIELD, shift) if @_;
  $self->set( $Class::Persist::ID_FIELD, $self->_generate_oid )
    unless $self->get( $Class::Persist::ID_FIELD );
  return $self->get( $Class::Persist::ID_FIELD );
}

sub _generate_oid { Data::UUID->new->create_str() }

=head2 mk_accessors

=head2 get( column )

=head2 set( column => value, [ column => value ... ] )

=cut

sub get {
  my $self = shift;
  Class::Persist::Error->throw( -text => "$self not an instance" )
    unless ref($self);
  $self->SUPER::get(@_);
}

sub set {
  my $self = shift;
  Class::Persist::Error->throw( -text => "$self not an instance" )
    unless ref($self);

  if ($self->isa("Class::Persist")) {
    # when setting certain members, we want to set ownership, etc.
    my %set = @_;
    while (my ($field, $value) = each(%set) ) {
      if ($self->has_a_all->{$field}) {
        next if $self->weak_reference_all->{$field}; # not weak refs
        if (my $current = $self->get($field)) {
          $current->owner(undef);
        }
        next unless defined($value);
        next if ( blessed($value) and $value->isa("Class::Persist::Proxy"));
        unless ( blessed($value) and $value->isa("Class::Persist") ) {
          Class::Persist::Error->throw(
            -text => "has_a targets must be Class::Persist objects" );
        }
        $value->owner( $self );
      }
    }
  }
  $self->SUPER::set(@_);
}


sub _duplicate_from {
  my $self = shift;
  my $source = shift or Class::Persist::Error->throw( -text => "need source" );
  if ($self->_object_cache and $self->oid ne $source->oid) {
    $self->_object_cache->remove($self);
  }
  %$self = %$source;
  bless $self, ref($source) if ref($source);
  return $self->_object_cache->store($self) if $self->_object_cache;
  return $self;
}


sub _populate {
  my $self = shift;
  my $cols = shift;
  while (my ($field, $value) = each %$cols) {
    my $db_accessor = "db_inflate_$field";
    if ($self->can($db_accessor)) {
      $self->$db_accessor($value);
    } else {
      $self->set( $field => $value );
    }
  }
  return $self;
}

# for a db field, return what should go into the DB for that field.
# (the value, not the bytes)
sub _get_db_value {
  my ($self, $field) = @_;
  my $value;
  my $db_accessor = "db_deflate_$field";
  if ($self->can($db_accessor)) {
    $value = $self->$db_accessor;
  } else {
    $value = $self->get($field);
    if (ref($value)) {
#      if ($value->isa("Class::Persist::Proxy")) {
#        $value = $value->oid;
#      } else {
        throw Class::Persist::Error
          -text => "Can't store $value in field $field - not a proxy";
#      }
    }
  }
  if (ref($value)) { #  eq 'ARRAY' or ref($value) eq 'HASH') {
    throw Class::Persist::Error::StoreReference (
      -text => "$field contains a reference");
  }
  return $value;
}

sub loadModule {
  my ($self, $class) = @_;
  $class->require;
}

sub _add_datetime_magic {
  my ($class, $col) = @_;
  no strict 'refs';
  if ($class->can("db_inflate_$col") and $class->can("db_deflate_$col")) {
    Class::Persist::Error::Method->throw(
      -text => "can't create magic methods for $col" );
  }

  *{ $class."::db_inflate_$col" } = sub {
    my ($self, $db) = @_;
    return undef unless defined($db); # NULL in the db

    my ($year, $month, $day, $hour, $min, $sec) = split(/[\-:T\s]/, $db);
    my $dt = eval { DateTime->new(
      year => $year, month => $month, day => $day,
      hour => $hour, minute => $min, second => $sec,
    ) }
    or Class::Persist::Error::DateTime->throw(
      -text => "Can't parse '$db' as YYYY-MM-DD HH:MM:SS" );

    return $self->set($col => $dt);
  };

  *{ $class."::db_deflate_$col" } = sub {
    my ($self) = shift;
    my $dt = $self->get($col) or return undef;
    return $dt->ymd("-")." ".$dt->hms(":");
  };
  return $class;
}


sub _add_has_a_magic {
  my ($class, $col, $target) = @_;
  no strict 'refs';
  if ($class->can("db_inflate_$col") and $class->can("db_deflate_$col")) {
    Class::Persist::Error::Method->throw(
      -text => "can't create magic methods for $col" );
  }

  *{ $class."::db_inflate_$col" } = sub {
    my ($self, $db) = @_;
    return undef unless defined($db); # NULL in the db
    my $proxy = Class::Persist::Proxy->new( class => $target, real_id => $db );
    return $self->set($col => $proxy);
  };

  *{ $class."::db_deflate_$col" } = sub {
    my ($self) = shift;
    my $object = $self->get($col) or return undef;
    $object->store() unless ($self->weak_reference_all->{$col});
    return $object->oid;
  };
  return $class;
}


# gets a list of oids of the passed class that have the
# passed object as their owner. Could probably very easily be replaced
# with a simple 'search' call, but search should return proxies first. (TODO)
sub _oids_for_owner {
  my $self  = shift;
  my $class = shift;
  my $owner = shift
    or Class::Persist::Error::InvalidParameters->throw(
      -text => "A owner should be passed");

  my $owner_oid = ref($owner) ? $owner->oid : $owner;

  my $dbh   = $class->dbh;
  my $table = $class->db_table;
  my $sql   = "SELECT $Class::Persist::ID_FIELD
               FROM $table
               WHERE owner=?";

  my $r = $dbh->prepare_cached($sql)
    or Class::Persist::Error::DB::Request->throw(
      -text => "Could not prepare $sql - $DBI::errstr");

  $r->execute($owner_oid)
    or Class::Persist::Error::DB::Request->throw(
     -text => "Could not execute $sql - $DBI::errstr");

  my $rows = $r->fetchall_arrayref
    or Class::Persist::Error::DB::NotFound->record(
      -text => "No object loaded") and return;

  $r->finish();

  [ map $_->[0], @$rows ];
}


sub _object_cache {
  my $self = shift;
  return $self->cache_class->instance;
}

sub cache_class { "Class::Persist::Cache" }




1;

__END__

=head1 NAME

Class::Persist::Base - Base class for Class::Persist

=head1 DESCRIPTION

This is a useful thing to inherit from - it gives you accessors, a new /
init method that will initialise the object, emit/throw/record methods
for throwing errors, and does the right thing when accessors don't
return true values.

