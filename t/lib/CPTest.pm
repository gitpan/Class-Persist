package CPTest;
use warnings;
use strict;
use base qw( Class::Persist );

__PACKAGE__->db_table('test' .$$ . int(rand(1000)). 'cptest');
__PACKAGE__->simple_db_spec(
  colour => 'VARCHAR(63)',
  peel => 'INT',
  bin => 'BLOB',
  clock => "DateTime",
);
__PACKAGE__->mk_accessors(qw(colour peel clock bin));

sub db_inflate_peel {
  my ($self, $db_value) = @_;
  $self->set( peel => $db_value ? "Peeled" : "Not Peeled" );
  return $self;
}

sub db_deflate_peel {
  my $self = shift;
  my $peel = $self->get("peel") or return 0;
  return 1 if $peel eq 'Peeled';
  return 0;
}

1;
__END__
=head1 Test class for Class::Persist
