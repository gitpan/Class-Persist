=head1 NAME

Class::Persist::Cache

=head1 DESCRIPTION

This is an object cache for Class::Persist. It stores weak references to
every object retrieved from the database, and Class::Persist will attempt
to return an object from the cache in preference to returning another
instance of the database object. This should mean that there is only
ever one instance of any given persistantable object around at any time.

You won't for the most part have to worry about this class. It's
documented here so you can either pull objects from the cache
explicitly, which is not recommended, or so you can subclass the object
cache for some reason - for instance, in a web application, you may want
the cache to be per-session or per-request, to to perform some
end-of-request cleanup on the cache.

=head1 SYNOPSIS

=cut

package Class::Persist::Cache;
use warnings;
use strict;
use Scalar::Util qw( blessed weaken );

use Carp qw( croak );
use Data::Dumper;
use Class::Persist::Base;

=head1 EXCEPTIONS

=over

=item Class::Persist::Error::Cache (a Class::Persist::Error)

all exceptions thrown by the cache are subclasses of this error

=item Class::Persist::Error::Cache::CannotStore (a Class::Persist::Error::Cache)

the object store cannot store the passed object - it's not a Class::Persist
object, or there's already a similar object in the store. 

=item Class::Persist::Error::Cache::CannotRemove (a Class::Persist::Error::Cache)

the object passed to the remove() function cannot be removed

=back

=cut

Class::Persist::Base->define_error_class( "Class::Persist::Error::Cache" );
Class::Persist::Base->define_error_class($_, "Class::Persist::Error::Cache") for (qw(
  Class::Persist::Error::Cache::CannotStore
  Class::Persist::Error::Cache::CannotRemove
));

=head1 METHODS

=over

=item instance()

Naturally, the singleton cache is itself a singleton. This method should
return the instance of the cache.

=cut

our $INSTANCE;
sub instance {
  my $class = shift;
  $INSTANCE ||= bless {}, $class; # we're a singleton
}

=item object_store()

Returns the hashref that we keep all the objects in. In this implementation,
the store is inside the Cache singleton, not package-level.

=cut

sub object_store {
  my $self = shift;
  $self->{_object_store} ||= {};
}

=item store( object )

Store an object by its oid. This method will not store a
non-Class::Persist object. You B<can> pass Proxies to store() and they
will be stored, unless there is a 'real' object with that oid in the
store. store() returns the object that is in the store - this is B<not>
nessecarily the object that you told it to store.

store() performs some sanity checking. If we already know about an
object with the oid of the thing we're trying to store, store() tries
very hard to ensure that there is only one definitive copy. If you're
trying to store a proxy, and we know about a real object, store() will
return the real object from the store. If you're trying to store a real
object and store only knows about a proxy, store will inflate the proxy
based on the real object, and return the object from the B<store> again,
so that other references to that object now have an inflated object.
Storing a proxy over a proxy just returns the proxy from the store.

Storing the exact same object twice is safe, obviously. The nasty case
arises when you're trying to store two 'real' objects with the same oid.
Under normal usage, this should never arise, and I'm very interested in
any test case you can produce that returns two different objects with
the same oid. If you try to store an object that is not in the store,
but has the same oid as some other object in the store, an exception
will be throw. This should not ever happen.

For this reason, in Class::Persist we are very careful to return the
object that the store() method B<returns>, as this is the singleton
version of that oid, and you should too.

Things are stored in the L<object_store> hash, and the references to
them are weakened, to avoid memory leaks. If you want a given object from
the database to stay around, you must hold a reference to it yourself.

=cut

sub store {
  my ($self, $object) = @_;

  # Class::Persist objects only, please.
  Class::Persist::Error::Cache::CannotStore->throw(
    -text => (ref($object)||'a scalar')." is not a Class::Persist object" )
      unless ( blessed($object) and (
        $object->isa("Class::Persist") or $object->isa("Class::Persist::Proxy") 
      ));

  #warn "storing $object (".$object->oid.")\n";

  # if there's already something in the store with this ID, we need to do
  # the right thing. The usage of the store() method is that the object you
  # get is the _return_ value of the method - any object already in the
  # store takes precedence over anything we just passed in, because there
  # must by definition be other things pointing at it. Thus we try to get
  # as much information from the thing passed in as possible, but return
  # a reference to the thing we already had.
  
  my $current = $self->object_store->{ $object->oid };
  if ($current and $current ne $object) {

    # if we're trying to store a proxy, don't. Return whatever we already
    # know about. this might be _another_ proxy, but proxies benefit from
    # being singletons too. No point in merging.
    if ($object->isa("Class::Persist::Proxy")) {
      return $current;

    # it's possible that the object in the store has been collapsed by
    # something, and is now a proxy. If this is the case, we overwrite the
    # object in the store with the passed in object (assuming they're not
    # _both_ proxies)
    } elsif ($current->isa("Class::Persist::Proxy")) {
      $current->_duplicate_from( $object )
        unless $object->isa("Class::Persist::Proxy");
      return $current;
    
    # if the object in the store is another copy, we consider it a fatal
    # error - we now have _2_ potential 'real' object. Bad, bad, bad.
    } else {
      Class::Persist::Error::Cache::CannotStore->throw(
        -text => "Object $current already stored" );
    }

  }

  # this is a new object! Put it in the store, but weaken the reference to
  # avoid memory leaks.
  $self->object_store->{ $object->oid } = $object;
  weaken( $self->object_store->{ $object->oid } );

  return $object;
}

=item remove( object )

Remove an object from the store. Throws an exception if the object isn't
a class persist object, or if the object you're trying to remove is not
the same object as the one for that oid already in the store.

=cut

sub remove {
  my ($self, $object) = @_;
  Class::Persist::Error::Cache::CannotRemove->throw( -text => "Not a Class::Persist object" )
    unless (blessed($object) and (
        $object->isa("Class::Persist") or $object->isa("Class::Persist::Proxy") 
      ) );
  Class::Persist::Error::Cache::CannotRemove->throw( -text => "Not the stored object" )
    unless ($object eq $self->object_store->{ $object->oid });
  delete $self->object_store->{ $object->oid };
  return $object;
}

=item get( id )

returns the object from the store with the given ID, or undef if the id
does not correspond to an object in the store.

=cut

sub get {
  my ($self, $id) = @_;
  $id = $id->oid if blessed($id);
  Class::Persist::Error::Cache->throw( -text => "No id" ) unless $id;
  return $self->object_store->{ $id };
}

=item all_ids()

returns a list of all the oids that the object store knows about.

=cut

sub all_ids {
  my $self = shift;
  return grep { $self->get($_) } keys(%{ $self->object_store });
}

=item tidy()

removes all the keys that point to undef values. Why not?

=cut

sub tidy {
  my $self = shift;
  for (keys(%{ $self->object_store })) {
    delete $self->object_store->{$_} unless $self->object_store->{$_};
  }
}

=item wipe_cache()

Resets the object cache. This should be considered very dangerous, as if there
are any other things holding references to objects in the cache, these objects
won't go away, and you'll get duplicate objects, etc.

=cut

sub wipe_cache {
  my $self = shift;
  Carp::shortmess( "WIPING OBJECT CACHE IS DANGEROUS" );
  %{ $self->object_store } = ();
  return $self;
}

=item proxy_all()

converts every object in the cache that is from the database, to a
Class::Persist::Proxy. This might be evil, I'm not sure. The objects
won't be stored.

=cut

sub proxy_all {
  my $self = shift;
  for ($self->all_ids) {
    my $object = $self->get($_);
    next unless $object->_from_db;
    Class::Persist::Proxy->proxy($object) or return;
  }
  return $self;
}

=item store_all()

stores all the objects in the cache. This will be slow, so watch it.

=cut

sub store_all {
  my $self = shift;
  for ($self->all_ids) {
    $self->get($_)->store or return;
  }
  return $self;
}


=back

=head1 SEE ALSO

Class::Persist

=head1 AUTHOR

Tom Insam, tinsam@fotango.com

=cut

1;
