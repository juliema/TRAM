#!/usr/bin/env perl
use strict;
use Getopt::Long;
use Pod::Usage;
use File::Basename;
use File::Temp qw/ tempfile tempdir /;
use FindBin;
use lib "$FindBin::Bin/lib";
use Subfunctions;
use Module::Load;
require Sequenceretrieval;

load Assembler;
Assembler->parse_config();

my $debug = 0;

my $hit_matrix = {};

if (@ARGV == 0) {
    pod2usage(-verbose => 1);
}

my $runline = "running " . basename($0) . " " . join (" ", @ARGV) . "\n";

#required: input file names
my $atram_db = 0;
my $target_fasta = 0;

#optional parameters:
my $help = 0;
my $log_file = "";
my $output_file = "";
my $shards = 0;
my $fraction = 1;
my $temp_name = "";
my $save_temp = 0;
my $complete = 0;
my $protflag = 0;
my $bitscore = 70;
my $contiglength = 100;
my $max_processes = 0;

#parameters with modifiable default values
my $ins_length = 300;
my $iterations = 5;
my $start_iter = 1;
my $exp_cov = 30;
my $evalue = 10e-10;
my $max_target_seqs = 100000000;
my $assembler = "Velvet";
my $kmer = 31;

GetOptions ('reads|sra|database|db=s' => \$atram_db,
            'target=s' => \$target_fasta,
            'assembler=s' => \$assembler,
            'start_iteration=i' => \$start_iter,
            'iterations=i' => \$iterations,
			'fraction=f' => \$fraction,
            'log_file=s' => \$log_file,
            'output=s' => \$output_file,
            'protein' => \$protflag,
            'max_processes|processes=i' => \$max_processes,
            'tempfiles=s' => \$temp_name,
            'debug' => \$debug,
            'complete' => \$complete,
            'insert_length|ins_length=i' => \$ins_length,
            'exp_coverage|expected_coverage=i' => \$exp_cov,
            'kmer=i' => \$kmer,
            'bitscore=i' => \$bitscore,
            'evalue=f' => \$evalue,
            'length=i' => \$contiglength,
            'help|?' => \$help) or pod2usage(-msg => "GetOptions failed.", -exitval => 2);

if ($help) {
    pod2usage(-verbose => 1);
}

if ($debug) {
	set_debug(1);
}

# find the path specified in the .atram file, if provided.
if ($atram_db =~ /\.atram$/) {
	open ATRAM_FH, "<", $atram_db;
	$atram_db = readline ATRAM_FH;
	chomp $atram_db;
	close ATRAM_FH;
}

unless($atram_db and $target_fasta) {
    pod2usage(-msg => "Must specify a short read archive (that has already been prepared with makelibrary.pl) and a target gene in fasta form.");
}

# check to make sure that the specified short read archive exists:
unless ((-e "$atram_db.0.1.fasta") && (-e "$atram_db.0.2.fasta")) {
	pod2usage(-msg => "Short read archive does not seem to be in the format made by makelibrary.pl. Did you specify the name correctly?");
}


if ($output_file eq "") {
    $output_file = $atram_db;
}
if ($log_file eq "") {
	$log_file = "$output_file.log";
}
if ($temp_name eq "") {
    $temp_name = $output_file;
    $save_temp = 0;
} else {
	$save_temp = 1;
}

my $log_fh;
open $log_fh, ">", $log_file or die "couldn't open $log_file\n";
set_log($log_fh);

printlog ($runline);

my $executing_path = dirname(__FILE__);
my $cmd;

# set up the number of partial libraries we'll be using.
my $total_shards_available = get_total_shards("$atram_db");
my $max_shard = get_max_shard();

$shards = int ($total_shards_available * $fraction);

# obviously we need to use at least one shard.
if ($shards == 0) {
	$shards = 1;
}

unless ((-e "$atram_db.$max_shard.1.fasta") && (-e "$atram_db.$max_shard.2.fasta")) {
	pod2usage(-msg => "aTRAM database was improperly formatted.");
}

printlog ("Using $shards of $total_shards_available total shards.");

open CONTIGS_FH, ">", "$output_file.all.fasta";
truncate CONTIGS_FH, 0;
close CONTIGS_FH;

my $start_seq = "";
my $end_seq = "";
my @complete_contigs = ();

# process the target sequence file to look for the start seq and end seq.
my $search_fasta = $target_fasta;
my @target_seqs = ();

open SEARCH_FH, "<", $search_fasta;
my $name = "";
my $seq = "";
my $fullseq = "";
while (my $line=readline SEARCH_FH) {
	chomp $line;
	if ($line =~ />(.*)/) {
		if ($name ne "") {
			push @target_seqs, "$name,$seq";
		}
		$name = $1;
		$seq = "";
	} else {
		$seq .= $line;
		$fullseq .= $seq;
	}
}
push @target_seqs, "$name,$seq";

close SEARCH_FH;

my $protein = 0;
if ($protflag != 0) {
	$protein = 1;
} else {
	$protein = is_protein($fullseq);
}

my $len = 100;
if ($protein==1) {
	$len = 30;
}

# check first target seq, see if we need to make just the first bit separated for checking completeness.
my $firstseq = shift @target_seqs;
if ($firstseq =~ /(.*),(.{$len})(.*)/) {
	# split into two smaller seqs:
	$start_seq = "aTRAM_target_start";
	unshift @target_seqs, $firstseq;
	unshift @target_seqs, "$start_seq,$2";
} else {
	# it's short enough to just go as-is
	$firstseq =~ /(.*),/;
	$start_seq = $1;
	unshift @target_seqs, $firstseq;
}

# check last target seq, see if we need to make just the first bit separated for checking completeness.
my $lastseq = pop @target_seqs;
if ($lastseq =~ /(.*),(.*)(.{$len})/) {
	# split into two smaller seqs:
	$end_seq = "aTRAM_target_end";
	push @target_seqs, $lastseq;
	push @target_seqs, "$end_seq,$3";
} else {
	# it's short enough to just go as-is
	$lastseq =~ /(.*),/;
	$end_seq = $1;
	push @target_seqs, $lastseq;
}

# okay, let's re-assemble the file for the target fasta.
my ($TARGET_FH, $target_fasta) = tempfile(UNLINK => 1);
my @targets = ();
foreach my $line (@target_seqs) {
	$line =~ /(.*),(.*)/;
	print $TARGET_FH ">$1\n$2\n";
	push @targets, $1;
}

# make a database from the target so that we can compare contigs to the target.
my (undef, $targetdb) = tempfile(UNLINK => 1);
if ($protein == 1) {
	system_call ("makeblastdb -in $target_fasta -dbtype prot -out $targetdb.db -input_type fasta");
} else {
	system_call ("makeblastdb -in $target_fasta -dbtype nucl -out $targetdb.db -input_type fasta");
}

if ($start_iter > 1) {
	my $x = $start_iter-1;
	$search_fasta = "$temp_name.".($start_iter-1).".contigs.fasta";
}

# writing the header line for the results file
open RESULTS_FH, ">", "$output_file.results.txt";
print RESULTS_FH "contig\t" . join ("\t",@targets) . "\ttotal score\n";
close RESULTS_FH;

my $best_score = 0;

# STARTING ITERATIONS:
for (my $i=$start_iter; $i<=$iterations; $i++) {
	printlog ("iteration $i starting...");

	my @shardfiles = ();
	my @pids = ();

	################################################################
	# MAP steps:
	################################################################

	#   blast search in each shard:
	print "\tblasting short reads...\n";
	for (my $s=0; $s<$shards; $s++) {
		my $current_shard = "$temp_name.blast.$i.$s";
		push @shardfiles, $current_shard;
		# 1. blast to find any short reads that match the target.
		if (($protein == 1) && ($i == 1)) {
			push @pids, fork_cmd ("tblastn -max_target_seqs $max_target_seqs -db $atram_db.$s.db -query $search_fasta -outfmt '6 sseqid' -out $current_shard");
		} else {
			push @pids, fork_cmd ("blastn -task blastn -evalue $evalue -max_target_seqs $max_target_seqs -db $atram_db.$s.db -query $search_fasta -outfmt '6 sseqid' -out $current_shard");
		}
		if (($max_processes > 0) && (@pids >= ($max_processes - 1))) {
			# don't spawn off too many threads at once.
			wait_for_forks(\@pids);
		}
	}
	wait_for_forks(\@pids);

	#   find the blast-hit paired sequences in each shard:
	print "\tgetting paired ends...\n";
	for (my $s=0; $s<$shards; $s++) {
		my $current_shard = "$temp_name.blast.$i.$s";
		# 2 and 3. find the paired end of all of the blast hits.
		push @pids, fork_pair_retrieval("$atram_db.$s.#.fasta", "$current_shard", "$current_shard.fasta");
		if (($max_processes > 0) && (@pids >= ($max_processes - 1))) {
			# don't spawn off too many threads at once.
			wait_for_forks(\@pids);
		}
	}
	wait_for_forks(\@pids);

	################################################################
	# REDUCE steps:
	################################################################

	#   join the fasta results of each shard into a single fasta file:
	my $fastafiles = join (" ", map {$_ . ".fasta"} @shardfiles);
	system_call ("cat $fastafiles > $temp_name.$i.blast.fasta");

	#   remove shards' fasta results
	system_call ("rm $fastafiles");

	#   remove shards' blast results
	my $readfiles = join (" ", @shardfiles);
	system_call ("rm $readfiles");

	# SHUTDOWN CHECK: did we not find any reads? Go ahead and quit.
	if ((-s "$temp_name.$i.blast.fasta") == 0) {
		printlog ("No similar reads were found.");
		last;
	}
	my $contigs_file = "";
	if ($save_temp) {
		$contigs_file = "$temp_name.$i.contigs.fasta";
	} else {
		(undef, $contigs_file) = tempfile(UNLINK => 1);
	}

	#   assemble the sequences:
	print "\tassembling pairs with $assembler...\n";
	load "$assembler";

	my $assembly_params = { 'kmer' => $kmer,
							'tempdir' => "$temp_name.$assembler",
							'ins_length' => $ins_length,
							'exp_cov' => $exp_cov,
							'min_contig_len' => 200,
						  };

	if ($i > 1) {
		# for iterations after the first one, we can use previous contigs to seed the assembly.
		$assembly_params->{'longreads'} = $search_fasta;
	}

	my $assembled_contigs = "$assembler"->assembler ("$temp_name.$i.blast.fasta", $assembly_params);
 	"$assembler"->write_contig_file($assembled_contigs, $contigs_file);

	if ($save_temp == 0) {
		system_call ("rm $temp_name.$i.blast.fasta");
	}

	# filter out the contigs to look for just the best ones:
	print "\tfiltering contigs...\n";

	my $blast_file = "";
	if ($save_temp) {
		$blast_file = "$temp_name.$i.blast";
	} else {
		(undef, $blast_file) = tempfile(UNLINK => 1);
	}

	if ($protein == 1) {
		system_call ("blastx -db $targetdb.db -query $contigs_file -out $blast_file -outfmt '6 qseqid sseqid bitscore qstart qend sstart send qlen'");
	} else {
		system_call ("tblastx -db $targetdb.db -query $contigs_file -out $blast_file -outfmt '6 qseqid sseqid bitscore qstart qend sstart send qlen'");
	}

	# we want to keep the contigs that have a bitscore higher than $bitscore.
	print "\tsaving best-scoring contigs...\n";
	my $raw_hit_matrix = {};
	make_hit_matrix ($blast_file, $raw_hit_matrix, $i);

	if ($save_temp == 0) {
		system_call ("rm $blast_file");
	}
	my @contig_names = ();
	my $old_matrix_size = (keys %$hit_matrix);
	my $high_score = process_hit_matrix ($raw_hit_matrix, \@targets, $bitscore, $contiglength, $hit_matrix, \@contig_names);

	if ($high_score > $best_score) {
		$best_score = $high_score;
	}

	# SHUTDOWN CHECK:
	if ((keys %$hit_matrix) == $old_matrix_size) {
		printlog ("No new contigs were found.");
		last;
	}

	# SHUTDOWN CHECK:
	if (@contig_names == 0) {
		printlog ("No contigs had a bitscore greater than $bitscore and longer than $contiglength in iteration $i: the highest bitscore this time was $high_score.");
		last;
	}

	# we've finished the work of the iteration. Now we do post-processing to save results to files.
	my $contig_seqs = findsequences ($contigs_file, \@contig_names);

	# we'll use the resulting contigs as the query for the next iteration.
	if ($save_temp) {
		$search_fasta = "$temp_name.$i.contigs.fasta";
	} else {
		(undef, $search_fasta) = tempfile(UNLINK => 1);
	}
	open SEARCH_FH, ">", $search_fasta;
	foreach my $contig_name (@contig_names) {
		print SEARCH_FH ">$contig_name\n$contig_seqs->{$contig_name}\n";
	}
	close SEARCH_FH;

	# save off these resulting contigs to the ongoing contigs file.
	open CONTIGS_FH, ">>", "$output_file.all.fasta";
	printlog ("\twriting contigs to $output_file.all.fasta:");
	foreach my $contig_name (@contig_names) {
		my $seq = $contig_seqs->{$contig_name};
		# revcomping contigs with negative strand directions:
		if ($hit_matrix->{$contig_name}->{"strand"} < 0) {
			printlog ("\t\twriting out reverse-complement of $contig_name");
			$seq = reverse_complement($seq);
			print CONTIGS_FH ">$i.$contig_name\n$seq\n";
		} else {
			printlog ("\t\twriting out $contig_name");
			print CONTIGS_FH ">$i.$contig_name\n$seq\n";
		}
		$hit_matrix->{$contig_name}->{"seq"} = $seq;
	}
	close CONTIGS_FH;

	open RESULTS_FH, ">>", "$output_file.results.txt";
	foreach my $contig_name (@contig_names) {
		print RESULTS_FH "$i.$contig_name\t";
		foreach my $target (@targets) {
			my $score = $hit_matrix->{$contig_name}->{$target};
			if ($score == undef) {
				print RESULTS_FH "-\t";
			} else {
				print RESULTS_FH "$score\t";
			}
		}
		my $total = $hit_matrix->{$contig_name}->{"total"};
		print RESULTS_FH "$total\n";
		if ((abs($hit_matrix->{$contig_name}->{$start_seq}) > 20) && (abs($hit_matrix->{$contig_name}->{$end_seq}) > 20)) {
			push @complete_contigs, "$i.$contig_name";
		}
	}
	close RESULTS_FH;

	# SHUTDOWN CHECK:
	if ($complete == 1) {
		if (@complete_contigs > 0) {
			printlog ("Contigs that cover the entire target sequence were found; quitting at iteration $i.");
			last;
		}
	}
}

print "\n\nContigs by target coverage:\n";

system ("cat $output_file.results.txt");

printlog ("Contigs containing the entire target sequence:\n\t" . join("\n\t", @complete_contigs) . "");

close $log_fh;

if (@complete_contigs > 0) {
	open COMPLETE_FH, ">", "$output_file.complete.fasta";
	foreach my $contig_name (@complete_contigs) {
		$contig_name =~ /(\d+)\.(.+)/;
		print COMPLETE_FH ">$contig_name\n$hit_matrix->{$2}->{'seq'}\n";
	}
	close COMPLETE_FH;
}

my @best_unsorted = ();
foreach my $contig_name (keys %$hit_matrix) {
	if ($hit_matrix->{$contig_name}->{"total"} > ($best_score - 100)) {
		push @best_unsorted, $contig_name;
	}
}

if (@best_unsorted > 0) {
	my @best_contigs = sort sort_contigs @best_unsorted;
	open BEST_FH, ">", "$output_file.best.fasta";
	foreach my $contig_name (@best_contigs) {
		print BEST_FH ">$hit_matrix->{$contig_name}->{'iteration'}.$contig_name\n$hit_matrix->{$contig_name}->{'seq'}\n";
	}
	close BEST_FH;
}

sub sort_contigs {
	if ($hit_matrix->{$a}->{"total"} < $hit_matrix->{$b}->{"total"}) {
		return 1;
	} elsif ($hit_matrix->{$a}->{"total"} > $hit_matrix->{$b}->{"total"}) {
		return -1;
	} else {
		if (length($hit_matrix->{$a}->{"seq"}) < length($hit_matrix->{$b}->{"seq"})) {
			return 1;
		} elsif (length($hit_matrix->{$a}->{"seq"}) > length($hit_matrix->{$b}->{"seq"})) {
			return -1;
		}
	}
	return 0;
}

sub reverse_complement {
	my $charstr = shift;

	# reverse the DNA sequence
	my $revcomp = reverse($charstr);

	# complement the reversed DNA sequence
	$revcomp =~ tr/ABCDGHMNRSTUVWXYabcdghmnrstuvwxy/TVGHCDKNYSAABWXRtvghcdknysaabwxr/;
	return $revcomp;
}


__END__

=head1 NAME

aTRAM.pl

=head1 SYNOPSIS

aTRAM.pl -sra atram_db -target target.fasta [-output filename] [-iterations int] [-start_iteration int] [-log_file filename] -options

aTRAM does targeted denovo assembly of short reads to find homologs or paralogs of a target sequence.

=head1 OPTIONS
  pipeline parameters:
  -sra|database|db: aTRAM database name (already run through format_sra.pl).
  -target:          fasta file with sequences of interest.
  -output:	        optional: the prefix for the pipeline's output files (default name is the same as -sra).
  -log_file:        optional: a file to store output of the pipeline.
  -tempfiles:       optional: use this name to save the intermediate files from the run.
  -iterations:      optional: the number of pipeline iterations (default 5).
  -start_iteration: optional: if resuming from previous run, which iteration number to start from (default 0).

  optional parameters:
  -protein:         if the target sequence is a protein fasta file (not mandatory, aTRAM will guess).
  -complete:        if specified, automatically quits when a complete homolog is recovered.
  -fraction:        if specified, use only specified fraction of the aTRAM database.
  -processes:       if specified, aTRAM will use no more than this number of processes for multiprocessing.

  optional assembly parameters:
  -assembler:       software to be used for targeted assembly (default is Velvet).
  -ins_length:	    the size of the fragments used in the short-read library (default 300).
  -exp_coverage:    the expected coverage of the region for velvetg (default 30).
  -kmer:            kmer size for assemblers that use it (default 31).

  optional values for searching short reads:
  -evalue:          default value is 10e-10.

  optional values for blast-filtering contigs:
  -bitscore:        default value is 70.
  -length:          default value is 100.

=cut

