#!perl
package BlobTest;
use warnings;
use strict;
use Class::Persist::Blob;
use base qw( Class::Persist::Blob );

__PACKAGE__->db_table('test' .$$ . int(rand(1000)). 'Blob');
__PACKAGE__->simple_db_spec(
  tail => "VARCHAR(30)",
);

__PACKAGE__->blob_fields(qw( bananas ));

__PACKAGE__->mk_accessors(qw( tail bananas ));

1;
__END__
=head1 Test class for Class::Persist
