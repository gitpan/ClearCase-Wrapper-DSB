package ClearCase::Wrapper::DSB;

$VERSION = '1.01';

use AutoLoader 'AUTOLOAD';

use strict;

#############################################################################
# Usage Message Extensions
#############################################################################
{
   local $^W = 0;
   no strict 'vars';

   # Usage message additions for actual cleartool commands that we extend.
   $catcs	= "\n* [-cmnt|-expand|-sources|-start]";
   $lock	= "\n* [-allow|-deny login-name[,...]] [-iflocked]";
   $mklabel	= "\n* [-up]";
   $setcs	= "\n\t     * [-clone view-tag] [-expand] [-sync]";
   $setview	= "* [-me] [-drive drive:] [-persistent]";
   $winkin	= "\n* [-vp] [-tag view-tag]";

   # Usage messages for pseudo cleartool commands that we implement here.
   local $0 = $ARGV[0] || '';
   $comment	= "$0 [-new] [-element] object-selector ...";
   $diffcs	= "$0 view-tag-1 [view-tag-2]";
   $edattr	= "$0 [-element] object-selector ...";
   $grep	= "$0 [grep-flags] pattern element";
   $recheckout	= "$0 pname ...\n";
   $winkout	= "$0 [-dir|-rec|-all] [-f file] [-pro/mote] [-do]
		[-meta file [-print] file ...";
   $workon	= "$0 [-me] [-login] [-exec command-invocation] view-tag\n";
}

#############################################################################
# Command Aliases
#############################################################################
*edcmnt		= *comment;
*egrep		= *grep;
*mkbrtype	= *mklbtype;	# not synonyms but the code's the same
*reco		= *recheckout;
*work		= *workon;

1;

__END__

## Internal service routines, undocumented.
# Function to parse 'include' stmts recursively.  Used by
# config-spec parsing meta-commands. The first arg is a
# "magic incrementing string", the second a filename,
# the third an "action" which is eval-ed
# for each line.  It can be as simple as 'print' or as
# complex a regular expression as desired. If the action is
# null, only the names of traversed files are printed.
sub _Burrow {
    local $input = shift;
    my($filename, $action) = @_;
    print $filename, "\n" if !$action;
    $input++;
    if (!open($input, $filename)) {
	warn "$filename: $!";
	return;
    }
    while (<$input>) {
	if (/^include\s+(.*)/) {
	    _Burrow($input, $1, $action);
	    next;
	}
	eval $action if $action;
    }
}

=head1 NAME

ClearCase::Wrapper::DSB - David Boyce's contributed wrapper functions

=head1 SYNOPSIS

This is an C<overlay module> for B<ClearCase::Wrapper> containing David
Boyce's non-standard extensions. See C<perldoc ClearCase::Wrapper> for
more details.

=head1 CLEARTOOL ENHANCEMENTS

=over 4

=item * CATCS

=over 4

=item 1. New B<-expand> flag

Follows all include statements recursively in order to print a complete
config spec. When used with the B<-cmnt> flag, comments are stripped
from this listing.

=item 2. New B<-sources> flag

Prints all files involved in the config spec (the I<config_spec> file
itself plus any files it includes).

=item 3. New B<-attribute> flag

This introduces the concept of user-defined I<view attributes>. A view
attribute is a keyword-value pair embedded in the config spec using the
conventional notation

    ##:Keyword: value ...

The value of any attribute may be retrieved by running

    <cmd-context> catcs -attr keyword ...

=item 4. New B<-start> flag

Prints the preferred I<initial working directory> of a view by
examining its config spec. This is simply the value of the
C<Start> attribute as described above and thus I<-start> is
a synonym for I<-attr Start>.

The B<workon> command (see) uses this value.  E.g., using B<workon>
instead of B<setview> with the config spec:

    ##:Start: /vobs_fw/src/java
    element * CHECKEDOUT
    element * /main/LATEST

would set the view and automatically cd to C</vobs_fw/src/java>.

=item 5. New B<-rdl> flag

Prints the value of the config spec's C"<##:RDL:> attribute.

=back

=cut

sub catcs {
    my(%opt, $op);
    GetOptions(\%opt, qw(attribute=s cmnt expand rdl start sources viewenv vobs));
    if ($opt{sources}) {
	$op = '';
    } elsif ($opt{expand}) {
	$op = 'print';;
    } elsif ($opt{'rdl'}) {
	$op = 's%##:RDL:\s*(.+)%print "$+\n";exit 0%ie';
    } elsif ($opt{viewenv}) {
	$op = 's%##:ViewEnv:\s+(\S+)%print "$+\n";exit 0%ie';
    } elsif ($opt{start}) {
	$op = 's%##:Start:\s+(\S+)|^\s*element\s+(\S*)/\.{3}\s%print "$+\n";exit 0%ie';
    } elsif ($opt{attribute}) {
	$op = 's%##:'.$opt{attribute}.':\s+(\S+)|^\s*element\s+(\S*)/\.{3}\s%print "$+\n";exit 0%ie';
    } elsif ($opt{vobs}) {
	$op = 's%^element\s+(\S+)/\.{3}\s%print "$1\n"%e';
    }
    if (defined $op) {
	$op .= ' unless /^\s*#/' if $op && $opt{cmnt};
	my $tag = ViewTag(@ARGV);
	die Msg('E', "view tag cannot be determined") if !$tag;;
	my($vws) = reverse split '\s+', ClearCase::Argv->lsview($tag)->qx;
	exit _Burrow('CATCS_00', "$vws/config_spec", $op);
    }
}

=item * COMMENT

For each ClearCase object specified, dump the current comment into a
temp file, allow the user to edit it with his/her favorite editor, then
change the objects's comment to the results of the edit. This is
useful if you mistyped a comment and want to correct it.

The B<-new> flag causes it to ignore the previous comment.

See B<edattr> for editor selection rules.

=cut

sub comment {
    shift @ARGV;
    my %opt;
    GetOptions(\%opt, qw(element new));
    my $retstat = 0;
    my $editor = $ENV{WINEDITOR} || $ENV{VISUAL} || $ENV{EDITOR} ||
						    (MSWIN ? 'notepad' : 'vi');
    my $ct = ClearCase::Argv->new;
    # Checksum before and after edit - only update if changed.
    my($csum_pre, $csum_post) = (0, 0);
    for my $obj (@ARGV) {
	my @input = ();
	$obj .= '@@' if $opt{element};
	if (!$opt{new}) {
	    @input = $ct->desc([qw(-fmt %c)], $obj)->qx;
	    next if $?;
	}
	my $edtmp = ".$::prog.comment.$$";
	open(EDTMP, ">$edtmp") || die Msg('E', "$edtmp: $!");
	for (@input) {
	    next if /^~\w$/;  # Hack - allow ~ escapes for ci-trigger a la mailx
	    $csum_pre += unpack("%16C*", $_);
	    print EDTMP $_;
	}
	close(EDTMP) || die Msg('E', "$edtmp: $!");

	# Run editor on temp file
	Argv->new($editor, $edtmp)->system;

	open(EDTMP, $edtmp) || die Msg('E', "$edtmp: $!");
	while (<EDTMP>) { $csum_post += unpack("%16C*", $_); }
	close(EDTMP) || die Msg('E', "$edtmp: $!");
	unlink $edtmp, next if $csum_post == $csum_pre;
	$retstat++ if $ct->chevent([qw(-replace -cfi), $edtmp], $obj)->system;
	unlink $edtmp;
    }
    exit $retstat;
}

=item * DIFFCS

New command.  B<Diffcs> dumps the config specs of two specified views
into temp files and diffs them. If only one view is specified, compares
against the current working view's config spec.

=cut

sub diffcs {
    my %opt;
    GetOptions(\%opt, qw(tag=s@));
    my @tags = @{$opt{tag}} if $opt{tag};
    push(@tags, @ARGV[1..$#ARGV]);
    if (@tags == 1) {
	my $cwv = ViewTag();
	push(@tags, $cwv) if $cwv;
    }
    die Msg('E', "two view-tag arguments required") if @tags != 2;
    my $ct = ClearCase::Argv->cleartool;
    my @cstmps = map {"$_.cs"} @tags;
    for my $i (0..1) {
	Argv->new("$ct catcs -tag $tags[$i] >$cstmps[$i]")->autofail(1)->system;
    }
    Argv->new('diff', @cstmps)->dbglevel(1)->system;
    unlink(@cstmps);
    exit 0;
}

=item * EDATTR

New command, inspired by the I<edcs> cmd.  B<Edattr> dumps the
attributes of the specified object into a temp file, then execs your
favorite editor on it, and adds, removes or modifies the attributes as
appropriate after you exit the editor.  Attribute types are created and
deleted automatically.  This is particularly useful on Unix platforms
because as of CC 3.2 the Unix GUI doesn't support modification of
attributes and the quoting rules make it difficult to use the
command line.

The environment variables WINEDITOR, VISUAL, and EDITOR are checked
in that order for editor names. If none of the above are set, the
default editor used is vi on UNIX and notepad on Windows.

=cut

sub edattr {
    my %opt;
    GetOptions(\%opt, qw(element));
    shift @ARGV;
    my $retstat = 0;
    my $editor = $ENV{WINEDITOR} || $ENV{VISUAL} || $ENV{EDITOR} ||
						    (MSWIN ? 'notepad' : 'vi');
    my $ct = ClearCase::Argv->new;
    my $ctq = $ct->clone({-stdout=>0, -stderr=>0});
    for my $obj (@ARGV) {
	my %indata = ();
	$obj .= '@@' if $opt{element};
	my @lines = $ct->desc([qw(-aattr -all)], $obj)->qx;
	if ($?) {
	    $retstat++;
	    next;
	}
	for my $line (@lines) {
	    next unless $line =~ /\s*(\S+)\s+=\s+(.+)/;
	    $indata{$1} = $2;
	}
	my $edtmp = ".$::prog.edattr.$$";
	open(EDTMP, ">$edtmp") || die Msg('E', "$edtmp: $!");
	print EDTMP "# $obj (format: attr = \"val\"):\n\n" if ! keys %indata;
	for (sort keys %indata) { print EDTMP "$_ = $indata{$_}\n" }
	close(EDTMP) || die Msg('E', "$edtmp: $!");

	# Run editor on temp file
	Argv->new($editor, $edtmp)->system;

	open(EDTMP, $edtmp) || die Msg('E', "$edtmp: $!");
	while (<EDTMP>) {
	    chomp;
	    next if /^\s*$|^\s*#.*$/;	# ignore null and comment lines
	    if (/\s*(\S+)\s+=\s+(.+)/) {
		my($attr, $newval) = ($1, $2);
		my $oldval;
		if (defined($oldval = $indata{$attr})) {
		    delete $indata{$attr};
		    # Skip if data unchanged.
		    next if $oldval eq $newval;
		}
		# Figure out what type the new attype needs to be.
		# Sorry, didn't bother with -vtype time.
		if ($ctq->lstype("attype:$attr")->system) {
		    if ($newval =~ /^".*"$/) {
			$ct->mkattype([qw(-nc -vty string)], $attr)->system;
		    } elsif ($newval =~ /^[+-]?\d+$/) {
			$ct->mkattype([qw(-nc -vty integer)], $attr)->system;
		    } elsif ($newval =~ /^-?\d+\.?\d*$/) {
			$ct->mkattype([qw(-nc -vty real)], $attr)->system;
		    } else {
			$ct->mkattype([qw(-nc -vty opaque)], $attr)->system;
		    }
		    next if $?;
		}
		# Deal with broken quoting on &^&@# Windows.
		if (MSWIN && $newval =~ /^"(.*)"$/) {
		    $newval = qq("\\"$1\\"");
		}
		# Make the new attr value.
		if (defined($oldval)) {
		    $retstat++ if $ct->mkattr([qw(-rep -c)],
			 "(Was: $oldval)", $attr, $newval, $obj)->system;
		} else {
		    $retstat++ if $ct->mkattr([qw(-rep)],
			 $attr, $newval, $obj)->system;
		}
	    } else {
		warn Msg('W', "incorrect line format: '$_'");
		$retstat++;
	    }
	}
	close(EDTMP) || die Msg('E', "$edtmp: $!");
	unlink $edtmp;

	# Now, delete any attrs that were deleted from the temp file.
	# First we do a simple rmattr; then see if it was the last of
	# its type and if so remove the type too.
	for (sort keys %indata) {
	    if ($ct->rmattr($_, $obj)->system) {
		$retstat++;
	    } else {
		# Don't remove the type if its vob serves as an admin vob!
		my @deps = grep /^<-/,
				$ct->desc([qw(-s -ahl AdminVOB)], 'vob:.')->qx;
		next if $? || @deps;
		$ct->rmtype(['-rmall'], "attype:$_")->system;
	    }
	}
    }
    exit $retstat;
}

=item * GREP

New command. Greps through past revisions of a file for a pattern, so
you can see which revision introduced a particular function or a
particular bug. By analogy with I<lsvtree>, I<grep> searches only
"interesting" versions unless B<-all> is specified.

Flags B<-nnn> are accepted where I<nnn> represents the number of versions
to go back. Thus C<grep -1 foo> would search only the predecessor.

=cut

sub grep {
    my %opt;
    GetOptions(\%opt, 'all');
    my $elem = pop(@ARGV);
    my $limit = 0;
    if (my @num = grep /^-\d+$/, @ARGV) {
	@ARGV = grep !/^-\d+$/, @ARGV;
	die Msg('E', "incompatible flags: @num") if @num > 1;
	$limit = -int($num[0]);
    }
    my $lsvt = ClearCase::Argv->new('lsvt', ['-s'], $elem);
    $lsvt->opts('-all', $lsvt->opts) if $opt{all} || $limit > 1;
    chomp(my @vers = sort {($b =~ m%/(\d+)%)[0] <=> ($a =~ m%/(\d+)%)[0]}
						grep {m%/\d+$%} $lsvt->qx);
    exit 2 if $?;
    splice(@vers, $limit) if $limit;
    splice(@ARGV, 0, 1, 'egrep');
    Argv->new(@ARGV, @vers)->dbglevel(1)->exec;
}

=item * LOCK

New B<-allow> and B<-deny> flags. These work like I<-nuser> but operate
incrementally on an existing I<-nuser> list rather than completely
replacing it. When B<-allow> or B<-deny> are used, I<-replace> is
implied.

When B<-iflocked> is used, no lock will be created where one didn't
previously exist; the I<-nusers> list will only be modified for
existing locks.

=cut

sub lock {
    my %opt;
    GetOptions(\%opt, qw(allow=s deny=s iflocked));
    return 0 unless %opt;
    my $lock = ClearCase::Argv->new(@ARGV);
    $lock->parse(qw(c|cfile=s c|cquery|cqeach nusers=s
						    pname=s obsolete replace));
    die Msg('E', "cannot specify -nusers along with -allow or -deny")
					if $lock->flag('nusers');
    die Msg('E', "cannot use -allow or -deny with multiple objects")
					if $lock->args > 1;
    my $lslock = ClearCase::Argv->lslock([qw(-fmt %c)], $lock->args);
    my($currlock) = $lslock->autofail(1)->qx;
    if ($currlock && $currlock =~ m%^Locked except for users:\s+(.*)%) {
	my %nusers = map {$_ => 1} split /\s+/, $1;
	if ($opt{allow}) {
	    for (split /,/, $opt{allow}) { $nusers{$_} = 1 }
	}
	if ($opt{deny}) {
	    for (split /,/, $opt{deny}) { delete $nusers{$_} }
	}
	$lock->opts($lock->opts, '-nusers', join(',', sort keys %nusers))
								    if %nusers;
    } elsif (!$currlock && $opt{iflocked}) {
	exit 0;
    } elsif ($opt{allow}) {
	$lock->opts($lock->opts, '-nusers', $opt{allow});
    }
    $lock->opts($lock->opts, '-replace') unless $lock->flag('replace');
    $lock->exec;
}

=item * MKBRTYPE,MKLBTYPE

Modification: if user tries to make a type in the current VOB without
explicitly specifying -ordinary or -global, and if said VOB is
associated with an admin VOB, then by default create the type as a
global type in the admin VOB instead. B<I<In effect, this makes -global
the default iff a suitable admin VOB exists>>.

=cut

sub mklbtype {
    return if grep /^-ord|^-glo|vob:/i, @ARGV;
    if (my($ahl) = grep /^->/,
		    ClearCase::Argv->desc([qw(-s -ahl AdminVOB vob:.)])->qx) {
	if (my $avob = (split /\s+/, $ahl)[1]) {
	    # Save aside all possible flags for mkxxtype,
	    # then add the vob selector to each type selector
	    # and add the new -global to opts before exec-ing.
	    my $ntype = ClearCase::Argv->new(@ARGV);
	    $ntype->parse(qw(replace|global|ordinary
			    vpelement|vpbranch|vpversion
			    pbranch|shared
			    gt|ge|lt|le|enum|default|vtype=s
			    cqe|nc c|cfile=s));
	    my @args = $ntype->args;
	    for (@args) {
		next if /\@/;
		$_ = "$_\@$avob";
		warn Msg('W', "making global type $_ ...");
	    }
	    $ntype->args(@args);
	    $ntype->opts('-global', $ntype->opts);
	    $ntype->exec;
	}
    }
}

=item * MKLABEL

The new B<-up> flag, when combined with B<-recurse>, also labels the parent
directories of the specified I<pname>s all the way up to their vob tags.

=cut

sub mklabel {
    my %opt;
    GetOptions(\%opt, qw(up));
    return 0 unless $opt{up};
    die Msg('E', "-up requires -recurse") if !grep /^-re?$|^-rec/, @ARGV;
    my $mkl = ClearCase::Argv->new(@ARGV);
    my $dsc = ClearCase::Argv->new({-autochomp=>1});
    $mkl->parse(qw(replace|recurse|ci|cq|nc
				version|c|cfile|select|type|name|config=s));
    $mkl->syfail(1)->system;
    require File::Basename;
    require File::Spec;
    File::Spec->VERSION(0.82);
    my($label, @elems) = $mkl->args;
    my %ancestors;
    for my $pname (@elems) {
	my $vobtag = $dsc->desc(['-s'], "vob:$pname")->qx;
	for (my $dad = File::Basename::dirname(File::Spec->rel2abs($pname));
		    length($dad) >= length($vobtag);
			    $dad = File::Basename::dirname($dad)) {
	    $ancestors{$dad}++;
	}
    }
    exit(0) if !%ancestors;
    $mkl->opts(grep !/^-r(ec)?$/, $mkl->opts);
    $mkl->args($label, sort {$b cmp $a} keys %ancestors)->exec;
}

=item * MOUNT

This is a Windows-only enhancement: on UNIX, I<mount> behaves correctly
and we do not mess with its behavior. On Windows, for some bonehead
reason I<cleartool mount -all> gives an error for already-mounted VOBs;
these are now ignored as on UNIX. At the same time, VOB tags containing
I</> are normalized to I<\> so they'll match the registry, and an
extension is made to allow multiple VOB tags to be passed to one
I<mount> command.

=cut

sub mount {
    return 0 if !MSWIN || @ARGV < 2;
    my %opt;
    GetOptions(\%opt, qw(all));
    my $mount = ClearCase::Argv->new(@ARGV);
    $mount->autofail(1);
    $mount->parse(qw(persistent options=s));
    die Msg('E', qq(Extra arguments: "@{[$mount->args]}"))
						if $mount->args && $opt{all};
    my @tags = $mount->args;
    my $lsvob = ClearCase::Argv->lsvob(@tags);
    # The set of all known public VOBs.
    my @public = grep /\spublic\b/, $lsvob->qx;
    # The subset which are not mounted.
    my @todo = map {(split /\s+/)[1]} grep /^\s/, @public;
    # If no vobs are mounted, let the native mount -all proceed.
    if ($opt{all} && @public == @todo) {
	push(@ARGV, '-all');
	return 0;
    }
    # Otherwise mount what's needed one by one.
    for (@todo) {
	$mount->args($_)->system;
    }
    exit 0;
}

=item * RECO/RECHECKOUT

Redoes a checkout without the database operations by simply copying the
contents of the existing checkout's predecessor over the view-private
checkout file. The previous contents are moved aside to "<element>.reco".

=cut

sub recheckout {
    shift;
    require File::Copy;
    for (@_) {
	$_ = readlink if -l && defined readlink;
	if (! -w $_) {
	    warn Msg('W', "$_: not checked out");
	    next;
	}
	my $pred = Pred($_, 1);
	my $keep = "$_.reco";
	unlink $keep;
	if (rename($_, $keep)) {
	    if (File::Copy::copy($pred, $_)) {
		chmod 0644, $_;
	    } else {
		die Msg('E', (-r $_ ? $keep : $_) . ": $!");
	    }
	} else {
	    die Msg('E', "cannot rename $_ to $keep: $!");
	}
    }
    exit 0;
}

=item * SETCS

Adds a B<-clone> flag which lets you specify another view from which to copy
the config spec.

Adds a B<-sync> flag. This is similar to B<-current> except that it
analyzes the CS dependencies and only flushes the view cache if the
I<compiled_spec> file is out of date with respect to the I<config_spec>
source file or any file it includes. In other words: B<setcs -sync> is
to B<setcs -current> as B<make foo.o> is to B<cc -c foo.c>.

Adds a B<-expand> flag, which "flattens out" the config spec by
inlining the contents of any include files.

=cut

sub setcs {
    my %opt;
    GetOptions(\%opt, qw(clone=s expand sync));
    die Msg('E', "-expand and -sync are mutually exclusive")
					    if $opt{expand} && $opt{sync};
    my $tag = ViewTag(@ARGV) if $opt{expand} || $opt{sync} || $opt{clone};
    if ($opt{expand}) {
	my $ct = Argv->new([$^X, '-S', $0]);
	my $settmp = ".$::prog.setcs.$$";
	open(EXP, ">$settmp") || die Msg('E', "$settmp: $!");
	print EXP $ct->opts(qw(catcs -expand -tag), $tag)->qx;
	close(EXP);
	$ct->opts('setcs', $settmp)->system;
	unlink $settmp;
	exit $?;
    } elsif ($opt{sync}) {
	chomp(my @srcs = qx($^X -S $0 catcs -sources -tag $tag));
	exit 2 if $?;
	(my $obj = $srcs[0]) =~ s/config_spec/.compiled_spec/;
	die Msg('E', "$obj: no such file") if ! -f $obj;
	die Msg('E', "no permission to update $tag's config spec") if ! -w $obj;
	my $otime = (stat $obj)[9];
	for (@srcs) {
	    ClearCase::Argv->setcs(qw(-current -tag), $tag)->exec
						    if (stat $_)[9] > $otime;
	}
	exit 1;
    } elsif ($opt{clone}) {
	my $ct = ClearCase::Argv->new;
	my $ctx = $ct->cleartool;
	my $cstmp = ".$ARGV[0].$$.cs.$tag";
	Argv->autofail(1);
	Argv->new("$ctx catcs -tag $opt{clone} > $cstmp")->system;
	$ct->setcs('-tag', $tag, $cstmp)->system;
	unlink($cstmp);
	exit 0;
    }
}

=item * SETVIEW

ClearCase 4.0 for Windows completely removed I<setview> functionality,
but this wrapper emulates it by attaching the view to a drive letter
and cd-ing to that drive. It supports all the flags I<setview> for
CC 3.2.1/Windows supported (B<-drive>, B<-exec>, etc.) and adds two
new ones: B<-persistent> and B<-window>.

If the view is already mapped to a drive letter that drive is used.
If not, the first available drive working backwards from Z: is used.
Without B<-persistent> a drive mapped by setview will be unmapped
when the setview process is existed.

With the B<-window> flag, a new window is created for the setview. A
beneficial side effect of this is that Ctrl-C handling within this new
window is cleaner.

The setview emulation sets I<CLEARCASE_ROOT> for compatibility and adds
a new EV I<CLEARCASE_VIEWDRIVE>.

UNIX setview functionality is left alone.

=cut

sub setview {
    # Clean up whatever EV's we might have used to communicate from
    # parent (pre-setview) to child (in-setview) processes.
    $ENV{CLEARCASE_PROFILE} = $ENV{_CLEARCASE_WRAPPER_PROFILE}
				if defined($ENV{_CLEARCASE_WRAPPER_PROFILE});
    delete $ENV{_CLEARCASE_WRAPPER_PROFILE};
    delete $ENV{_CLEARCASE_PROFILE};
    for (grep /^(CLEARCASE_)?ARGV_/, keys %ENV) { delete $ENV{$_} }

    if (!MSWIN) {
	ClearCase::Argv->ctcmd(0);	# CtCmd setview doesn't work right
	return 0;
    }

    my %opt;
    GetOptions(\%opt, qw(exec=s drive=s login ndrive persistent window));
    my $child = $opt{'exec'};
    if ($ENV{SHELL}) {
	$child ||= $ENV{SHELL};
    } else {
	delete $ENV{LOGNAME};
    }
    $child ||= $ENV{ComSpec} || $ENV{COMSPEC} || 'cmd.exe';
    my $vtag = $ARGV[-1];
    my @net_use = grep /\s[A-Z]:\s/i, Argv->new(qw(net use))->qx;
    my $drive = $opt{drive} || (map {/(\w:)/ && uc($1)}
				grep /\s+\\\\view\\$vtag\b/,
				grep !/unavailable/i, @net_use)[0];
    my $mounted = 0;
    my $pers = $opt{persistent} ? '/persistent:yes' : '/persistent:no';
    if (!$drive) {
	ClearCase::Argv->startview($vtag)->autofail(1)->system
						    if ! -d "//view/$vtag";
	$mounted = 1;
	my %taken = map { /\s([A-Z]:)\s/i; $1 => 1 } @net_use;
	for (reverse 'G'..'Z') {
	    next if $_ eq 'X';	# X: is reserved (for CDROM?) on Citrix
	    $drive = $_ . ':';
	    if (!$taken{$drive}) {
		local $| = 1;
		print "Connecting $drive to \\\\view\\$vtag ... "
							    if !$opt{'exec'};
		my $netuse = Argv->new(qw(net use),
					    $drive, "\\\\view\\$vtag", $pers);
		$netuse->stdout(0) if $opt{'exec'};
		last if !$netuse->system;
	    }
	}
    } elsif ($opt{drive}) {
	$drive .= ':' if $drive !~ /:$/;
	$drive = uc($drive);
	if (! -d $drive) {
	    $mounted = 1;
	    local $| = 1;
	    print "Connecting $drive to \\\\view\\$vtag ... ";
	    Argv->new(qw(net use), $drive, "\\\\view\\$vtag", $pers)->system;
	    exit $?>>8 if $?;
	}
    }
    chdir "$drive/" || die Msg('E', "chdir $drive $!");
    $ENV{CLEARCASE_ROOT} = "\\\\view\\$vtag";
    $ENV{CLEARCASE_VIEWDRIVE} = $ENV{VD} = $drive;
    my $sv = Argv->new($child);
    $sv->prog(qw(start /wait), $sv->prog) if $opt{window};
    if ($mounted && !$opt{persistent}) {
	my $rc = $sv->system;
	my $netuse = Argv->new(qw(net use), $drive, '/delete');
	$netuse->stdout(0) if $opt{'exec'};
	$netuse->system;
	exit $rc;
    } else {
	$sv->exec;
    }
}

=item * WINKIN

The B<-tag> flag allows you specify a local file path plus another view;
the named DO in the named view will be winked into the current view.

The B<-vp> flag, when used with B<-tag>, causes the "remote" file to be
converted into a DO if required before winkin is attempted. See the
B<winkout> extension for details.

=cut

sub winkin {
    my %opt;
    local $Getopt::Long::autoabbrev = 0; # so -rm and -r/ecurse don't collide
    GetOptions(\%opt, qw(rm tag=s vp));
    return 0 if !$opt{tag};
    my $wk = ClearCase::Argv->new(@ARGV);
    $wk->parse(qw(print|noverwrite|siblings|adirs|recurse|ci out|select=s));
    $wk->quote;
    my @files = $wk->args;
    unlink @files if $opt{rm};
    if ($opt{vp}) {
	my @winkout = ($^X, '-S', $0, 'winkout', '-pro');
	ClearCase::Argv->new(qw(setview -exe), "@winkout @files",
					    $opt{tag})->autofail(1)->system;
    }
    my $rc = 0;
    for my $file (@files) {
	if ($wk->flag('recurse') || $wk->flag('out')) {
	    $wk->args;
	} else {
	    $wk->args('-out', $file);
	}
	$rc ||= $wk->args($wk->args, "/view/$opt{tag}$file")->system;
    }
    exit $rc;
}

=item * WINKOUT

The B<winkout> pseudo-cmd takes a set of view-private files as
arguments and, using clearaudit, makes them into derived objects. The
config records generated are meaningless but the mere fact of being a
DO makes a file eligible for forced winkin.

If the B<-promote> flag is given, the view scrubber will be run on the
new DO's. This has the effect of promoting them to the VOB and winking
them back into the current view.

If a meta-DO filename is specified with B<-meta>, this file is created
as a DO and caused to reference all the other new DO's, thus defining a
I<DO set> and allowing the entire set to be winked in using the meta-DO
as a hook. E.g. assuming view-private files X, Y, and Z already exist:

	ct winkout -meta .WINKIN X Y Z

will make them into derived objects and create a 4th DO ".WINKIN"
containing references to the others. A subsequent

	ct winkin -recurse -adirs /view/extended/path/to/.WINKIN

from a different view will wink all four files into the current view.

Accepts B<-dir/-rec/-all/-avobs>, a file containing a list of files
with B<-flist>, or a literal list of view-private files. When using
B<-dir/-rec/-all/-avobs> to derive the file list only the output of
C<lsprivate -other> is considered unless B<-do> is used; B<-do> causes
existing DO's to be re-converted.

The B<"-flist -"> flag can be used to read the file list from stdin.

=cut

sub winkout {
    warn Msg('E', "if you can get this working on &%@# Windows you're a better programmer than I am!") if MSWIN;
    my %opt;
    GetOptions(\%opt, qw(directory recurse all avobs flist=s
					do meta=s print promote));
    my $ct = ClearCase::Argv->new({-autochomp=>1, -syfail=>1});

    my $dbg = Argv->dbglevel;

    my $cmd = shift @ARGV;
    my @list;
    if (my @scope = grep /^(dir|rec|all|avo|f)/, keys %opt) {
	die Msg('E', "mutually exclusive flags: @scope") if @scope > 1;
	if ($opt{flist}) {
	    open(LIST, $opt{flist}) || die Msg('E', "$opt{flist}: $!");
	    @list = <LIST>;
	    close(LIST);
	} else {
	    my @type = $opt{'do'} ? qw(-other -do) : qw(-other);
	    @list = Argv->new([$^X, '-S', $0, 'lsp'],
		    ['-s', @type, "-$scope[0]"])->qx;
	}
    } else {
	@list = @ARGV;
    }
    chomp @list;
    my %set = map {$_ => 1} grep {-f}
		    grep {!m%\.(?:mvfs|nfs)\d+|cmake\.state%} @list;
    exit 0 if ! %set;
    if ($opt{'print'}) {
	for (keys %set) {
	    print $_, "\n";
	}
	print $opt{meta}, "\n" if $opt{meta};
	exit 0;
    }
    # Shared DO's should be g+w!
    (my $egid = $)) =~ s%\s.*%%;
    for (keys %set) {
	my($mode, $uid, $gid) = (stat($_))[2,4,5];
	if (!defined($mode)) {
	    warn Msg('W', "no such file: $_");
	    delete $set{$_};
	    next;
	}
	next if $uid != $> || ($mode & 0222) || ($mode & 0220 && $gid == $egid);
	chmod(($mode & 07777) | 0220, $_);
    }
    my @dolist = sort keys %set;
    # Add the -meta file to the list of DO's if specified.
    if ($opt{meta}) {
	if ($dbg) {
	    my $num = @dolist;
	    print STDERR "+ associating $num files with $opt{meta} ...\n";
	}
	open(META, ">$opt{meta}") || die Msg('E', "$opt{meta}: $!");
	for (@dolist) { print META $_, "\n" }
	close(META);
	push(@dolist, $opt{meta});
    }
    # Convert regular view-privates into DO's by opening them
    # under clearaudit control.
    {
	my $clearaudit = '/usr/atria/bin/clearaudit';
	local $ENV{CLEARAUDIT_SHELL} = $^X;
	my $ecmd = 'chomp; open(DO, ">>$_") || warn "Error: $_: $!\n"';
	my $cmd = qq($clearaudit -n -e '$ecmd');
	$cmd = "set -x; $cmd" if $dbg;
	open(AUDIT, "| $cmd") || die Msg('E', "$cmd: $!");
	for (@dolist) {
	    print AUDIT $_, "\n";
	    print STDERR $_, "\n" if $dbg;
	}
	close(AUDIT) || die Msg('E', $! ?
				"Error closing clearaudit pipe: $!" :
				"Exit status @{[$?>>8]} from clearaudit");
    }
    if ($opt{promote}) {
	my $scrubber = '/usr/atria/etc/view_scrubber';
	my $cmd = "$scrubber -p";
	$cmd = "set -x; $cmd" if $dbg;
	open(SCRUBBER, "| $cmd") || die Msg('E', "$scrubber: $!");
	for (@dolist) { print SCRUBBER $_, "\n" }
	close(SCRUBBER) || die Msg('E', $! ?
				"Error closing $scrubber pipe: $!" :
				"Exit status $? from $scrubber");
    }
    exit 0;
}

=item * WORKON

New command, similar to I<setview> but provides hooks to cd to a
preferred I<initial working directory> within the view and to set
up any required environment variables. The I<initial working directory>
is defined as the output of B<ct catcs -start> (see).

If a file called I<.viewenv.pl> exists in the I<initial working
directory>, it's read before starting the user's shell. This file uses
Perl syntax and must end with a "1;" like any C<require-d> file.  Any
unrecognized arguments given to I<workon> following the view name will
be passed on to C<.viewenv.pl> in C<@ARGV>. Environment variables
required for builds within the setview may be set here.

=cut

sub workon {
    shift @ARGV;	# get rid of pseudo-cmd
    my(%opt, @sv_argv);
    # Strip flags intended for 'setview' out of @ARGV, hold them in @sv_argv.
    GetOptions(\%opt, qw(drive=s exec=s login ndrive persistent window));
    push(@sv_argv, '-drive', $opt{drive}) if $opt{drive};
    push(@sv_argv, map {"-$_"} grep !/^(drive|exec)/, keys %opt);
    # Now dig the tag out of @ARGV, wherever it might happen to be.
    # Assume it's the last entry in ARGV matching a legal view-tag pattern.
    my $tag;
    for (my $i=$#ARGV; $i >= 0; $i--) {
	if ($ARGV[$i] !~ /^-|^\w+=.+/) {
	    $tag = splice(@ARGV, $i, 1);
	    last;
	}
    }
    die Msg('E', "no tag argument found in '@ARGV'") if !$tag;
    # If anything left in @ARGV has whitespace, quote it against its
    # journey through the "setview -exec" shell.
    for (@ARGV) {
	if (/\s/ && !/^(["']).*\1$/) {
	    $_ = qq('$_');
	}
    }
    # Last, run the setview cmd we've so laboriously constructed.
    unshift(@ARGV, '_inview');
    if ($opt{'exec'}) {
	push(@ARGV, '-_exec', qq("$opt{'exec'}"));
    }
    my $vwcmd = "$^X -S $0 @ARGV";
    # This next line is required because 5.004 and 5.6 do something
    # different with quoting on Windows, no idea exactly why or what.
    $vwcmd = qq("$vwcmd") if MSWIN && $] > 5.005;
    push(@sv_argv, '-exec', $vwcmd, $tag);
    # Prevent \'s from getting lost in subsequent interpolation.
    for (@sv_argv) { s%\\%/%g }
    # Hack - assume presence of $ENV{_} means we came from a UNIX-style
    # shell (e.g. MKS on Windows) so set quoting accordingly.
    my $cmd_exe = (MSWIN && !$ENV{_});
    Argv->new($^X, '-S', $0, 'setview', @sv_argv)->autoquote($cmd_exe)->exec;
}

## undocumented helper function for B<workon>
sub _inview {
    my $tag = (split(m%[/\\]%, $ENV{CLEARCASE_ROOT}))[-1];
    #Argv->new([$^X, '-S', $0, 'setcs'], [qw(-sync -tag), $tag])->system;

    # If -exec foo was passed to workon it'll show up as -_exec foo here.
    my %opt;
    GetOptions(\%opt, qw(_exec=s)) if grep /^-_/, @ARGV;

    my @cs = Argv->new([$^X, '-S', $0, 'catcs'], [qw(--expand -tag), $tag])->qx;
    chomp @cs;
    my($iwd, $venv, @viewenv_argv);
    for (@cs) {
	if (/^##:Start:\s+(\S+)/) {
	    $iwd = $1;
	} elsif (/^##:ViewEnv:\s+(\S+)/) {
	    $venv = $1;
	} elsif (/^##:([A-Z]+=.+)/) {
	    push(@viewenv_argv, $1);
	}
    }

    # If an initial working dir is supplied cd to it, then check for
    # a viewenv file and require it if so.
    if ($iwd) {
	print "+ cd $iwd\n";
	# ensure $PWD is set to $iwd within req'd file
	require Cwd;
	Cwd::chdir($iwd) || warn "$iwd: $!\n";
	my($cli) = grep /^viewenv=/, @ARGV;
	$venv = (split /=/, $cli)[1] if $cli;
	$venv ||= '.viewenv.pl';
	if (-f $venv) {
	    local @ARGV = grep /^\w+=/, @ARGV;
	    push(@ARGV, @viewenv_argv) if @viewenv_argv;
	    print "+ reading $venv ...\n";
	    eval { require $venv };
	    warn Msg('W', $@) if $@;
	}
    }

    # A reasonable default for everybody.
    $ENV{CLEARCASE_MAKE_COMPAT} ||= 'gnu';

    for (grep /^(CLEARCASE_)?ARGV_/, keys %ENV) { delete $ENV{$_} }

    # Exec the default shell or the value of the -_exec flag.
    my $final = Argv->new;
    if (! $opt{_exec}) {
	if (MSWIN) {
	    $opt{_exec} = $ENV{SHELL} || $ENV{ComSpec} || $ENV{COMSPEC}
				|| (-x '/bin/sh.exe' ? '/bin/sh' : 'cmd');
	} else {
	    $opt{_exec} = $ENV{SHELL} || (-x '/bin/sh' ? '/bin/sh' : 'sh');
	}
    }
    #system("title workon $tag") if MSWIN;
    $final->prog($opt{_exec})->exec;
}

=back

=head1 COPYRIGHT AND LICENSE

Copyright (c) 1997-2002 David Boyce (dsb@boyski.com). All rights
reserved.  This Perl program is free software; you may redistribute it
and/or modify it under the same terms as Perl itself.

=head1 SEE ALSO

perl(1), ClearCase::Wrapper

=cut
