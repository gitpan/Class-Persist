=head1 NAME

Class::Persist::Collection

=head1 SYNOPSIS

  my $collection = Class::Persist::Collection->new();
  $collection->owner($owner);
  $collection->push($object1, $object2);
  $collection->store();
  $obj1 = $collection->[0];

=head1 DESCRIPTION

Class::Persist::Collection objects serve as the intermediate step
between Class::Persist objects and their children in a has_many
relationship. They can be deferenced as arrays, and will inflate their
children from proxes as required.

=head1 INHERITANCE

  Class::Persist::Base

=head1 METHODS

=cut

package Class::Persist::Collection;
use strict;
use warnings::register;
use base  qw( Class::Persist::Base );
use Scalar::Util qw( blessed );
use Error qw(:try);

use overload '@{}' => '_get_elements', 'fallback' => 1;

__PACKAGE__->mk_accessors(qw( element_class owner_class owner_oid ));


=head2 owner

A collection has an owner - this is the owner that all the members of the
collection have.

=cut

# TODO - nasty code duplication from Persist.pm
sub owner {
  my $self = shift;
  if (@_) {
    my $owner = shift;
    my $changing = $self->get('owner_class') ? 1 : 0;

    # TODO - isn't _setting_ an owner from user code INCREDIBLY DANGEROUS?
    # we need to think about the whole re-parenting issue lots.

    Class::Persist::Error->throw( -text => "Not a class persist object" )
      unless blessed($owner) and $owner->isa("Class::Persist::Base");

    # setting a proxy as the owner? Inflate it.
    $owner = $owner->load if ($owner->isa("Class::Persist::Proxy"));

    # record the class of the owner, the oid of the owner only.
    # We can reconstruct a proxy that points at the owner very easily
    $self->set( owner_class => ref($owner) );
    $self->set( owner_oid => $owner->oid );
    
    # If we're _changing_ owners, reset the owners of all the elements
    if ($changing) {
      for (@{ $self->element }) {
        $_->owner($owner) or return;
      }
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


=head2 element

When called for the first time, create an array of proxies
representing the real objects. Returns a listref of the children
of the collection.

=cut

sub element {
  my $self = shift;
  if (@_) {
    $self->{ element } = shift;
    return $self;
  }
  $self->load() unless $self->{element};
  return $self->{element};
}

sub _get_elements {
  my $self = shift;
  return $self->element;
}

=head2 load()

Replace all the element by proxies

=cut

sub load {
  my $self   = shift;
  my $class  = $self->element_class
    or Class::Persist::Error::InvalidParameters->throw(
      -text => "A class should be defined in proxy");

  $self->loadModule( $class );

  my $owner = $self->owner
    or Class::Persist::Error::InvalidParameters->throw(
      -text => "A owner should be defined in proxy");

  my $ids = $self->_oids_for_owner( $class, $owner );
  my @element;
  foreach my $id (@$ids) {
    my $element;
    $element = $self->_object_cache->get( $id ) if $self->_object_cache;
    $element = Class::Persist::Proxy->new( class => $class, real_id => $id )
      unless $element;

    CORE::push @element, $element;
  }
  $self->element(\@element);
}


=head2 store()

Store any non proxy element in the collection and proxy it

=cut

sub store {
  my $self = shift;
  my $owner = $self->owner
    or Class::Persist::Error::InvalidParameters->throw(
      -text => "A owner should be defined in proxy");
  if (my $element = $self->{element}) {
    foreach my $elem (@$element) {
      next if $elem->isa('Class::Persist::Proxy');
      $elem->owner( $owner );
      $elem->store();
      Class::Persist::Proxy->proxy( $elem );
    }
  }
  $self;
}

=head2 count()

returns the number of elements in the collection

=cut

sub count {
  my $self = shift;
  return scalar @$self;
}

=head2 push( element )

add an element to the end of the collection

=cut

sub push {
  my $self = shift;
  my @elements = @_;
  my $owner = $self->owner;
  $_->owner($owner) for @elements;
  CORE::push @$self, @elements;
}

=head2 unshift( element )

add an element to the beginning of the collection

=cut

sub unshift {
  my $self = shift;
  my @elements = @_;
  my $owner = $self->owner;
  $_->owner($owner) for @elements;
  CORE::unshift @$self, @elements;
}

=head2 delete( $index )

Without parameter, delete all the elements of the collection.
If an index is given, deletes the related element.

Deletes elements recursively.

=cut

sub delete {
  my ($self, $index) = @_;
  $self->{element} or $self->load() or return;
  if (defined($index)) {
    my $obj = $self->[$index]
      or Class::Persist::Error->record(
        -text => "Cannot delete, element $index doesn't exist")
        and return;
    $obj->delete() or return;
    return splice( @$self, $index, 1);
  }
  else {
    if (my $element = $self->element) {
      foreach my $elem (@$element) {
        $elem->delete() or return;
      }
    }
    $self->element( [] );
  }
  1;
}


=head2 revert( [index] )

reverts either the given element (if index is passed) or all elements (if
not).

=cut

sub revert {
  my ($self, $index) = @_;
  $self->{element} or $self->load() or return;
  if (defined($index)) {
    return $self->element->[$index]->revert;
  }

  my @new_elements;
  foreach my $elem (@{ $self->element }) {
    try {
      $elem->revert() or return;
      CORE::push @new_elements, $elem;
    } catch Class::Persist::Error::Revert with {
      # this happens if the object isn't in the DB. But we're reverting
      # _us_, so the DB state here must be that we don't have a relationship
      # with that object.
      $elem->owner(undef);
    }
  }
  @{ $self->element } = @new_elements;
  return $self;
}

=head2 clone( new_owner, [index] )

With an index, clones and returns the clone of the indexed element.
Without, returns a Class::Persist::Collection that is a clone of itself,
containing clones of all its elements.

new_owner is the object that will own the new collection, and B<must>
be passed.

=cut

sub clone {
  my ($self, $new_owner, $index) = @_;
  Class::Persist::Error->throw(
    -text => "Collection has to have an owner" )
      unless $new_owner;
  Class::Persist::Error->throw(
    -text => "Owner must be Class::Persist object" )
      unless (blessed($new_owner) and $new_owner->isa("Class::Persist"));

  $self->{element} or $self->load() or return;
  if (defined($index)) {
    return $self->element->[$index]->clone;
  }
  my $clone = Class::Persist::Collection->new(
    element_class => $self->element_class,
    owner_class => ref($new_owner),
    owner_oid => $new_owner->oid,
  );
  foreach my $elem (@{ $self->element }) {
    my $c = $elem->clone( $new_owner ) or return;
    $clone->push( $c );
  }
  return $clone;
}





=head1 SEE ALSO

Class::Persist

=cut

1;
