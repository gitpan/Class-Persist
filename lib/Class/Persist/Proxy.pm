=head1 NAME

Class::Persist::Proxy - Proxy for an object not loaded yet

=head1 SYNOPSIS

  use Class::Persist::Proxy;
  $proxy = Class::Persist::Proxy->new( class => "Class", oid => "oid" );
  $real = $proxy->load();

=head1 DESCRIPTION

Framework to replace objects in the DB by Proxy objects. This allows
delayed loading of objects. A proxy acts as the real object itself, it
should be transparent. When a method is called on the proxy, the real
object is loaded in place of the proxy.

=head1 INHERITANCE

  Class::Persist::Base

=head1 METHODS

=cut

package Class::Persist::Proxy;
use strict;
use warnings;
use Scalar::Util qw( blessed );

use Class::Persist::Base;
use base qw( Class::Persist::Base );

Class::Persist::Base->define_error_class("Class::Persist::Error::Proxy");

__PACKAGE__->mk_accessors(qw( class real_id _empty_proxy ));

=head2 new( class => "class", real_id => "oid" )

Creates a proxy for the specified class and oid. These two must be passed
to the constructor or an error will be thrown.

=cut

sub new {
  my $class = shift;
  my $self = $class->SUPER::new(@_) or return;
  if ($self->_empty_proxy) {
    $self->_empty_proxy(undef);
    return $self;
  }

  Class::Persist::Error::Proxy->throw( -text => "Proxies need class and real_id" )
    unless $self->class and $self->real_id;

  # make sure we know about the class we're proxying
  $self->loadModule( $class );

  Class::Persist::Error::Proxy->throw( -text => "Class ".$self->class." does not exist" )
    unless UNIVERSAL::isa($self->class, "UNIVERSAL");

  if ($self->_object_cache) {
    # return a cached object with the oid we've been asked to proxy
    # if there's one in the class. This means that the new() method
    # may return a real object, and not a proxy
    my $current = $self->_object_cache->get($self->real_id);
    return $current if $current;
    # if we're not in the cache, we should be.
    $self->_object_cache->store($self);
  }
  return $self;
}

=head2 oid()

Tries hard to return the oid of the object proxied,
if it fails, returns the proxy oid.

=cut

sub oid {
  my $self = shift;
  return $self->set($Class::Persist::ID_FIELD, shift) if @_;
  return $self->real_id || $self->SUPER::oid();
}
=head2 real_id()

returns the oid of the thing we're proxying
 
=head2 class()

returns the class of the thing we're proxying.

=cut

=head2 dbh

returns a DBH object. We use the dbh that our L<class> uses, so dbh
must work as a class method on the proxied class.

=cut

sub dbh {
  my $self = shift;
  Class::Persist::Error::Proxy->throw( -text => "No class - can't get dbh" )
    unless $self->class;
  return $self->class->dbh;
}

# return the object_proxy of the proxied class
sub _object_cache {
  my $self = shift;
  return undef if $self->_empty_proxy;
  Class::Persist::Error::Proxy->throw( -text => "No class - can't get cache" )
    unless $self->class;
  return $self->class->_object_cache;
}

=head2 load()

Replace (in-place) the proxy by its target object

=cut

sub load {
  my $self  = shift;
  my $class = $self->get('class')
    or Class::Persist::Error::Proxy->throw(
      -text => "A class should be defined in proxy" );

  my $obj = $class->load( $self->real_id )
    or Class::Persist::Error::Proxy->throw(
      -text => "Can't load object with class $class, oid ".$self->real_id );

  return $self->_duplicate_from( $obj );
}

# proxies are already stored.
sub store { shift }

=head2 proxy( $obj )

Replace an object in-place by a proxy. This method doesn't store the object -
do that first if you want to keep changes.

  my $myobj = Object->load( $oid ); # load the object
  Class::Persist::Proxy->proxy( $myobj ); # and proxy it

=cut

# TODO - when we get a 'dirty' flag, proxying dirty objects should throw an
# error - you should be required to revert to store the object first.

sub proxy {
  my $class  = shift;
  my $obj    = shift;
  return $obj if $obj->isa("Class::Persist::Proxy");
  $obj->isa('Class::Persist')
    or Class::Persist::Error::Proxy->throw(
      -text => "object to proxy should be a Class::Persist, not a ".(ref($obj) || "scalar"));

  $class->loadModule( ref $obj ) or return;

  # if we create a proxy object oin one step here, we'll just
  # get the singleton back out the DB. Explicitly make a 'real'
  # proxy object instead.
  my $proxy = $class->new( _empty_proxy => 1 );
  $proxy->class( ref($obj) );
  $proxy->real_id( $obj->oid );

  # and this will put it into the cache.
  return $obj->_duplicate_from( $proxy );
}

our $AUTOLOAD;
sub AUTOLOAD {
  my $self = shift;
  $self = $self->load() or return; # die "Can't find in DB from ".(caller)[0]." line ".(caller)[2];
  my $meth = substr($AUTOLOAD, rindex($AUTOLOAD, ':') + 1);

  # if we can't do the thing we've been asked, throw an error that looks like
  # the normal perl error for this event.
  my $can = $self->can($meth)
    or Carp::croak("Can't locate object method \"$meth\" via package \"".ref($self)."\"");

  $can->($self, @_);
}

sub DESTROY { 1 }

sub clone {
  my $self = shift;
  $self = $self->load or return;
  return $self->clone(@_);
}

1;

=head1 SEE ALSO

Class::Persist

=head1 AUTHOR

Fotango

=cut

# Local Variables:
# mode:CPerl
# cperl-indent-level: 2
# indent-tabs-mode: nil
# End:
