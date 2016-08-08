#! perl

use strict;
use warnings;

# 全自動で同期する
#  指定は相互のディレクトリ名(できればフルパス）
#  両方にファイルがあったら、新しいファイルでコピー
#  ないファイルが見つかったら、ディレクトリの更新時刻を見て新しい方に合わせて削除・コピー
#  ファイルとディレクトリが違っていて両方にあったら、エラーをログに出力（ディレクトリ側はもう入らない）
#  ディレクトリ、ファイル、symlink以外（？）は、エラーをログに出力

my (%OPTS, %OPTS_RAW);

use Getopt::Long;

my @ORG_ARGV = @ARGV;

GetOptions(\%OPTS_RAW,
	   'dryrun',
	   'shallow',
	   'service:i', # [interval]
	   'ldustbox=s',
	   'rdustbox=s',
	   'config=s',  # conf_file
	   'statuslog=s',	# log_file
	   'log=s',	# log_file
	   'mapping=s', # mapping_file
	   'diffrelax=i',	# sec
	   'verbose=i',	# 0: no message, 1: minimal, 2: verbose
	   'encode=s',
	   'except=s',	# pattern
);


# remote local [day_limit]

my $ERROR=0;
my $INFO=1;
my $LOG=2;
my $DEBUG=3;
my $STATUS1=4;
my $STATUS2=5;


my $before_log = "";
my $last_size = 0;

my $log_count = 0;

# initialize LOG filehandle
    open LOG, ">/dev/null";
    open STATUSLOG, ">/dev/null";

#######
### agelog
#######

my $AGELOG_MES = "";

sub next_file( $$$ ) {
  my ( $body, $count, $ext ) = @_;
  if ( not defined($OPTS{".agelogformat"}) ) {
    my $len = ( $OPTS{agelogmax} < 100 ? 2 : length($OPTS{agelogmax}) );
    $OPTS{".agelogformat"} = "%s_%0${len}d%s";
  }
  sprintf($OPTS{".agelogformat"}, $body, $count, $ext);
}
sub rm_next_next_file ( $$$ ) {
  my ( $body, $count, $ext ) = @_;
  $count++;
  my ( $next_next_file ) = next_file( $body, $count, $ext);
  if ( -e $next_next_file ) {
    $AGELOG_MES .= "<time>agelog: /bin/rm $next_next_file\n";
    system("/bin/rm $next_next_file");
  }
}

sub next_aLOG_file ( $ ) {
  my ( $file ) = @_;

  use File::Basename;
  my ($basename, $dirname, $ext) = fileparse($file, qr/\.[^.]*/);
  my ($body) = "$dirname$basename";

  foreach my $count ( 0 .. $OPTS{agelogmax} ) {
    my $next_file = next_file( $body, $count, $ext);
    if ( not -e  $next_file ) {
      rm_next_next_file( $body, $count, $ext);
      return $next_file
    }
  }
  my $count = "00";
  my $next_file = next_file( $body, $count, $ext);
  rm_next_next_file( $body, $count, $ext);
  return $next_file
}

sub archive_LOG () {
  if ( not defined $OPTS{log} or not defined $OPTS{agelogmax} ) {
    return;
  }

  flush LOG;
  my $nextfile = next_aLOG_file( $OPTS{log});
  $AGELOG_MES .= sprintf( "<time>agelog: %s %s %s\n", "/bin/cp", $OPTS{log}, $nextfile );
  if (system("/bin/cp", $OPTS{log}, $nextfile ) == 0) {
    $AGELOG_MES .= sprintf( "<time>agelog: reopen  %s\n", $OPTS{log});
    open(LOG, ">", $OPTS{log});
  }
}

sub count_line ( $ ) {
  my ( $mes ) = @_;
  my @c =  ($mes =~ /\n/g);
  return @c+0;
}

#####
### LOG
#####

sub out_LOG ( $$@ );

sub out_LOG ( $$@ ) {
    my ( $level, $format, @args ) = @_;

    use POSIX qw/strftime/;
    my $date = strftime "%y/%m/%d_%H:%M:%S: ", localtime;

    my $mes;
    if (!defined($format)) {
	$mes = "out_LOG\n";
    } else {
	$mes = sprintf($format, @args);
    }
    $mes =~ s/<time>/$date/g;
    $mes = $date . $mes;

    if ( $level == $STATUS1 ) {
      print STATUSLOG $mes, "\n";

      $before_log = "";
      print STDERR ' ' x $last_size . "\r";
      print STDERR $mes;
      print STDERR "\r";
      $last_size = length( $mes );
    } elsif ( $level == $STATUS2 ) {
      print STATUSLOG $mes;
      $before_log = $mes;
#      print STDERR "debug: before_log='$mes'\n";
    } else {
      if ( $OPTS{log} and $level <= $INFO) {
	$log_count += count_line($before_log);
	$log_count += count_line($mes);
	if ( defined($OPTS{ageloglines}) and $log_count > $OPTS{ageloglines} ) {
	  $AGELOG_MES = '';
	  $AGELOG_MES .= sprintf( "<time>agelog: log lines exceed ageloglines: %d > %d\n", $log_count, $OPTS{ageloglines} );

	  archive_LOG();
	  $log_count = 0;
	  out_LOG $INFO, "%s", $AGELOG_MES;
	  $AGELOG_MES = '';
	}
	print LOG $before_log;
	print LOG $mes;
      }
      if ( $level <= $OPTS{verbose} ) {
	print STDERR ' ' x $last_size . "\r";
	print STDERR $before_log;
	print STDERR $mes;
	print STATUSLOG $mes, "\n";
	$before_log = "";
	$last_size = 0;
      }
#      print STDERR "debug: level= $level mes='$mes' before_log='${before_log}' \n";
    }
  }

# コンソールの状態
#   1. 行頭にあって、行には何も表示していない
#   2. 行頭にあって、行に表示されている
#   エントリーポイントは 1.
#   消されてもよい1行を表示すると2.
#   1.の状態で、
#     消されても良い1行 ⇒ そのまま出力して 2.
#     消されても良い複数行 ⇒ バッファリングして 1.のまま
#     消されてはいけない行 ⇒ バッファを書いて1.
#   2.の状態で、
#     消されても良い1行 ⇒ 行をクリアしてから、出力して 2.
#     消されても良い複数行 ⇒ バッファリングして 2.のまま
#     消されてはいけない行 ⇒ 行をクリアしてから、バッファを書いて1.


# 消されても良い1行の情報は、
#   表示した後で行頭に戻る(\r)
#   次に消されても良い情報が来たら、古いものを上書きする
#   ログは、statuslogだけ出力する

#   コンソールには、"            \r"を出力。次に何か出力する前に "                         \n"を出力
#   次のハートビートは、コンソールには、"            \r"を出力。次に何か出力する前に "                         \n"を出力
sub oneline_stauts_LOG ( $$@ ) {
  my ( $format, @args ) = @_;

  use POSIX qw/strftime/;
  my $date = strftime "%y/%m/%d_%H:%M:%S: ", localtime;

  my $mes;
  if (!defined($format)) {
    $mes = "out_LOG\n";
  } else {
    $mes = sprintf($format, @args);
  }
  $mes = $date . $mes;

  print STATUSLOG $mes,"\n";

  $before_log = "";
  print STDERR ' ' x $last_size . "\r";
  print STDERR $mes;
  $last_size = length( $mes );
  print STDERR "\r";
}

# 消されても良い複数行の情報は、
#   必要になるまでメモリに入れておき、必要になったら（消されてはいけない情報を出力する時に）出力する。消されても良い情報を出力する時には古いものは出力せずに消す。
#   ログは、statuslogにすぐに出力する
sub multiline_status_LOG ( $ ) {
    my ( $format, @args ) = @_;

    use POSIX qw/strftime/;
    my $date = strftime "%y/%m/%d_%H:%M:%S: ", localtime;

    my $mes;
    if (!defined($format)) {
	$mes = "out_LOG\n";
    } else {
	$mes = sprintf($format, @args);
    }
    $mes = $date . $mes;

    print STATUSLOG $mes;

    $before_log = $mes;
}

sub normal_LOG ( $ ) {
}

# 消されてはいけない情報は、
#   消されても良い１行の情報を上書きし、過去の消されても良い複数行の情報を出力し、本当の出力をする
#   ログは、過去の消されても良い複数行の情報を出力し、本当の出力を 更新ログに出力する。


# ハートビート: 消されても良い1行
# エラー: 消されてはいけない情報
# 更新: 消されてはいけない情報
# 設定情報: 消されてはいけない情報
# 動作情報: 消されても良い複数行の情報
# デバッグ用情報: 消されてはいけない情報

sub out_HB ( $ ) {
# ハートビートを出す。
# ログには、
# コンソールには、"            \r"を出力。次に何か出力する前に "                         \n"を出力
}

sub open_LOG ( $ ) {
  my ( $file ) = @_;
  $log_count = 0;
  if ( $file ) {
    open LOG, "<", $file;
    while ( <LOG> ) {
      $log_count++;
    }
    open LOG, ">>", $file;
    LOG->autoflush(1);
    out_LOG $DEBUG, "agelog: log_count=%d\n", $log_count;
  } else {
    open LOG, ">", "/dev/null";
  }
}


sub read_file ( $ ) {
  my ($file) = @_;
  if ( open( my $filehandle, "<", $file ) ) {
    local $/;
    my $content = <$filehandle>;
    close $filehandle;
    return $content;
  }
}

sub read_jsonfile ( $ ) {
  my ($file) = @_;
  my $confstring = read_file( $file );
  my $conf;
  if ( defined($confstring) ) {
    $@="";
    eval {
      $conf = JSON->new->relaxed->decode( $confstring );
    };
    if ($@) {
      $@ .= "Reading $file\n";
    }
  }
  return $conf
}

sub write_jsonfile ( $$ ) {
  my ($file, $content) = @_;
  use JSON::PP ();
  if (open( my $last_json, ">", $file ) ) {
    print $last_json JSON::PP->new->allow_blessed->as_nonblessed->pretty->encode( $content );
    close( $last_json );
  }

}

sub read_conf ( $;$ );

sub read_conf ( $;$ ) {
    # JSON
    # 上記オプションも、未セットなら入れる（--optの方が優先）
    # PATTERNSは構わず追加

    my ($file, $base) = @_;
    use JSON;

#    $JSON::BareKey = 1;
#    $JSON::QuotApos = 1;

    my $conf = read_jsonfile( $file );
    if ($@) {
      return;
    }

    if (! defined( $conf ) ) {
	# error!
	return;
    }
    return if (ref($conf) ne "HASH");

    if ( $conf->{opts}{config} ) {
        $@="";
	my $conf_in_conf = read_conf( $conf->{opts}{config} );
	if ( $@ ) {
#	  printf STDERR $@;
	  out_LOG $ERROR, $@;
	  $@="";
	}
	if ( $conf_in_conf ) {
	  $conf->{'.CONF'} = $conf_in_conf;
	}
    }

    use File::Spec;
    foreach my $dir ( @{ $conf->{files} } ) {
      if ( ref($dir) eq "" ) {
	# files に 文字列があれば、ディレクトリ名として解釈し、そこにある _sync_conf.txt を設定ファイルとして読み込む
	# $dir は $base からの相対パスも許可する
	if ( defined($base) ) {
	  $dir = File::Spec->rel2abs( $dir, $base ) ;
	}

	# "*" と書いたら、 $base/* それぞれで実行する
	foreach my $dir2 ( glob( $dir ) ) {
	  next if ( not -d $dir2 );
	  my $sub_file = "$dir2/_sync_conf.txt";
	  next if ( not -f $sub_file );
	  my $conf_in_file = # eval {
	    read_conf( $sub_file, $dir2 );
#	  };
	  if ( $@ ) {
	    out_LOG $ERROR, $@;
	    $@="";
	    next;
	  }
	  if ( $conf_in_file ) {
	    #	  $conf_in_file->{local} = $file;
	    $conf_in_file->{'.BASE'} = $dir2;
	    push @{ $conf->{'.FILES'} }, $conf_in_file;
	  }
	}
      }
    }
    return $conf;
}

sub opts_overwrite ( $$ ) {
    my ( $from_opts, $to_opts ) = @_;

    # キーを上書き
    foreach my $key ( keys( %{ $from_opts } )) {
	$to_opts->{$key} = $from_opts->{$key};
    }

}

sub is_prefix ( $$ ) {
  my ( $pre, $string ) = @_;
  return (substr($string, 0, length($pre)) eq $pre);
}

sub file_complete ( $$$ ) {
  my ( $file, $conf, $opts ) = @_;
  if ( ref($file) eq "HASH" ) {
    # localは.BASEからの相対参照を許す。
    # $file->{local} は $conf->{'.BASE'} からの相対参照で置き換える
    if ( defined( $conf->{'.BASE'} ) ) {
      $file->{local} = File::Spec->rel2abs( $file->{local}, $conf->{'.BASE'} ) ;
    }
    if ( defined $opts->{pattern} ) {
      foreach my $p ( @{ $opts->{pattern} } ) {
	if ( is_prefix( $p->{prefix}, $file->{ $p->{name} } ) )  {
	  while ( my ($k, $v) = each %{ $p->{add} } ) {
	    if ( not defined($file->{$k}) ) {
	      $file->{$k} = $v;
	    }
	  }
	}
      }
    }
    return 1;
  }
}

sub equal_object ( $$ ) {
  my ( $a, $b ) = @_;
  my $a_json = (defined($a) ? JSON->new->canonical->encode($a) : '');
  my $b_json = (defined($b) ? JSON->new->canonical->encode($b) : '');
  return ($a_json eq $b_json);
}


sub conf_final ( $$$ );
sub conf_final ( $$$ ) {
    my ( $files, $opts, $conf ) = @_;

    if ( defined($conf->{'.CONF'}) ) {
	conf_final( $files, $opts, $conf->{'.CONF'} );
    }

    # 上の層のoptsで上書き
    opts_overwrite( $conf->{opts}, $opts );

    # 上の層ので追加(push)
    if ( defined($conf->{files} ) ) {
	push @$files, (
#		       grep {
#			 if ( ref($_) eq "HASH" ) {
#			   # localは.BASEからの相対参照を許す。
#			   # $_->{local} は $conf->{'.BASE'} からの相対参照で置き換える
#			   if ( defined( $conf->{'.BASE'} ) ) {
#			     $_->{local} = File::Spec->rel2abs( $_->{local}, $conf->{'.BASE'} ) ;
#			   }
#			   # foreach $p ( @{ $conf->{pattern} } ) { if ($_->{$p->{name}} =prefix $p->{prefix}) { $p->{add}; last }}
#			   1;
#			 };
#		       }   @{ $conf->{files} }   );
		       grep { file_complete( $_, $conf, $opts) } @{ $conf->{files} }   );
      }

    use File::Spec;
    # $conf->{'.FILES'} からたどれるものを追加。
    if ( defined( $conf->{'.FILES'} ) ) {
      foreach my $f ( @{ $conf->{'.FILES'} } ) {
	my $dummy_opts = { %$opts };
	conf_final( $files, $dummy_opts, $f );
	if ( not equal_object( $dummy_opts, $opts)) {
	  out_LOG $ERROR, "options in sub-folder config is ignored: %s %s\n", $f->{'.BASE'}, JSON->new->pretty->canonical->encode($dummy_opts);
	  # $conf->{'.FILES'}{'.CONF'} は当面無視。使おうとするとファイルによって異なるoptsを使う結果になり、意味がややこしくなりすぎるので。
	  # いきなり$filesを更新せず、ここで得られたfiles に $dummy_optsを展開してからpushすればよい。
	  # いや、なかなか厄介だ。
	}
      }
    }
}

sub match ( $$ ) {
    my ($name, $pattern) = @_;
    my $res = ( $name =~ $pattern ) ;
    return $res;
#    foreach my $pat (@$patterns) {
#	if ($name =~ $pat) {
#	    return 1;
#	}
#    }
#    return 0;
}

sub match_2 ( $$ ) {
    my ($name, $pattern) = @_;
    if ($name eq "_last.json" or
	$name eq "_sync_conf.txt" or
	$name eq "_original" or
	$name =~ /\.conflict[0-9]{6}_[0-9]{6}/) {
      return 1;
    }
    return match($name, $pattern);
}

###
### local/remote string util
###

{
    my $remotetop;
    my $localtop;
    my $toptimestring;

    sub get_toptimestring () {
	$toptimestring;
    }

    my $toptimestring1;

    sub get_toptimestring1 () {
	$toptimestring1;
    }

    sub top_dir ( $$ ) {
	my ($r, $l) = @_;
	$remotetop = $r;
	$localtop = $l;

	use File::Basename;
	my $topbase = basename($localtop);

	use POSIX qw/strftime/;
	my $time = time();
	$toptimestring1 = strftime( "%y%m%d_%H%M%S", localtime($time));
	$toptimestring = sprintf("%s_%s", $toptimestring1,
				 $topbase);

	out_LOG $STATUS1, "LOCAL:  %s", $localtop;
	my $mes = "";
	$mes .= sprintf("---\n");
#	$mes .= sprintf("<time>REMOTE: %s\n", $remotetop);
	$mes .= sprintf("<time>LOCAL:  %s\n", $localtop);
	$mes .= sprintf("<time>toptimestring: %s\n", get_toptimestring());
	out_LOG $STATUS2, "%s", $mes;
    }

    sub remove_prefix( $$ ) {
	my ( $str, $pre ) = @_;
	my $str_pre = substr( $str, 0, length( $pre ) );
	if ( $str_pre eq $pre ) {
	    my $str_sub = substr( $str, length( $pre ) );
	    $str_sub =~ s!^[/\\]!! ;
	    return $str_sub;
	}
	return undef;
    }

    sub dir_part ( $ ) {
	my ( $dir ) = @_;
	my $subdir;
	$subdir = remove_prefix($dir, $remotetop);
	if ( defined($subdir) ) {
	    return "REMOTE", $subdir;
	}
	$subdir = remove_prefix($dir, $localtop);
	if ( defined($subdir) ) {
	    return "LOCAL", $subdir;
	}
	return "ABS", $dir;
    }
}

sub from_to_top ( $$ ) {
    my ($from_top, $to_top) = @_;
    if ($from_top eq "LOCAL" and $to_top eq "REMOTE") {
	return "LOCAL  -> REMOTE";
    } elsif ($from_top eq "REMOTE" and $to_top eq "LOCAL") {
	return "LOCAL  <- REMOTE";
    } else {
	return sprintf("%6s", $from_top);
    }
}

sub from_to_string ( $$ ) {
    my ($from, $to) = @_;
    my ($from_top, $from_sub) = dir_part( $from );
    my ($to_top,   $to_sub)   = dir_part( $to );
    if ( ($from_top eq "REMOTE" or $from_top eq "LOCAL") and
	 ($to_top   eq "REMOTE" or $to_top   eq "LOCAL") ) {
	my $from_to_top = from_to_top( $from_top, $to_top );
	if  ($from_sub eq $to_sub)  {
	    return sprintf("%s %s\n", $from_to_top, $from_sub);
	} else {
	    my $subdir = remove_prefix($from_sub, $to_sub);
	    if ( defined($subdir) ) {
		return sprintf("%s %s\n", $from_to_top, $from_sub);
	    } else {
		return sprintf("%s\n\t\t\t%s\t\t\t%s\n", $from_to_top, $from_sub, $to_sub);
	    }
	}
    } else {
	return sprintf("%6s -->%6s\n\t\t\t%s\t\t\t%s\n", $from_top, $to_top, $from_sub, $to_sub);
    }
}

sub dir_string ( $$ ) {
    my ($from,$mes) = @_;
    my ($from_top, $from_sub) = dir_part( $from );
    return sprintf("%-6s %-9s %s\n", $from_top, $mes, $from_sub);
}

###
### file utils
###

sub files ( $ ) { 
    my ( $dir ) = @_;
    # return @files, except ".", "..";

    opendir DIR, $dir
	or return;
    my @filenames = readdir DIR;
    closedir DIR
	or die "Cannot close dir $dir: $!";

    stat( "$dir/." )
	or die "Failed to re-stat dir $dir: $!";
    out_LOG $DEBUG, "%10s stat(%s)\n", "files re-stat", "$dir/." ;

    my @return;
    foreach my $f ( @filenames ) {
	if ( $f eq "." or $f eq ".." ) {
	    next;
	}
	push @return, $f;
    }
    return @return;
}

sub sort_uniq (@) {
    my (@files) = @_;

    @files = sort @files;

    my @return;
    my $last = "";
    for my $f ( @files ) {
	if ($f ne $last) {
	    push @return, $f;
	    $last = $f;
	}
    }
    return @return;
}


sub attr ( $ ) {
    my ( $file ) = @_;

    use File::stat;

    my $attr = stat( $file )
	or return;
    out_LOG $DEBUG, "%10s stat(%s)\n", "attr", $file ;

    attr_file($attr, $file);

    if ( -d $attr ) {
      attr_type($attr, "dir");
      opendir( my $tmp, $file )
	or  die "stat success but opendir fail: $file $!";
      if ( $tmp ) {
	closedir $tmp;
      } else {
	or  die "stat success but opendir sets null handler: $file";
      }
    } elsif ( -f $attr ) {
	attr_type($attr, "file");

	open( my $tmp, "<", $file )
	  or die "stat success but open fail: $file $!";
      if ( $tmp ) {
	close $tmp;
      } else {
	die "stat success but open sets null handler: $file";
      }
    } elsif ( -l $attr ) {
	attr_type($attr, "link");
    } else {
	attr_type($attr, "other");
    }
    return $attr;
}

#$!$!$! $$:$にして、$valをセットしないときを簡単に書けるようにすべき
sub attr_index ( $$$ ) {
    my ($attr, $val, $index) = @_;
    if (defined($val)) {
	$attr->[$index] = $val;
    }
    return $attr->[$index];
}

sub attr_type ( $;$ ) {
    my ($attr, $val) = @_;
    attr_index($attr, $val, 13) or "";
}

sub attr_file ( $;$ ) {
    my ($attr, $val) = @_;
    attr_index($attr, $val, 14);
}

sub attr_mtime ( $ ) {
    return( attr_index( $_[0], undef, 9) or 0 );
#    return $_[0]->mtime;

#    my ($attr) = @_;
#    if (attr_type($attr) eq 'dir' ) {
#	return $attr->mtime;
#    }
#
#    if ( $attr-> mtime > $attr->ctime ) {
#	return $attr->mtime;
#    } else {
#	return $attr->ctime;
#    }
}

sub attr_atime ( $ ) {
    return attr_index( $_[0], undef, 8);
#    return $_[0]->atime;
  }

sub attr_mtime_str ( $ ) {
  my ($attr) = @_;
  my ($mtime) = attr_mtime($attr);
  if ( $mtime ) {
    $mtime += 0;
    use POSIX qw/strftime/;
    return strftime( "%y/%m/%d %H:%M:%S", localtime($mtime));
#    return "".localtime( $mtime );
  } else {
    return "[NO TIME INFO]     ";
  }
}

# 二つのattrで更新時刻を比較して、以下を返す
#  同じなら 0
#  第一引数の方が新しければ +1
#  第二引数の方が新しければ -1
#  どちらかがundefならundef
sub newer ( $$ ) {
    my ( $a_attr, $b_attr ) = @_;
    # もしかしたら $a_attr eq "dir"の時は別の属性で比較するのかも。
    if (! defined($a_attr) or !defined($b_attr) ) {
      return undef;
    }
    if ( abs(attr_mtime($a_attr) - attr_mtime($b_attr)) < $OPTS{diffrelax} ) {
	return 0;
    } elsif ( attr_mtime($a_attr) - attr_mtime($b_attr) < 0 ) {
	return -1;
    } else {
	return 1;
    }
}

sub defined_newer ( $$ ) {
    my ( $a_attr, $b_attr ) = @_;
    if (! defined($a_attr) or !defined($b_attr) ) {
      return -1;
    }
    if ( abs(attr_mtime($a_attr) - attr_mtime($b_attr)) < $OPTS{diffrelax} ) {
	return 0;
    } elsif ( attr_mtime($a_attr) - attr_mtime($b_attr) < 0 ) {
	return -1;
    } else {
	return 1;
    }
  }

sub defined_older ( $$ ) {
    my ( $a_attr, $b_attr ) = @_;
    if (! defined($a_attr) and !defined($b_attr) ) {
      return 0;
    }
    if (! defined($a_attr) ) {
      return 1;
    }
    if (! defined($b_attr) ) {
      return -1;
    }
    if ( abs(attr_mtime($a_attr) - attr_mtime($b_attr)) < $OPTS{diffrelax} ) {
	return 0;
    } elsif ( attr_mtime($a_attr) - attr_mtime($b_attr) < 0 ) {
	return 1;
    } else {
	return -1;
    }
  }

sub choose_newer ( $$ ) {
  #$!$!$! うまくアクセスできないと、 24/05/20 15:07:31 (= 1716185251 )になってしまい、新しく見えてしまう
  #$!$!$! うまくアクセスできないと、 27/09/05 15:48:15 (= ???? )になってしまい、新しく見えてしまう
  #$!$!$! 2015/09/18_17:38:26にperlを起動すると、27/09/05 10:04:40になってしまう。全てではない //fileserv-kawa7だけ //nas.kawasaki, //teamsite //ueda-pc2 は大丈夫。different typeが出るのも//fileserv-kawa7.ad. だけ。同じユーザーによる複数のユーザー名での接続もそこだけ。perlの起動時に何かしているかも知れない。
  #$!$!$! 2015/09/18_17:48:26にperlを起動すると、27/09/05 10:04:40 スリープしたが関係ない
  #$!$!$! nowより1年以上未来だったら信用しないとかquickfix してみるか
    my ( $a_attr, $b_attr ) = @_;
    if (! defined($a_attr) or attr_mtime($a_attr) > time() + 3600*24*365 ) {
      return $b_attr;
    }
    if (! defined($b_attr) or attr_mtime($b_attr) > time() + 3600*24*365 ) {
      return $a_attr;
    }
    if ( abs(attr_mtime($a_attr) - attr_mtime($b_attr)) < $OPTS{diffrelax} ) {
	return $b_attr;
    } elsif ( attr_mtime($a_attr) - attr_mtime($b_attr) < 0 ) {
	return $b_attr;
    } else {
	return $a_attr;
    }
  }

sub newer_date ( $$ ) {
    my ($file_attr, $day_limit) = @_;

    if ( !defined($day_limit) ) {
	return 1;
    }

    # $file_attr - 今日の日付 < $day_limit なら true

    my $now = time();
    my $today = (sprintf("%d", ($now /60/60/24 )) + 1) *60*60*24 -1 - 9*60*60; # 今日の 23:59 の時刻 (JST)
    my $diff_time =  $today - attr_mtime($file_attr);
#    use DateTime;
#    my $diff_time =  DateTime->today()->epoch() - attr_mtime($file_attr);
    my $diff_days = sprintf("%d", $diff_time / 60 / 60 / 24); # 今日できたばかりのファイルは 0
    out_LOG $DEBUG, "newer_date %d<%d\n\t%s\n", $diff_days, $day_limit, attr_file($file_attr);
    return ($diff_days < $day_limit);

}


###
### file/dir operation
###


sub copy_file ( $$$$$;$$ ) {
    my ( $file, $src_attr, $dst, $dstdir, $day_limit, $dustbox, $last_files ) = @_;
    if ( match_2( $file, $OPTS{except} ) ) {
	return;
    }

    return if ( ! newer_date( $src_attr, $day_limit ) );
    my ($src) = attr_file($src_attr);

    # copy overwrite, copy timestamp (cp -p); or out_LOG if dryrun
    if ( $OPTS{dryrun} ) {
	out_LOG $INFO, "copy_file (dryrun) %s", from_to_string($src, $dst);
    } else {
      # 上書きする前にバックアップを取る
      if (defined($dustbox) and -e $dst ) {
	my ($dir_part) = dir_part($dst);
	out_LOG $DEBUG, " copy_file backup %s\n", $dir_part;
      	cpto_dustbox( $dst, $dustbox);
      }
	out_LOG $INFO, "copy_file   %-6s", from_to_string($src, $dst);
	use File::Path qw(make_path);
	make_path( $dstdir, {mode=>0777} );
	if ($OPTS{log} ) {
	    # ' を含むファイル名は失敗する
	    $src =~ s/'/'"'"'/g;
	    $dst =~ s/'/'"'"'/g;
#	    system("/bin/cp --preserve=timestamps,links '$src' '$dst' 2>&1 | /usr/bin/tee -a $OPTS{log}") == 0
#	      or die "copy_file failed: $src $dst: $!";

            # exit status は tee のものになるので、cpに失敗してもdieできない。
	    $? = 0;
	    my $msg = `/bin/cp --preserve=timestamps,links '$src' '$dst' 2>&1 `;
	    my $status = $?;
	    print STDERR $msg;
	    print LOG $msg;
	    if ( $status ) {
	      die "copy_file failed: $src $dst: $!";
	    }

	} else {
	    system("/bin/cp", "--preserve=timestamps,links", $src, $dst) == 0
	      or die "copy_file failed: $src $dst: $!";
	}
      $last_files->{$file} = $src_attr;
      my ($dirpart) = dir_part($dst);
      $last_files->{"/UPDATE_$dirpart"} = 1;
      $last_files->{"/last_update"} = 1;
    }
}

sub copy_tree ( $$$$ ) { #$!$!$! $local_filesを引数に取るべき
    my ( $file, $src_attr, $dstdir, $day_limit ) = @_;
    if ( match_2( $file, $OPTS{except} ) ) {
	return;
    }
    return if ( ! newer_date( $src_attr, $day_limit ) );
    my ($src) = attr_file($src_attr);

    # copy recursivly, preserve timestamp (cp -rp); or out_LOG if dryrun
    if ( $OPTS{dryrun} ) {
	out_LOG $INFO, "copy_tree   %s (dryrun)", from_to_string($src, $dstdir);
    } else {
	out_LOG $INFO, "copy_tree   %s", from_to_string($src, $dstdir);
	if ($OPTS{log} ) {
	  # ' を含むファイル名は失敗する
	    $src =~ s/'/'"'"'/g;
	    $dstdir =~ s/'/'"'"'/g;
	    # exit status は tee のものになるので、cpに失敗してもdieできない
#	    system("/bin/cp -r --preserve=timestamps,links '$src' '$dstdir' 2>&1 | /usr/bin/tee -a $OPTS{log}") == 0
#	      or die "copy_tree failed: $src $dstdir: $!";
#	    system("robocopy /e /dcopy:t '$src' '$dstdir' 2>&1 | /usr/bin/tee -a $OPTS{log}") == 0
#	    $dstdir/fileにしないといけない。$srcがフォルダじゃないといけない

	    $?=0;
	    my $msg = `/bin/cp -r --preserve=timestamps,links '$src' '$dstdir' 2>&1 `;
	    my $status = $?;
	    print STDERR $msg;
	    print LOG $msg;
	    if ( $status ) {
	      die "copy_tree failed: $src $dstdir : $!";
	    }


	} else {
	    system("/bin/cp", "-r", "--preserve=timestamps,links", $src, $dstdir) ==0
	      or die "copy_dir failed: $src $dstdir: $!";
#	    system("robocopy /e /dcopy:t '$src' '$dstdir'") == 0
#	    $dstdir/fileにしないといけない。$srcがフォルダじゃないといけない
	}
    }
}


{
    my $lasttime = 0;
    my $lastcount = 0;


    sub prepare_dustbox_dir ( $$ ) {
      my ($part, $dustbox) = @_;
	use File::Basename;
	my $partdir = dirname($part);
	my $partfile = basename($part);

	my $dest = sprintf("%s/%s", $dustbox, $partdir);

	use File::Path qw(make_path);
#	out_LOG $DEBUG, "prepare_dustbox_dir: make_path(%s, {mode=>0777} );\n", $dest;
	make_path($dest, {mode=>0777} );
      return $dest;
    }

    sub mvto_dustbox ( $$ ) {
	my ($dir, $dustbox) = @_;

	my ($top, $part) = dir_part( $dir ) ;

	my $dest = prepare_dustbox_dir($part, $dustbox);
#	use File::Basename;
#	my $partdir = dirname($part);
#	my $partfile = basename($part);
#
#	my $dest = sprintf("%s/%s", $dustbox, $partdir);
#
#	use File::Path qw(make_path);
##	out_LOG $INFO, "mvto_dustbox: make_path(%s, {mode=>0777} );\n", $dest;
#	make_path($dest, {mode=>0777} );
#
##	use File::Copy "mv";
##	out_LOG $INFO, "mvto_dustbox: mv( %s, %s );\n", $dir, $dest;
##	if (mv( $dir, $dest ) == 0) {
##	    out_LOG $ERROR, "$!\n";
##	}
##	out_LOG $INFO, qq[rename( %s, "%s/%s")\n],  $dir, $dest, $partfile;
##	if ( ! rename( $dir, "$dest/$partfile") ) {
##	    out_LOG $ERROR, "$!\n";
##	}
#
#
##       my ($top
#	out_LOG $INFO, "backup      %-6s %s\n", $top, $part;

#	out_LOG $INFO, "/bin/mv '%s' '%s'\n", $dir, $dest;
	# 動いたら動かす。からでなければ無視
#	system("/bin/mv '$dir' '$dest'") ==0
	system("/bin/mv",  $dir, $dest) ==0
	    or out_LOG $LOG, "mvto_dustbox failed: %s %s: %s", $dir, $dest, $!;

#	system("/bin/mv '$dir' '$dest'") == 0
#	      or die "mvto_dustbox failed: $dir $dest: $!";
    }

    sub cpto_dustbox ( $$ ) {
	my ($dir, $dustbox) = @_;

	my ($top, $part) = dir_part( $dir ) ;

	my $dest = prepare_dustbox_dir($part, $dustbox);

	out_LOG $INFO, "backup(cp)  %-6s [dustbox] %s\n", $top, $part;
#	out_LOG $INFO, "backup(cp)  %-6s           %s\n", $top, $part;
	# 動いたら動かす。からでなければ無視
	system("/bin/cp",  "--preserve=timestamps,links", $dir, $dest) ==0
	    or out_LOG $LOG, "cpto_dustbox failed: %s %s: %s", $dir, $dest, $!;
    }

    sub dustbox ( $ ) {
	my ( $base ) = @_;
	if ( ! defined($base) ) {
	    return $base;
	}

	my $dirname = sprintf("%s/%s", $base, get_toptimestring());
	return $dirname;
    }

}

sub delete_tree ( $$$;$ ) {
    use File::Path;

    my ( $file, $dir, $dustbox, $mes ) = @_;
    if ( match_2( $file, $OPTS{except} ) ) {
	return ;
    }
    $mes = "" if (not defined($mes));

    # rm -rf; or mv $dir $DUSTBOX; or out_LOG if dryrun
    if ( $OPTS{dryrun} ) {
	out_LOG $INFO, "delete      %s", dir_string($dir, $mes."(dryrun)" );
    } elsif ( $dustbox ) {
	out_LOG $INFO, "delete      %s", dir_string($dir, $mes."[dustbox]" );
	mvto_dustbox( $dir, $dustbox);
    } else {
	out_LOG $INFO, "delete      %s", dir_string($dir, $mes);
	File::Path::remove_tree( $dir );
    }
}

sub sync_mtime2 ( $$ ) {
    my ( $attr, $dest ) = @_; 
    if ( -d $dest ) {
      my ($dir_part, $subdir) = dir_part($dest);
      my $stat_dest = stat($dest)
	or die "failed to stat $dest";
      out_LOG $DEBUG, "%10s stat(%s)\n", "sync_mtime2", $dest ;

	if ( $OPTS{dryrun} ) {
	    out_LOG $LOG, "sync_mtime2 %-6s (%s -> %s) %s (dryrun)\n", $dir_part, attr_mtime_str($stat_dest), attr_mtime_str($attr), $subdir;
	} else {
	    out_LOG $LOG, "sync_mtime2 %-6s (%s -> %s) %s \n", $dir_part, attr_mtime_str($stat_dest), attr_mtime_str($attr), $subdir;
	    my($atime, $mtime) = (attr_atime($attr), attr_mtime($attr)); #($attr->atime, $attr->mtime); # (stat($src))[8,9];
	    utime $atime, $mtime, $dest
		or die "failed to set mtime $dest";
	}
    }
}



###
### file/dir operation
###

# ここで、@files_attr = sort { $a がfile, $b がdirなら、$aが先； 両方がfileか両方がdirなら、時間が新しい方(更新時刻の大きい方）が先};
{
  my %type_order = ( "file"  => 1,
		     "dir"   => 4,
		     "link"  => 2,
		     "other" => 3,
		     ""      => 5,
		   );

  sub sync_sort () {
    my $a_type = $type_order{attr_type($a->{attr})};
    my $b_type = $type_order{attr_type($b->{attr})};

    if ($a_type eq $b_type and $a_type != 5) {
      return attr_mtime($b->{attr}) <=> attr_mtime($a->{attr});
    } else {
      return $a_type <=> $b_type;
    }
  }
}

# _lastaccess.json 拡張のためのもの
# _lastaccess.json というファイルは転送除外
# ディレクトリにファイルスキャンフェーズに入ったら、ローカル側の _lastaccess.jsonを読む
# ディレクトリのファイルスキャンが終わったらローカル側の_lastaccess.jsonに書く

sub read_lastaccess ( $ ) {
  my ( $local ) = @_;
  use JSON -convert_blessed_universally;
  my $last_files = read_jsonfile( "$local/_last.json" );
  del_undefined_value( $last_files );
  undef $last_files->{"/UPDATE_REMOTE"};
  undef $last_files->{"/UPDATE_LOCAL"};
  undef $last_files->{"/last_update"};
  return $last_files;
}

sub write_lastaccess ( $$ ) {
  my ( $local, $last_files ) = @_;
  if ( $OPTS{drydun} ) {
    return;
  }

  if (	$last_files->{"/last_update"} ) {
    write_jsonfile("$local/_last.json", $last_files);
    $last_files->{"/UPDATE_LOCAL"} = 1;
    undef $last_files->{"/last_update"};
  }
}


# last locl remote
# 有   有   有	時間で比較
# 無   有   有	両方で作った(lastの書き込みに失敗したかも)！同じファイルなら無視、そうでなければコンフリクト！

# 有   有   無	remoteを消した
# 無   有   無	localで作った

# 有   無   有	localを消した
# 無   無   有	remoteで作った

# 有   無   無	両方で消した
# 無   無   無	起きない

# 時間で比較。小さい方が古い
# 1    1    1	同じファイル。何もしない
# 1    1    2	remoteで更新
# 1    2    1	localで更新
# 2    1    1	何故かlocalとremoteが元に戻った。lastの時刻をlocalに合わせて書き出す。

# 1    2    2	両方に新しいコピーを作った。lastの時刻をlocalに合わせて書き出す。
# 2    2    1	remoteが古い版に戻った。エラー
# 2    1    2	localが古い版に戻った。エラー

# 1    2    3	localとremoteで更新。コンフリクト！remoteが新しい。
# 1    3    2	localとremoteで更新。コンフリクト！localが新しい。
# 2    1    3	localは古い版に戻った。remoteは更新。エラー。
# 2    3    1	remoteは古い版に戻った。localは更新。エラー。
# 3    1    2	localもremoteも古い版だが、バージョンが違う。エラーでコンフリクト。
# 3    2    1	localもremoteも古い版だが、バージョンが違う。エラーでコンフリクト。

#=====================
# 1    1    2	remoteで更新
# 1    2    1	localで更新

# localとremoteが同じ時刻なら、lastの時刻をlocalに合わせて書き出す。ファイルのコピーはしない。
# 1    1    1	同じファイル。何もしない
# 2    1    1	localとremoteが元に戻った（たぶん手動作業）。lastの時刻をlocalに合わせて書き出す。
# 1    2    2	両方に新しいコピーを作った(lastの書き込みに失敗したかも)。lastの時刻をlocalに合わせて書き出す。

# local, remote, last の全てが違えばコンフリクト。エラーメッセージを出す。lastの時刻を変えない。
# 2    1    3	localは古い版に戻った。remoteは更新。エラーでコンフリクト。
# 2    3    1	remoteは古い版に戻った。localは更新。エラーでコンフリクト。
# 3    1    2	localもremoteも古い版だが、バージョンが違う。エラーでコンフリクト。
# 3    2    1	localもremoteも古い版だが、バージョンが違う。エラーでコンフリクト。
# 1    2    3	localとremoteで更新。コンフリクト！remoteが新しい。
# 1    3    2	localとremoteで更新。コンフリクト！localが新しい。

# localかremoteがlastより古ければ警告。コピーしない。lastの時刻は変えない
# 2    2    1	remoteが古い版に戻った。エラー（remoteをコピーすべきかも）
# 2    1    2	localが古い版に戻った。エラー(localをコピーすべきかも）

#=====================
# 有   有   有	時間で比較
# 無   有   有	両方で作った(lastの書き込みに失敗したかも)！同じファイルなら無視、そうでなければコンフリクト！
# last locl remote


# localかremoteがlastより古ければ警告。コピーしない。lastの時刻は変えない

sub eqtime ( $ ) {
  my ( $newer ) = @_;
  return ( defined($newer) and ($newer == 0) );
}

sub sync_file ( $$$$$$$$ ) {
  my ($remote_attr, $local_attr, $last_attr, $day_limit, $file, $remote, $local, $last_files) = @_;

  if ( match_2( $file, $OPTS{except} ) ) {
    return;
  }

  my $remote_file = "$remote/$file";
  my $local_file = "$local/$file";
  my $remote_newer = newer($remote_attr , $local_attr );
  my $remote_last  = newer($remote_attr , $last_attr );
  my $local_last   = newer($local_attr  , $last_attr );


  if ( eqtime($remote_newer) ) {
    # localとremoteが同じ時刻なら、lastの時刻をlocalに合わせて書き出す。ファイルのコピーはしない。
    # same file. do nothing
    if ( ! eqtime($local_last) ) {
# 1    2    2	両方に新しいコピーを作った(lastの書き込みに失敗したかも)。lastの時刻をlocalに合わせて書き出す。
# 2    1    1	localとremoteが元に戻った（たぶん手動作業）。lastの時刻をlocalに合わせて書き出す。
      out_LOG $DEBUG, " no update but no last:%s (LOCAL %s REMOTE %s)\n", $file, attr_mtime_str($local_attr), attr_mtime_str($remote_attr);
      $last_files->{$file} = $local_attr;
      $last_files->{"/last_update"} = 1;
    }
# 1    1    1	同じファイル。何もしない
    if (! newer_date( $local_attr, $day_limit ) ) {
#      out_LOG $INFO, "Older than day_limit: %s %s\n", $day_limit, attr_mtime_str($local_attr);
      delete_tree( $file, $local_file, undef, sprintf("[>%dD]",$day_limit) ); # day_limit超えたら、バックアップはしないで消してよい. dustbox($OPTS{ldustbox})
      undef $last_files->{$file};
      $last_files->{"/UPDATE_LOCAL"} = 1;
      $last_files->{"/last_update"} = 1;
    }
    return;
  }
  if ( !eqtime($remote_newer) and eqtime($local_last) ) {
# 1    1    2	remoteで更新
      out_LOG $DEBUG, " REMOTE updated:%s (LOCAL %s REMOTE %s LAST %s)\n", $file, attr_mtime_str($local_attr), attr_mtime_str($remote_attr), attr_mtime_str($last_attr);
    if ( $remote_newer < 0 ) {
# 2    2    1	remoteが古い版に戻った。警告出力して、remoteをコピー
      out_LOG $INFO, "sync_file remote is updated with old file (%s -> %s) %s\n", attr_mtime_str($local_attr),  attr_mtime_str($remote_attr), $file;
    }
    # localをremoteで上書きする前にバックアップを取る
    copy_file( $file, $remote_attr, $local_file, $local, $day_limit, dustbox($OPTS{ldustbox}) );
    $last_files->{$file} = $remote_attr;
      $last_files->{"/UPDATE_LOCAL"} = 1;
      $last_files->{"/last_update"} = 1;
    return;
  }
  if ( !eqtime($remote_newer) and eqtime($remote_last) ) {
      out_LOG $DEBUG, " LOCAL updated: %s (LOCAL %s REMOTE %s LAST %s)\n", $file, attr_mtime_str($local_attr), attr_mtime_str($remote_attr), attr_mtime_str($last_attr);
# 1    2    1	localで更新
    if ( $remote_newer > 0 ) {
# 2    1    2	localが古い版に戻った。警告出力して、localをコピー

    }
    # remoteをlocalで上書きする前にバックアップを取る
    copy_file( $file, $local_attr, $remote_file, $remote, undef, dustbox($OPTS{rdustbox}) );
    $last_files->{$file} = $local_attr;
      $last_files->{"/UPDATE_REMOTE"} = 1;
      $last_files->{"/last_update"} = 1;
    return;
  }

  if ( !eqtime($remote_newer) and !eqtime($remote_last) and !eqtime($local_last) ) {
# local, remote, last の全てが違えばコンフリクト。エラーメッセージを出す。lastの時刻を変えない。
# 2    1    3	localは古い版に戻った。remoteは更新。エラーでコンフリクト。
# 2    3    1	remoteは古い版に戻った。localは更新。エラーでコンフリクト。
# 3    1    2	localもremoteも古い版だが、バージョンが違う。エラーでコンフリクト。
# 3    2    1	localもremoteも古い版だが、バージョンが違う。エラーでコンフリクト。
# 1    2    3	localとremoteで更新。コンフリクト！remoteが新しい。
# 1    3    2	localとremoteで更新。コンフリクト！localが新しい。

    out_LOG $INFO, ("CONFLICT found:              %s\n".
		    "                     LOCAL  %s\n".
		    "                     REMOTE %s\n".
		    "                     LAST   %s\n\n" ) ,
		      $file, attr_mtime_str($local_attr),  attr_mtime_str($remote_attr), attr_mtime_str($last_attr);

    # コンフリクトの処理:
    #  localをコンフリクトファイルにして
    use File::Basename;
    my ($basename, $dirname, $extname) = fileparse($local_file, qr/\.[^.]*/);
    my $conflict_file = $basename . ".conflict" . get_toptimestring1() . $extname;
    my $conflict_path = $dirname . $conflict_file;
    my ($confl_top, $confl_sub) = dir_part( $conflict_path );
    # dryrunの時はrenameしない

    if ( $OPTS{dryrun} ) {
      out_LOG $INFO, "rename(dry) LOCAL [conflict] %s\n", $confl_sub;
    } else {
      out_LOG $INFO, "rename      LOCAL [conflict] %s\n", $confl_sub;
      rename( $local_file, $conflict_path);
    }

    #  remoteを転送。バックアップはしない
    #  lastはremoteを使う
    copy_file( $file, $remote_attr, $local_file, $local, $day_limit, undef, $last_files );

    # conflict_snapファイルを作る。diffをするならここで。
    if ( ! $OPTS{dryrun} ) {
      my $conflict_snap_path = $dirname .$basename . ".conflict" . get_toptimestring1() . "snap" . $extname;
      system("/bin/cp", "--preserve=timestamps,links", $local_file, $conflict_snap_path) == 0
	or die "copy_file failed: $local_file, $conflict_snap_path: $!";
    }

    $last_files->{$file} = $remote_attr;
    $last_files->{"/last_update"} = 1;
    #  コンフリクトファイルのlastを作ると、remoteでdeleteしたように見えてしまうのでしない。
#    $last_files->{$conflict_file} = $local_attr;
#    $last_files->{"/UPDATE_LOCAL"} = 1;
  }

}


sub check_rm_empty_daylimit ( $$$$ ) {
  my ($day_limit, $local, $file, $last_files) = @_;
  my @files = files( $local );
  @files = grep { not match_2( $_, $OPTS{except} ) } @files;
  if ( defined($day_limit) and not @files and -d $local ) {
    # daylimit 制限があって、空っぽになったディレクトリは削除する
    # _last.jsonはあっても無視する
    # $!$!$!: dryrun でも実行してしまう!!
    # rmdir( $local );
    delete_tree( '????', $local, dustbox($OPTS{ldustbox}) );
    undef $last_files->{$file};
    $last_files->{"/UPDATE_LOCAL"} = 1;
    $last_files->{"/last_update"} = 1;
  }
}

sub is_attr_type ( $$ ) {
  my ($attr, $type) = @_;
  my $attr_type = attr_type($attr);
#  return ( !defined($attr_type) or ($attr_type eq $type));
  return ( ($attr_type eq '')  or ($attr_type eq $type));
}

sub del_undefined_value ( $ ) {
  my ($hash) = @_;
  foreach my $k (keys(%$hash)) {
    if (! defined($hash->{$k})) {
      delete $hash->{$k};
    }
  }
}

sub prepare_typed_list_attr ( $$$$ ) {
  my ($local, $remote, $last_files, $dir_attr) = @_;
  my @files = ( files( $remote), files( $local ), keys( %$last_files ) );
  @files = grep { ! m[^/] } @files;
  @files = sort_uniq(@files);

  my @files_attr;
  push @files_attr, $dir_attr;
  foreach my $file (@files) {
    my $remote_file = "$remote/$file";
    my $local_file = "$local/$file";
    my $remote_attr = attr( $remote_file );
    my $local_attr = attr( $local_file );

    my $last_attr = $last_files->{$file};
    push @files_attr, {file => $file, remote_attr => $remote_attr, local_attr => $local_attr, last_attr => $last_attr, attr => ($local_attr or $remote_attr, or $last_attr) }; # attrはこの順で良い？
    # push @files_attr, {file => $file, remote_attr => $remote_attr, local_attr => $local_attr, attr => ($local_attr or $remote_attr) };
  }
  if ( ! defined( attr( $remote )) ) {
    die "connection broken $remote";
  }

  # ファイル名をタイプで分類して、それぞれ @変数に入れる
  my %typed_list_attr = ( "dir" => [], "file" => [], "link" => [], "others" => [], "mismatch" => [] );
 fileloop:
  foreach my $file (@files_attr) {
    foreach my $type ( "dir", "file", "link", "others" ) {
      if (is_attr_type($file->{local_attr}, $type) and
	  is_attr_type($file->{remote_attr}, $type) and
	  is_attr_type($file->{last_attr}, $type) ) {
	push @{ $typed_list_attr{$type} }, $file;
	next fileloop;
      }
    }
    push @{ $typed_list_attr{"mismatch"} }, $file;
  }
  return \%typed_list_attr;
}

sub typed_list_to_array ( $@ ) {
  my ( $typed_list_attr, @types ) = @_;
  my @files_others_attr = ();
  foreach my $type (@types) {
    push @files_others_attr, @{ $typed_list_attr->{$type} };
  }
  return  sort sync_sort @files_others_attr;
}

sub sync_dir_2 ( $$$$ );
sub sync_dir_2 ( $$$$ ) {
  # $remote_dir_newerの代わりに @files_attrの要素になる { file => ".", remote_attr => リモートディレクトリのattr, local_attr, last_attr, attr} を受け取る
  my ($remote, $local, $dir_attr, $day_limit ) = @_;
  if ($OPTS{verbose}) {
    my ($top, $subdir) = dir_part($remote);
    out_LOG $DEBUG, "enter dir: %s\n", $subdir;
  }
  # ここで _last.json を読む
  my $last_files = read_lastaccess( $local );

  my $typed_list_attr = prepare_typed_list_attr( $local, $remote, $last_files, $dir_attr);
#  my %typed_list_attr = ( "dir" => [], "file" => [], "link" => [], "others" => [], "mismatch" => [] );

  foreach my $file_attr ( typed_list_to_array($typed_list_attr, qw(mismatch) )) {
    my $file = $file_attr->{file};
    my $remote_attr = $file_attr->{remote_attr};
    my $local_attr = $file_attr->{local_attr};
    my $last_attr = $file_attr->{last_attr};
    my ( $top, $subdir ) = dir_part($remote);
    out_LOG $ERROR, "different type: %s/%s REMOTE(%s) LOCAL(%s) LAST(%s)\n",
      $subdir, $file,
	attr_type($remote_attr), attr_type($local_attr), attr_type($last_attr);
    # sync できなかったのだから、次の lastは消去
    delete $last_files->{$file};
    $last_files->{"/last_update"} = 1;
  }

  # othersとfileとlinkは同じ扱い
  foreach my $file_attr ( typed_list_to_array($typed_list_attr, qw(others file link) )) {
    my $file = $file_attr->{file};
    if ( match_2( $file, $OPTS{except} ) ) {
      next;
    }
    my $remote_file = "$remote/$file";
    my $local_file = "$local/$file";
    my $remote_attr = $file_attr->{remote_attr};
    my $local_attr = $file_attr->{local_attr};
    my $last_attr = $file_attr->{last_attr};

    if ( $remote_attr and $local_attr ) {
      # last locl remote
      # 有   有   有	時間で比較
      # 無   有   有	両方で作った(lastの書き込みに失敗したかも)！同じファイルなら無視、そうでなければコンフリクト！
#      out_LOG $DEBUG, " remote exists, local exists: %s\n", $file;

      sync_file($remote_attr, $local_attr, $last_attr, $day_limit, $file, $remote, $local, $last_files);

    } elsif ( $remote_attr and ! $local_attr ) {
      # remoteだけにある
      # last locl remote
      # 無   無   有	remoteで作った
      # 有   無   有	localを消した

      if ( ! $last_attr ) {
	# remoteで作った
      out_LOG $DEBUG, " remote exists, local not  : %s (no last)\n", $file;
	if ( defined( $day_limit ) ) {
	  copy_file( $file, $remote_attr, $local_file, $local, $day_limit, dustbox($OPTS{ldustbox}), $last_files );
	  # $last_filesはどうすればよい？特にday_limitが絡んだら => 中で更新してもらう
	  # $last_files->{$file} = $remote_attr;
	} else {
	  copy_tree( $file, $remote_attr, $local, $day_limit  );
	  $last_files->{$file} = $remote_attr;
	  $last_files->{"/last_update"} = 1;
	}
      } else {
	# remoteだけにあるが、localの親のディレクトリの方がremoteの親より新しい
	# localを消した
      out_LOG $DEBUG, " remote exists, local not  : %s (be last)\n", $file;
#	  # day_limitの期限内(指定されていなければ無期限）なら、$remote_attrを消し、期限外なら無視する。
        if ( newer_date( $remote_attr, $day_limit ) ) {
#	  out_LOG $INFO, "Older than day_limit: %s %s\n", $day_limit, attr_mtime_str($local_attr);
	  delete_tree( $file, $remote_file, dustbox($OPTS{rdustbox}) );
	  delete $last_files->{$file};
	  $last_files->{"/UPDATE_REMOTE"} = 1;
	  $last_files->{"/last_update"} = 1;
        }
      }
    } elsif ( $local_attr and ! $remote_attr ) {
      # localだけにある
      # last locl remote
      # 無   有   無	localで作った
      # 有   有   無	remoteを消した
      if ( ! $last_attr ) {
      out_LOG $DEBUG, " remote not   , local exists: %s (no last)\n", $file;
	# localで作った
	copy_tree( $file, $local_attr, $remote, undef  );
	$last_files->{$file} = $local_attr;
	$last_files->{"/UPDATE_REMOTE"} = 1;
	$last_files->{"/last_update"} = 1;
      } else {
      out_LOG $DEBUG, " remote not   , local exists: %s (be last)\n", $file;
	# remoteを消した
	# localだけにあるが、remoteの親のディレクトリの方がlocalの親より新しい
	delete_tree( $file, $local_file, dustbox($OPTS{ldustbox}) );
	delete $last_files->{$file};
	$last_files->{"/UPDATE_LOCAL"} = 1;
	$last_files->{"/last_update"} = 1;
      }
    } else {
      # last locl remote
      # 無   無   無	起きない
      # 有   無   無	両方で消した
      if ( ! $last_attr ) {
      out_LOG $DEBUG, " remote not   , local not   : %s (no last)\n", $file;
	delete $last_files->{$file};
	$last_files->{"/last_update"} = 1;
	die sprintf("both files are unaccessable: %s %s", $remote_file, $local_file);
      } else {
      out_LOG $DEBUG, " remote not   , local not   : %s (be last)\n", $file;
	delete $last_files->{$file};
	$last_files->{"/last_update"} = 1;
      }
      # both not exist
      # never happen
    }

  }

  # ここで、一度 last.jsonを書き出し
  write_lastaccess( $local, $last_files );

  foreach my $file_attr ( typed_list_to_array($typed_list_attr, qw(dir) )) {
    my $file = $file_attr->{file};
    if ( $file eq "." ) {
      next;
    }
    if ( match_2( $file, $OPTS{except} ) ) {
#      next;
    }

    my $remote_file = "$remote/$file";
    my $local_file = "$local/$file";
    my $remote_attr = $file_attr->{remote_attr};
    my $local_attr = $file_attr->{local_attr};
    my $last_attr = $file_attr->{last_attr};

    if ( $remote_attr and $local_attr ) {
      # last locl remote
      # 有   有   有	時間で比較
      # 無   有   有	両方で作った(lastの書き込みに失敗したかも)！同じファイルなら無視、そうでなければコンフリクト！
#      out_LOG $DEBUG, " remote exists, local exists: %s/\n", $file;

      my $attr = ( newer($remote_attr , $local_attr ) > 0 )
	? $remote_attr : $local_attr;
      my $this_dir_attr = { file => ".", remote_attr => $remote_attr, local_attr => $local_attr, last_attr => $last_attr,
			    #  以下は、sync_sortの時間順にする時に使う
			    attr => $attr };
#      if ( $OPTS{shallow} and defined($day_limit) and newer_date( $remote_attr, $day_limit ) ) {
	# skip deeper sync;
#      } else {
      # 両方あるなら、不要なものを消しに行かないと行けないので深く探しに行く
	sync_dir_2( $remote_file, $local_file, $this_dir_attr, $day_limit );
        if ( not defined($last_attr) or newer($attr, $last_attr) > 0 ) {
	  $last_files->{$file} = $attr;
	  $last_files->{"/UPDATE_REMOTE"} = 1;
	  $last_files->{"/last_update"} = 1;
        }
	check_rm_empty_daylimit($day_limit, $local_file, $file, $last_files);
#      }

      next;

    } elsif ( $remote_attr and ! $local_attr ) {
      # last locl remote
      # 無   無   有	remoteで作った
      # 有   無   有	localを消した
      if ( ! $last_attr ) {
      out_LOG $DEBUG, " remote exists, local not   : %s/ (no last)\n", $file;
	# remoteで作った
	if ( defined( $day_limit ) ) {
	  my $attr = $remote_attr; # remoteにしかないから
	  my $this_dir_attr = { file => ".", remote_attr => $remote_attr, local_attr => $local_attr, last_attr => $last_attr,
				#  以下は、sync_sortの時間順にする時に使う
				attr => $attr };
	  if ( $OPTS{shallow} and defined($day_limit) and not newer_date( $remote_attr, $day_limit ) ) {
	    # remoteにしかなくても、古いディレクトリは深く見なくて良い。
	  } else {
	    sync_dir_2( $remote_file, $local_file, $this_dir_attr, $day_limit );
#	    if  (not defined($last_attr) or  ( newer($attr, $last_attr) > 0) ) {
	    if  (-d $local_file ) {
	      $last_files->{$file} = $attr;
	      $last_files->{"/UPDATE_REMOTE"} = 1;
	      $last_files->{"/last_update"} = 1;
	    }
	    check_rm_empty_daylimit($day_limit, $local_file, $file, $last_files);
	  }
	  # $last_files->{$file} = $remote_attr;
	} else {
	  copy_tree( $file, $remote_attr, $local, $day_limit  );
	  $last_files->{$file} = $remote_attr;
	  $last_files->{"/UPDATE_LOCAL"} = 1;
	  $last_files->{"/last_update"} = 1;
	}
      } else {
	# localを消した
      out_LOG $DEBUG, " remote exists, local not   : %s/ (be last)\n", $file;
	if ( defined( $day_limit ) ) {
	  # day_limitがあっても、消したとわかっているなら消すべきな気がする。ディレクトリ名を修正したらduplicateしてしまうから
	  delete_tree( $file, $remote_file, dustbox($OPTS{rdustbox}) );
	  delete $last_files->{$file};
	  $last_files->{"/UPDATE_REMOTE"} = 1;
	  $last_files->{"/last_update"} = 1;

#	  # localのディレクトリの方が古い時と同じ処理をする
#	  my $attr = $remote_attr; # remoteにしかないから
#	  my $this_dir_attr = { file => ".", remote_attr => $remote_attr, local_attr => $local_attr, last_attr => $last_attr,
#				#  以下は、sync_sortの時間順にする時に使う
#				attr => $attr };
#	  if ( $OPTS{shallow} and defined($day_limit) and not newer_date( $remote_attr, $day_limit ) ) {
#	    # localを消したとしても、古いディレクトリは深く見なくて良い。
#	  } else {
#	    sync_dir_2( $remote_file, $local_file, $this_dir_attr, $day_limit );
#	    check_rm_empty_daylimit($day_limit, $local_file, $file, $last_files);
#	  }
	} else {
	  delete_tree( $file, $remote_file, dustbox($OPTS{rdustbox}) );
	  delete $last_files->{$file};
	  $last_files->{"/UPDATE_REMOTE"} = 1;
	  $last_files->{"/last_update"} = 1;
	}
      }
    } elsif ( $local_attr and ! $remote_attr ) {
      # last locl remote
      # 無   有   無	localで作った
      # 有   有   無	remoteを消した
      if ( ! $last_attr ) {
      out_LOG $DEBUG, " remote not   , local exists: %s/ (no last)\n", $file;
	copy_tree( $file, $local_attr, $remote, undef  );
	$last_files->{$file} = $local_attr;
	$last_files->{"/UPDATE_REMOTE"} = 1;
	$last_files->{"/last_update"} = 1;
      } else {
      out_LOG $DEBUG, " remote not   , local exists: %s/ (be last)\n", $file;
	# localだけにあるが、remoteの親のディレクトリの方がlocalの親より新しい
	delete_tree( $file, $local_file, dustbox($OPTS{ldustbox}) );
	delete $last_files->{$file};
	$last_files->{"/UPDATE_LOCAL"} = 1;
	$last_files->{"/last_update"} = 1;
      }
    } else {
      # last locl remote
      # 無   無   無	起きない
      # 有   無   無	両方で消した
      if ( ! $last_attr ) {
      out_LOG $DEBUG, " remote not   , local not   : %s/ (no last)\n", $file;
	delete $last_files->{$file};
	die sprintf("both files are unaccessable: %s %s", $remote_file, $local_file);
	$last_files->{"/last_update"} = 1;
      } else {
      out_LOG $DEBUG, " remote not   , local not   : %s/ (be last)\n", $file;
	delete $last_files->{$file};
	$last_files->{"/last_update"} = 1;
      }
      # both not exist
      # never happen
    }
  }

  # ここで、もう一度 last.jsonを書き出し
  write_lastaccess( $local, $last_files );

  # 古い方のディレクトリ($local or $remote)の mtimeを新しい方に合わせる
  # 今書き換えてしまったので、オリジナルの時刻（の新しい方）に両方を合わせる。
  my $this_attr = $dir_attr->{attr};

  if ( $last_files->{"/UPDATE_LOCAL"}  or newer( $dir_attr->{local_attr},  $this_attr) ) {
    sync_mtime2( $this_attr, $local ) ;
  }
  if ( $last_files->{"/UPDATE_REMOTE"} or newer( $dir_attr->{remote_attr}, $this_attr) ) {
    sync_mtime2( $this_attr, $remote ) ;
  }
}


sub sync ( $$$ );

sub sync ( $$$ ) {
    my ($remote, $local, $day_limit) = @_;
    my $remote_attr = attr( $remote );
    my $local_attr = attr( $local );

    if ( defined($remote_attr) and defined($local_attr) ) {
	if ( attr_type($remote_attr) ne attr_type($local_attr) ) {
	    out_LOG $STATUS1, "different type: %s(%s) %s(%s)\n",
		attr_file($remote_attr), attr_type($remote_attr),
		    attr_file($local_attr), attr_type($local_attr);
	    if ( $OPTS{ruser} and $OPTS{rpass} ) {
		my $rpass= $OPTS{rpass};
		my $path = attr_file($remote_attr);
		$path =~ s!/!\\!g;
		my $command = sprintf(q!net use '%s' '%s' '/user:%s'!, $path, $rpass, $OPTS{ruser});
#		out_LOG $INFO, "try reconnect: %s\n  %s\n", $path, $command; # パスワードが丸見え。ログにも残る
		out_LOG $INFO, "try reconnect: %s\n", $path;
		system($command);
		# 一度だけ再試行
		$OPTS{ruser} = undef;
		$OPTS{rpass} = undef;
		return sync($remote, $local, $day_limit);
	    }
	    die "Connection may broken!";
	}

	if ( attr_type($local_attr) eq "dir" ) {
	    top_dir( $remote, $local);
	    my $attr = ( newer($remote_attr , $local_attr ) > 0 )
	      ? $remote_attr : $local_attr;
	    my $this_dir_attr = { file => ".", remote_attr => $remote_attr, local_attr => $local_attr, last_attr => undef,
				  #  以下は、sync_sortの時間順にする時とに使う
				  attr => $attr };
	    sync_dir_2( $remote, $local, $this_dir_attr, $day_limit);

	    if ( not -e "$local/_original.lnk" ) {
	      out_LOG $INFO, "making $local/_original.lnk\n";
#	      symlink $remote, "$local/_original";	# windowsからアクセスできない。そもそも .lnk がついてないといけない
	      my $originalpath = `/bin/cygpath -w '$local/_original.lnk'`;   # まずパス変換
	      chomp $originalpath;
	      my $remotepath = `/bin/cygpath -w '$remote'`;   # まずパス変換
	      chomp $remotepath;
	      use FindBin qw($Bin);
	      my $cmd = "$Bin/Shortcut.CMD /t:'$remotepath' '$originalpath'";
	      out_LOG $DEBUG, "lnkcmd: %s\n", $cmd;
	      system( $cmd ); # 外部コマンドを使う。
#	      sync_mtime2( $this_dir_attr, $local ) ;	# this_dir_attr が arrayref じゃないと怒られる
	      sync_mtime2( $attr, $local ) ; 	# こっちかな？
	    }
#	    out_LOG $INFO, "top dir sync: newer  %s\n", attr_mtime_str($attr);
#	    out_LOG $INFO, "top dir sync: local  %s -> %s\n", attr_mtime_str($this_dir_attr->{local_attr}),  attr_mtime_str(attr( $local ));
#	    out_LOG $INFO, "top dir sync: remote %s -> %s\n", attr_mtime_str($this_dir_attr->{remote_attr}), attr_mtime_str(attr( $remote ));

	    return;
	}
	out_LOG $ERROR, "either not directory: %s(%s) %s(%s)\n",
	    attr_file($remote_attr), attr_type($remote_attr),
		attr_file($local_attr), attr_type($local_attr);
    } else {
	if ($remote_attr) {
	    out_LOG $ERROR, "local dir missing: %s\n",  $local;
	} else {
	    out_LOG $LOG,   "remote dir missing: %s\n",	$remote;
	}
    }
}

sub write_file ( $$ ) {
  my ($filename, $content) = @_;
  open my $f, ">", $filename;
  print $f  $content;
  close $f;
}

sub diff_log ( $$$ ) {
  my ($filename, $old, $now) = @_;
  my $oldfile = "${filename}_old";
  my $nowfile = "${filename}_now";

  write_file( $oldfile, $old);
  write_file( $nowfile, $now);

  my $diff = `/bin/diff --minimal --horizon-lines=7 -U 1 $oldfile $nowfile | /bin/sed 1,3d`; # possibly try diff --minimal
  system("/bin/rm $oldfile $nowfile");
  return "--- old; +++ now\n" . $diff;
}
my $lastStatuslogFile;

sub reload_conf ( ;$$ ) {
    my ($mes, $old_files) = @_;
    my ($myconf);

    my $old_files_json = defined($old_files) ?
	JSON->new->canonical->encode($old_files) :
	    '';
    my $old_files_json_print = defined($old_files) ?
	JSON->new->pretty->canonical->encode($old_files) :
	    '';
    my $old_OPTS_json  = JSON->new->canonical->encode(\%OPTS);

    $myconf->{opts} = \%OPTS_RAW;

    my $file;
    if ( $OPTS_RAW{config} ) {
        $file =  $OPTS_RAW{config};
    } else {
	use FindBin qw($Bin);
        $file =  "$Bin/sync_conf.txt";
    }

    $@ = "";
#    eval {
      $myconf->{'.CONF'} = read_conf( $file );
#    };
    if ( $@ ) {
      out_LOG $ERROR, $@;
#      printf STDERR $@;
      $@="";
    }
    if ( not $myconf->{'.CONF'} ) {
      printf STDERR "file: $file; $0 @ARGV\n". "Press Enter key: ";
      $/="\n";
      <STDIN>;
      exit( 1 );
    }


    if ( @ARGV ) {
	$myconf->{files} = 
	    [ { 'local' , $ARGV[0],
		'remote' , $ARGV[1], 
		'day_limit' , $ARGV[2],
	      } ];
    }

    $OPTS{diffrelax} = 2;  # default value

    my @files;

    conf_final(\@files, \%OPTS, $myconf);

    use IO::Handle;

#    if ( $OPTS{log} ) {
      open_LOG( $OPTS{log} );
#	$log_count=`wc -l $OPTS{log}`;
#	open LOG, ">>", $OPTS{log};
#	LOG->autoflush(1);
#	out_LOG $INFO, "agelog: log_count=%d\n", $log_count;
#    } else {
#	open LOG, ">", "/dev/null";
#    }

    # statuslog は引き続きの時は開きなおさない。serviceの１サイクルごとに消えてしまうので。
#    printf "statuslog: '%s' lastStatuslogFile: '%s' -> ", $OPTS{statuslog}, $lastStatuslogFile;
    if ( $OPTS{statuslog} ) {
      if ( (not defined($lastStatuslogFile) or $OPTS{statuslog} ne $lastStatuslogFile) ) {
	open STATUSLOG, ">", $OPTS{statuslog};
#	printf "re-open";
      } else {
#	printf "do nothing";
      }
      $lastStatuslogFile = $OPTS{statuslog};
      STATUSLOG->autoflush(1);
    } else {
      open STATUSLOG, ">", "/dev/null";
      $lastStatuslogFile = undef;
#      printf "/dev/null";
    }
#    printf " lastStatuslogFile: '%s'\n", $lastStatuslogFile;

    STDERR->autoflush(1);

    use Encode qw(encode decode);
    foreach my $sync ( @files ) {
	my (%OPTS_orig) = (%OPTS);
	opts_overwrite( $sync, \%OPTS);
	my $encode = ($OPTS{encode} || 'shiftjis');
	$sync->{remote} = encode($encode, decode('utf-8', $sync->{remote} ));
	$sync->{local} = encode($encode, decode('utf-8', $sync->{local} ));
	%OPTS = %OPTS_orig;
    }


    # @files を remoteまたはlocalの新しい方が先に来るようにソートしてから
    @files = map {
      my $remote_attr = attr($_->{remote});
      my $local_attr  = attr($_->{local});
#     remoteが切れていたら、最外周のループに戻る
      $_ -> {attr} = choose_newer( $remote_attr, $local_attr );
#      my ($top,$part) = dir_part( $_->{local} );
#      my $dir = dirname($part);
      my $dir = basename( $_->{local} );
      $_->{Name} = "$dir";
      $_->{"~time"} = attr_mtime_str( $_->{attr} );
#      $_->{"~Rtime"} = attr_mtime_str( $remote_attr );
#      $_->{"~Ltime"} = attr_mtime_str( $local_attr );
      $_;
    } @files;
    @files = sort { defined_older($a->{attr}, $b->{attr}) } @files;
    @files = map { delete $_->{attr}; $_; } @files;


    # configurationが変わったら診断出力

    out_LOG $INFO, $mes if $mes;

    my $new_files_json = JSON->new->canonical->encode(\@files);
    my $new_OPTS_json =  JSON->new->canonical->encode(\%OPTS);

    my $new_OPTS_json_print = JSON->new->pretty->canonical->encode(\%OPTS);
    $new_OPTS_json_print =~ s/"rpass" : "[^"]*"/"rpass" : "*****"/g;
    my $new_FILES_json_print = JSON->new->pretty->canonical->encode(\@files);
#    $new_FILES_json_print =~ s/\n\s*"rpass"[^\n]*\n/\n/g;

    $new_FILES_json_print =~ s/"rpass" : "[^"]*"/"rpass" : "*****"/g;
    $old_files_json_print =~ s/"rpass" : "[^"]*"/"rpass" : "*****"/g;

    out_LOG $INFO, "opts: %s\n", $new_OPTS_json_print
	if $new_OPTS_json ne $old_OPTS_json;
#    out_LOG $INFO, "files: %s\n", $new_FILES_json_print
    if ( $old_files_json ) {
      if ($new_files_json ne $old_files_json) {
	$new_FILES_json_print =~ s/"(rpass|ruser|verbose|rdustbox|ldustbox|)" : [^\n]*\n//g;
	$old_files_json_print =~ s/"(rpass|ruser|verbose|rdustbox|ldustbox|)" : [^\n]*\n//g;
	out_LOG $INFO, "files: %s\n", diff_log("/tmp/files", $old_files_json_print, $new_FILES_json_print);
      }
    } else {
      out_LOG $INFO, "files: %s\n",  $new_FILES_json_print;
    }

    # pattern compile
    #$OPTS{except} = qr/$OPTS{except}/;

    if ( $OPTS{mapping} ) {
      my %mapping;
      foreach my $f ( @files ) {
	$mapping{ $f->{local} } =  $f->{remote};
      }
      write_jsonfile($OPTS{mapping}, \%mapping);
    }

    return @files;
}

my $SIGQUIT_flag;
my $SIGHUP_flag;
my $SIGUSR1_flag;

sub sighup_h {
  $SIGHUP_flag=1;
  $SIGQUIT_flag=0;
  die "signal HUP";
}
sub sigquit_h {
  $SIGQUIT_flag = not $SIGQUIT_flag;
  die "signal QUIT";
}
sub sigusr1_h {
  $SIGUSR1_flag=1;
  die "signal USR1";
}

sub main_routine () {
  $OPTS{verbose} = 1;
    my @files = reload_conf("start: $0 @ORG_ARGV\n");
    if ( $OPTS{service} ) {
      $SIG{HUP} = "sighup_h";
      $SIG{QUIT} = "sigquit_h";
      $SIG{USR1} = "sigusr1_h";

	while ( $OPTS{service} ) {
	    $SIGHUP_flag=0;
	    $SIGQUIT_flag=0;
	    $SIGUSR1_flag=0;
	    out_LOG $STATUS1, "service start:";
	    eval {
	      foreach my $sync ( @files ) {
		my (%OPTS_orig) = (%OPTS);
#	        local (%OPTS);
		eval {
		  opts_overwrite( $sync, \%OPTS );
		  sync($sync->{remote}, $sync->{local}, $sync->{day_limit});
		};
		%OPTS = %OPTS_orig;
		if ($@) {
		  if ($SIGHUP_flag or $SIGQUIT_flag or $SIGUSR1_flag) {
		    die  $@;
		  } else {
		    out_LOG $STATUS1, $@;
		    $@="";
		    last;
		  }
		}
	      }
	      out_LOG $STATUS1,     "service sleep: %d", $OPTS{service};
	      my $before_sleep = time;
	      sleep( $OPTS{service} );
	      my $after_sleep = time;
	      my $slept = $after_sleep - $before_sleep;
	      if ($slept > $OPTS{service} + 20) {
		# スリープから起きた。
		# 無線LANがつながるまで少しかかるかも。その分もう一息待ってから。
		out_LOG $STATUS1, "wake up after machine sleep. sleep 30sec more";
		sleep( 30 )
	      }
	    }; # end eval
	    if ($@) {
	      out_LOG $ERROR, $@;
	      if ($SIGUSR1_flag) {
		out_LOG $STATUS1, "restart!\n";
		exec $^X, $0, @ORG_ARGV or
		  out_LOG $STATUS1, "Failed restart : $!";
	      }
	      eval {
		while ($SIGQUIT_flag) {
		  out_LOG $STATUS1,     "service sleep under SIG_QUIT: %d", $OPTS{service};
		  sleep $OPTS{service};
		}
	      };
	      $@="";
	    }
	    @files = reload_conf(undef, \@files);
	}
    } else {
	foreach my $sync ( @files ) {
	    my (%OPTS_orig) = (%OPTS);
	    opts_overwrite( $sync, \%OPTS );
	    sync($sync->{remote}, $sync->{local}, $sync->{day_limit});
	    %OPTS = %OPTS_orig;
	}
	printf STDERR "end: $0 @ARGV\n". "Press Enter key: ";
	<STDIN>;
    }
}

main_routine();

__END__


# Version 1.0 2015.03.11
# GitHub ident: $Id$
