package ParentTest;
use warnings;
use strict;
use base qw( Class::Persist );

__PACKAGE__->db_table('test' .$$ .  int(rand(1000)). 'parent');
__PACKAGE__->simple_db_spec(
  name => "VARCHAR(10)",
  one => 'CPTest::',
  many => ['CPTest'],
);
__PACKAGE__->mk_accessors(qw(
  name one many might bin clock
));

1;
