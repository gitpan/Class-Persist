=head1 NAME

Class::Persist::Blob - More flexible Class::Persist subclass

=head1 DESCRIPTION

If you want to store lots of complicated data in your object, and you
don't want to have to go to the trouble of creating database columns
for it all, your object can subclass Class::Persist::Blob instead
of Class::Persist. Class::Persist::Blob will store specified properties
of your object in the database in the same way as Class::Persist, but
will B<also> use Storable to save other properties into a BLOB in the
database, in a column called 'dump'. When you retrieve the object later,
these properties will be inflated from the dump column and returned to you.

=head1 SYNOPSIS

  package My::Complicated;
  use base qw( Class::Persist::Blob );
  __PACKAGE__->db_table("some_table");
  __PACKAGE__->simple_db_spec( name => "CHAR(30)" );
  __PACKAGE__->blob_fields(qw( age list ));

  package main;
  my $complicated = My::Complicated->new;
  $complicated->set( name => "Dave" );
  $complicated->set( age => "20" );
  $complicated->set( list => [ 1, 2, 3, 4 ] );
  $complicated->store;

  my $oid = $complicated->oid;
  my $copy = My::Complicated->load( $oid );
  print $copy->get('age'); # prints 20
  print Dumper($copy->get('list')); # prints the list

You can store most arbitrarily complicated things in an object, anything
Storable can store will work. This means no dbhs, etc, of course.

=head1 LIMITATIONS

There are several limitations of using Class::Persist::Blob - it's not
magic. The main one is that you can only use the search() function to
search in columns that are actually stored in the database. Also, you
can't store magic things in the object, database handles, apache
requests, etc.

We use the db column 'blob' to store the data. Make sure your app doesn't
need this.

=cut

package Class::Persist::Blob;
use warnings;
use strict;
use Class::Persist;
use base qw( Class::Persist );
use Storable qw( nfreeze thaw );

__PACKAGE__->simple_db_spec(
  dump => "BLOB",
);

=head2 blob_fields( field list )

Declare, for this package, all the fields that you want stored into the
blob column.

=cut

sub blob_fields {
  my $self  = shift;
  @{$self->_fields_access('blob', @_) || []};
}

=head2 blob_fields_all()

Returns a list of all blob fields that this class and all its superclasses use.

=cut

sub blob_fields_all {
  my $self  = shift;
  @{$self->_fields_access_all('blob', @_)};
}

sub db_inflate_dump {
  my ($self, $db_value) = @_;
  my $data = thaw($db_value);
  $self->{$_} = $data->{$_} for ( $self->blob_fields_all );
  return $self;
}

sub db_deflate_dump {
  my $self = shift;
  my $data = {};

  $data->{$_} = $self->get($_) for ($self->blob_fields_all);
  return nfreeze($data);
}

1;
