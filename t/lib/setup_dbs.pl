#!perl
use strict;
use warnings;
use Test::More;
use File::Temp 'tempfile';

my @cleanup;

sub setup {
  my ($classname, $dbh, $dbname) = @_;
  $classname->dbh($dbh);
  eval {$classname->destroy_DB_infrastructure()};
  push @cleanup, sub {
    $classname->dbh($dbh);
    $dbh->disconnect;
  }
}

{
  my %served;
  my %max = (MySQL => 1, Pg => 1);
  sub db_factory {
    my $dbname = shift;
    my $dbh;
    die "Only know how to generate $max{$dbname} $dbname"
      if defined $max{$dbname} and ($served{$dbname}||0) >= $max{$dbname};

    if ($dbname eq 'SQLite') {
      # Can we manage a SQLite DB?
      my (undef, $dbfile) = tempfile();
      push @cleanup, sub {unlink $dbfile if -e $dbfile };

      # connect as if we're SQLite 2, with the null escaping - this is
      # ignored by later versions, so it's safe.
      return DBI->connect("dbi:SQLite:dbname=$dbfile", '', '',
        { AutoCommit => 1,
          PrintError => 0,
          sqlite_handle_binary_nulls=>1
        });
    } elsif ($dbname eq 'SQLite2' ) {
      # Can we manage a SQLite2 DB?
      my (undef, $dbfile) = tempfile();
      push @cleanup, sub {unlink $dbfile if -e $dbfile };

      return DBI->connect("dbi:SQLite2:dbname=$dbfile", '', '',
        { AutoCommit => 1,
          PrintError => 0,
          sqlite_handle_binary_nulls=>1 # needed for BLOB storage
        });
    } elsif ($dbname eq 'MySQL') {
      $dbh = DBI->connect('DBI:mysql:database=test', '', '',
        {PrintError => 0});
    } elsif ($dbname eq 'Pg') {
      # Warn=>0 to silence those
      # "NOTICE:  CREATE TABLE / PRIMARY KEY will create implicit index ...
      # messages
      $dbh = DBI->connect("dbi:Pg:dbname=test", '', '',
        {PrintError => 0, Warn=>0});
    } else {
      die "Unknown DB name $dbname";
    }
    $served{$dbname}++;
    return $dbh;
  }
}

sub test_sub_with_dbs {
  my ($classname, $db_names, $sub) = @_;
  $classname ||= 'Class::Persist';
  $db_names ||= [qw (SQLite2 SQLite MySQL Pg)];
  my $dbs;

  foreach my $name (@$db_names) {
    my $dbh = eval {db_factory($name)};

    if ($dbh) {
      $dbs++;
      setup ($classname, $dbh, $name);
      &$sub($dbh, $name);
      &$_ for @cleanup;
      @cleanup = ();
    }
  }
  fail ("No DBs found to test with") unless $dbs;
}

1;
