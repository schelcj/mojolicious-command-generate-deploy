package Mojolicious::Command::generate::deploy;

# ABSTRACT: turns baubles into trinkets
#
use Mojo::Base 'Mojolicious::Command';

use Cwd;
use Mojo::File;
use Mojo::Loader 'data_section';
use Data::Dumper;

has description => 'Generate deployment configurations with Rexify';
has usage => sub {shift->extract_usage};

# TODO
# - maybe switch to File::Share instead of data section
# - detect if ran within a mojo application folder or not

sub run {
  my ($self) = @_;

  my $cwd = Mojo::File->new(getcwd());
  my $env_dir = $cwd->child('config', 'environments')->make_path;

  for (qw(development testing production)) {
    my $file     = qq(${_}.yaml);
    my $env_file = $env_dir->child($file);

    next if -e $env_file;

    say "Creating $_ environment file";
    $env_file->spurt(data_section(__PACKAGE__, $file));
  }

  my $rex_file = $cwd->child('Rexfile');
  unless (-e $rex_file) {
    say 'Creating Rexfile';
    $rex_file->spurt(data_section(__PACKAGE__, 'Rexfile'));
  }

  my $cpanfile = $cwd->child('cpanfile');
  unless (-e $cpanfile) {
    say 'Creating cpanfile';
    $cpanfile->spurt(data_section(__PACKAGE__, 'cpanfile'));
  }
}

1;

__DATA__

@@ cpanfile
requires 'Mojolicious';

@@ testing.yaml
---
  srv_user:      'mojo'
  moniker:       'REPLACEME'
  base_dir:      '/home/mojo/srv'
  releases_dir:  '/home/mojo/srv/releases'
  tmp_dir:       '/home/mojo/srv/tmp'
  log_dir:       '/home/mojo/srv/logs'
  build_dir:     'build'
  current_lnk:   '/home/mojo/srv/current'
  previous_lnk:  '/home/mojo/srv/previous'
  pid_file:      '/home/mojo/srv/tmp/hypnotoad.pid'
  servers:       'test.local'

@@ development.yaml
---
  srv_user:      'mojo'
  moniker:       'REPLACEME'
  base_dir:      './'
  releases_dir:  './'
  asset_dir:     './'
  tmp_dir:       '/tmp'
  log_dir:       './'
  build_dir:     'build'
  current_lnk:   ''
  previous_lnk:  ''
  servers:       'localhost'

@@ production.yaml
---
  srv_user:      'mojo'
  moniker:       'REPLACEME'
  base_dir:      '/home/mojo/srv'
  releases_dir:  '/home/mojo/srv/releases'
  tmp_dir:       '/home/mojo/srv/tmp'
  log_dir:       '/home/mojo/srv/logs'
  build_dir:     'build'
  current_lnk:   '/home/mojo/srv/current'
  previous_lnk:  '/home/mojo/srv/previous'
  pid_file:      '/home/mojo/srv/tmp/hypnotoad.pid'
  servers:       'test.local'

@@ Rexfile
# vim: set ft=perl

use Rex -base;
use Rex::Commands::File;
use Rex::Commands::Fs;
use Rex::Commands::Rsync;
use Rex::Commands::User;
use Rex::CMDB;

use Cwd qw(abs_path getcwd);
use YAML qw(LoadFile);

key_auth;
private_key "$ENV{HOME}/.ssh/id_rsa";
public_key  "$ENV{HOME}/.ssh/id_rsa.pub";

unless (is_file("$ENV{HOME}/.ssh/id_rsa")) {
  die "Please generate a ssh key pair with `ssh-keygen` before proceeding";
}

set 'release' => time();

set cmdb => {
  type => 'YAML',
  path => [
    'config/environments/{environment}.yml',
  ],
  merge_behavior => 'LEFT_PRECEDENT',
};

for (qw(staging production development)) {
  environment $_ => sub {
    my $env     = cmdb;
    my $release = get 'release';

    user $env->{value}->{srv_user} // $ENV{USER};
    group 'servers' => $env->{value}->{servers};

    set 'moniker'       => $env->{value}->{moniker};
    set 'credentials'   => "$ENV{HOME}/$env->{value}->{credentials}";
    set 'release_dir'   => "$env->{value}->{releases_dir}/$release";
    set 'server'        => $env->{value}->{servers};
    set 'pid_file'      => $env->{value}->{pid_file};

    for (qw(base_dir asset_dir tmp_dir log_dir build_dir releases_dir)) {
      set $_ => $env->{value}->{$_};
    }

    for (qw(current_lnk previous_lnk)) {
      set $_ => $env->{value}->{$_};
    }
  };
}

set 'db_pass' => _prompt('db_pass', 'Oracle Password: ', 1);

task 'setup', group => 'servers' => sub {
  my $params = shift;
  my $user   = get 'user';

  for (qw(base_dir release_dir tmp_dir log_dir )) {
    my $dir = get $_;
    file $dir, ensure => 'directory', owner => $user;
  }
};

task 'build_release', sub {
  my $params    = shift;
  my $build_dir = get 'build_dir';
  my $release   = get 'release';

  if (is_dir($build_dir)) {
    rmdir $build_dir;
  }

  unless (exists $params->{release}) {
    $release = 'master';
  }

  file $build_dir,
    ensure => 'directory';

  run "git archive $release | tar -C $build_dir -xf -";
};

task 'sync_release', group => 'servers' => sub {
  my $params      = shift;
  my $release_dir = get 'release_dir';
  my $build_dir   = get 'build_dir';
  my $user        = get 'user';
  my $server      = get 'server';

  # XXX - this will throw a warning about redundant sprintf args.
  #       looks like a bug in Rex::Commands::Rsync. Hopefully, it
  #       gets corrected in a new release.
  sync "$build_dir/", $release_dir, {
    exclude => '*.git*',
  };
};

task 'install_perl_deps', group => 'servers' => sub {
  my $params      = shift;
  my $release_dir = (environment eq 'development') ? getcwd() : get 'release_dir';

  my $carton_cmd = case environment, {
    production => "carton install --deployment",
    testing    => "carton install --deployment",
    default    => "carton install",
  };

  run $carton_cmd,
    cwd => $release_dir,
    env => {
      ORACLE_HOME => '/usr/lib/oracle/11.2/client64', # TODO - get from login profile somehow
    };
};

task 'setup_config', group => 'servers' => sub {
  my $params = shift;

  use Data::Dumper;
  $Data::Dumper::Terse = 1;

  my $moniker     = get 'moniker';
  my $release_dir = get 'release_dir';
  my $tmp_dir     = get 'tmp_dir';

  my $mode = case environment, {
    prod       => 'production',
    production => 'production',
    test       => 'testing',
    testing    => 'testing',
    staging    => 'staging',
  };

  my $file = "$moniker.$mode.conf";
  unless (is_file($file)) {
    $file = "$moniker.conf";
  }

  my $config = do $file;
  $config->{hypnotoad}->{pid_file} = get 'pid_file';
  $config->{db}->{pass}            = get 'db_pass';

  for (keys %{$config->{paths}}) {
    my $dir = get "${_}_dir";

    if ($dir) {
      $config->{paths}->{$_} = $dir;
    }

    file $config->{paths}->{$_}, ensure => 'directory';
  }

  file "$release_dir/$moniker.$mode.conf",
    content => Data::Dumper->Dump([$config]);
};

task 'set_previous_link', group => 'servers' => sub {
  my $params      = shift;
  my $previous    = get 'previous_lnk';
  my $current_lnk = get 'current_lnk';

  if (is_symlink($current_lnk)) {
    my $current = readlink $current_lnk;

    file $previous,
      ensure => 'absent';

    symlink($current, $previous);
  }
};

task 'set_current_link', group => 'servers' => sub {
  my $params      = shift;
  my $release_dir = get 'release_dir';
  my $current     = get 'current_lnk';

  if (is_symlink($current)) {
    rm($current);
  }

  symlink($release_dir, $current);
};

task 'set_log_link', group => 'servers' => sub {
  my $params = shift;

  my $release      = get 'release';
  my $release_dir  = get 'release_dir';
  my $log_dir      = get 'log_dir';
  my $release_logs = "$log_dir/$release";

  unless (is_dir($release_logs)) {
    file $release_logs, ensure => 'directory', owner => $user;
  }

  symlink($release_logs, "$release_dir/log");
};

task 'restart_app_server', group => 'servers' => sub {
  my $params = shift;

  my $user        = get 'user';
  my $moniker     = get 'moniker';
  my $pid_file    = get 'pid_file';
  my $current_lnk = get 'current_lnk';

  my $mode = case environment, {
    prod       => 'production',
    production => 'production',
    test       => 'testing',
    testing    => 'testing',
    staging    => 'staging',
  };

  run "$current_lnk/local/bin/hypnotoad $current_lnk/script/$moniker",
    env => {
      MOJO_MODE => $mode,
      PERL5LIB  => "$current_lnk/lib:$current_lnk/local/lib/perl5",
    };
};

task 'deploy' => sub {
  my $params = shift;

  my @tasks = (
    qw(
      setup
      build_release
      sync_release
      install_perl_deps
      setup_config
      set_previous_link
      set_current_link
      set_log_link
      restart_app_server
    )
  );

  if (exists $params->{release}) {
    my $releases_dir = get 'releases_dir';

    set 'release'     => $params->{release};
    set 'release_dir' => "$releases_dir/$params->{release}";
  }

  for (@tasks) {
    do_task $_, $params;
  }
};

sub _prompt {
  my ($field, $prompt, $hide) = @_;
  my $creds = get 'credentials';

  if (is_file($creds)) {
    my $results = LoadFile($creds);
    return $results->{$field} if exists $results->{$field};
  }

  print $prompt;
  run "stty -echo" if $hide;

  chomp(my $input = <STDIN>);

  run "stty echo" if $hide;
  print "\n" if $hide;

  return $input;
}
