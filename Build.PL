#!/usr/bin/perl
use strict;
use warnings;
use Module::Build;
my $build = Module::Build->new(
  module_name => 'Class::Persist',
  license     => 'perl',
  requires    => {
    'perl' => 5.008,
    'Class::Accessor::Chained' => 0,
    'Class::Data::Inheritable' => 0,
    'Error' => '0.15',
    'DateTime' => "0.21",
    'DBI' => '0.01',
    'UNIVERSAL::require' => '0.01',
    "Data::UUID" => "0.01",
  },
  build_requires => {
    'DBD::SQLite'  => 0,
    'Test::Pod'    => '1.00',
    'Test::Simple' => 0,
    'Test::More'   => 0,
    'File::Find::Rule' => 0,
  },
  create_makefile_pl => 'traditional',
  create_readme => 1,
)->create_build_script();
