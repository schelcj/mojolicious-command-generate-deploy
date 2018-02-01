package Mojolicious::Command::generate::deploy;

# ABSTRACT: turns baubles into trinkets
#
use Mojo::Base 'Mojolicious::Command';

use Data::Dumper;

has description => 'Generate deployment configurations with Rexify';
has usage => sub {shift->extract_usage};

sub run {
  my ($self) = @_;

  # TODO
  #   - need app name to write environments
  #   - create config/environments directories
  #   - write config/environments/testing.yaml
  #   - write config/environments/development.yaml
  #   - write Rexfile

  print Dumper $self;

}

1;

__DATA__

@@ config/environments/testing.yaml

@@ config/environments/development.yaml

@@ Rexfile
