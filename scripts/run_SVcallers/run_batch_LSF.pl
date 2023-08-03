#!/usr/bin/perl -w
use strict;
use File::Basename;
use Getopt::Long;
use Pod::Usage;

my $bam_list = '';
my $config = '';
my $queue = '';
my $memory = 30000000;
my $time = 0;
my $help;
 
GetOptions(
    'bam_list|b=s' => \$bam_list,
    'config|c=s' => \$config,
    'queue|q=s' => \$queue,
    'mem|m=i' => \$memory,
    'time|t=i' => \$time,
    'help' => \$help
) or pod2usage(-verbose => 0);
pod2usage(-verbose => 0) if $help;

=head1 SYNOPSIS

  run_batch_LSF.pl -b <bam_list> -c <config_file> -q <queue> -m <memory(MB)>

  Options:
   --bam_list or -b <STR>   bam list file [mandatory]
   --config or -c <STR>     config file [mandatory]
   --queue or -q            The partition that this job will run on [mandatory]
   --memory or -m <INT>     minimum amount of real memory in KB [default: 30000000]
   --time or -t <INT>  		  time limit in min (optional)
   --help or -h             output help message
   
=cut

die "bam list is not specified:\n" if ($bam_list eq '');
die "config file is not specified:\n" if ($config eq '');
die "queue is not specified:\n" if ($queue eq '');

my $bsub_opt = "bsub -q $queue";

if ($memory ne ''){
	$bsub_opt .= " -M $memory";
}
if ($time > 0){
	$bsub_opt .= " -W $time";
}

my $ref = '';
my $target_chr = 'ALL';
my $non_human = 0;
my $run_svcaller_dir = '';

my $script_dir = '';
$script_dir = $1 if ($0 =~ /(.+)\//);
$run_svcaller_dir = $script_dir;

my @tools;

my %tool_opt;
my %tool_script;
my $tool = '';

open (FILE, $config) or die "$config is not found: $!\n";
while (my $line = <FILE>){
	chomp $line;
	if ($line =~ /^#/){
		$tool = '';
	}
	next if ($line =~ /^#|^$/);
	if ($line =~ /^<(.+)>/){
		$tool = $1;
		push @tools, $tool;
		next;
	}
	if ($line =~ /^(\S+)\s*=\s*(\S+)\s*;/){
		my $opt1 = $1;
		my $arg = $2;
		$opt1 =~ s/[\'\"]// if ($opt1 =~ /[\'\"']/);
		$arg =~ s/[\'\"]// if ($arg =~ /[\'\"']/);
		if ($tool eq 'general'){
			if ($opt1 eq 'ref'){
				$ref = $arg;
			}
			elsif ($opt1 eq 'target'){
				$target_chr = $arg;
			}
			elsif ($opt1 eq 'non_human'){
				$non_human = $arg;
			}
			elsif ($opt1 eq 'run_svcaller_dir'){
				$run_svcaller_dir = $arg;
			}
		}
		elsif ($tool ne ''){
			if ($line =~ /\[\s*(\S+)\s+(\S+)\s*\]/){
				my $run_script = $1;
				my $opt2 = $2;
				$run_script =~ s/[\'\"]// if ($run_script =~ /[\'\"']/);
				$opt2 =~ s/[\'\"]// if ($opt2 =~ /[\'\"']/);
				${$tool_opt{$tool}}{$opt1} = "$opt2 $arg";
				$tool_script{$tool} = "$run_svcaller_dir/$run_script" if ($run_svcaller_dir ne '');
			}
		}
	}
}
close (FILE);

my $cur_dir = `pwd`;
chomp $cur_dir;

my $bam_path = '';

my $bsub_flag = 0;
my $return = `which bsub`;
chomp $return;
$bsub_flag = 1 if ($return !~ /no|\s/);


open (FILE, $bam_list) or die "$bam_list is not found:$!\n";
while (my $line = <FILE>){
	chomp $line;
	if ($line =~ /^#\s*(\S+)/){
		my $path = $1;
		if ($path =~ /\//){
			$bam_path = $path;
		}
	}
	next if ($line =~ /^#|^$/);
	my $bam = $line;
	my $bam_base = basename ($line);
	my $ID = $bam_base;
	$ID = $1 if ($bam_base =~ /(.+?)\./);
	if ($bam_base =~ /\.cram$/){
		die "input alignment file should be in bam format (not cram)\n";
	}
	if ($bam_base !~ /\.bam$/){
		$bam_base = "$ID.bam";
		$bam .= '.bam';
	}
	system ("mkdir $ID") if (!-d $ID);
	chdir $ID;
	if (!-f $bam_base){
		$bam = "$bam_path/$bam" if ($bam_path ne '');
		system ("ln -s $bam");
		system ("ln -s $bam.bai");
		$bam = $bam_base;
	}
	print STDERR "Sample: $ID\n";
	foreach my $tool_name (@tools){
		next if ($tool_name eq 'general');
		system ("mkdir $tool_name") if (!-d $tool_name);
		chdir $tool_name;
		my $run_script = $tool_script{$tool_name};
		my $opt_str = '';
		my $thread = 1;
		foreach my $opt (keys %{$tool_opt{$tool_name}}){
			$opt_str .= "${$tool_opt{$tool_name}}{$opt} ";
			if ($opt eq 'threads'){
				$thread = $1 if (${$tool_opt{$tool_name}}{$opt} =~ /\s(\d+)/);
			}
		}
#print STDERR "$tool_name\t$run_script $opt_str\n";
		$bam = "../$bam" if ($bam !~ /\//);
		$opt_str .= "-nh $non_human " if ($tool_name =~ /CNVnator|inGAP|MELT|Wham|DELLY|Lumpy|SoftSV|Manta|GRIDSS|MATCHCLIP|INSurVeylor/);
		$opt_str =~ s/\s$//;
		if (($tool_name eq 'CNVnator') and ($opt_str =~ /-r\s/)){
			$opt_str = "-b $bam -p $ID " . $opt_str;
		}
		else{
			$opt_str = "-b $bam -p $ID -r $ref " . $opt_str;
		}
		if ($target_chr ne 'ALL'){
			$opt_str .= " -c $target_chr";
		}
		my $bsub_opt2 = $bsub_opt;
		$bsub_opt2 .= " -n $thread";
		my $error_log = "$ID.error.log";
		my $out_log = "$ID.out.log";
		my $command = "$run_script $opt_str";
		open (OUT, "> run.sh");
		print OUT "#! /usr/bin/bash\n\n";
		print OUT "$command\n";
		close (OUT);
		open (OUT, "> $ID.command.log");
		print OUT "LSF command: $bsub_opt2 -o $out_log -e $error_log run.sh\n";
		close (OUT);
		if ($bsub_flag == 1){
			my $jobid = `$bsub_opt2 -o $out_log -e $error_log run.sh`;
			$jobid = $1 if ($jobid =~ /(\d+)/);
	        print STDERR "$tool_name:$jobid\n";
	    }
	    else{
	    	print STDERR "No sbatch command:\n";
	    }
        chdir '..';
	}
	print STDERR "\n";
	chdir $cur_dir;
}
close (FILE);

