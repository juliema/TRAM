"""Wrappers for the various assember programs."""

import os
import shutil
import subprocess


class Assembler:
    """A factory class for building the assembers."""

    @staticmethod
    def factory(args):
        """Return the assembler based upon the configuration options."""

        if args.assembler.lower() == 'trinity':
            return TrinityAssembler(args)
        elif args.assembler.lower() == 'velvet':
            return VeletAssembler(args)
        elif args.assembler.lower() == 'abyss':
            return AbyssAssembler(args)

    def __init__(self, args):
        self.args = args
        self.steps = []
        self.is_paired = False
        self.output_file = None
        self.long_reads_file = None
        self.single_ends_file = None
        self.ends_1_file = None
        self.ends_2_file = None

    @property
    def work_path(self):
        """The output directory name may have unique requirements."""

        return self.args.work_dir

    def command(self):
        """Build the command for assembly."""

        raise NotImplementedError()

    def assemble(self):
        """Use the assembler to build up the contigs. We take and array of
        subprocess steps and execute them in order. We then follow this up
        with a post assembly step.
        """

        print(self.steps)
        for step in self.steps:
            print(step())
            subprocess.check_call(step(), shell=True)

        self.post_assembly()

    def post_assembly(self):
        """Assembers have unique post assembly steps."""

    def path(self, temp_dir, file_name, iteration=0):
        """Files will go into the temp dir."""

        file_name = '{}.{:02d}.{}'.format(
            self.args.blast_db, iteration, file_name)

        return os.path.join(temp_dir, file_name)

    def iteration_files(self, temp_dir, iteration):
        """Files used by the assembler. Do this at the start of each
        iteration.
        """

        self.output_file = self.path(temp_dir, 'output.fasta', iteration)
        self.ends_1_file = self.path(temp_dir, 'paired_end_1.fasta', iteration)
        self.ends_2_file = self.path(temp_dir, 'paired_end_2.fasta', iteration)
        self.single_ends_file = self.path(
            temp_dir, 'single_end.fasta', iteration)


class AbyssAssembler(Assembler):
    """Wrapper for the Abyss assembler."""

    def __init__(self, args):
        super().__init__(args)
        self.steps = [self.abyss]

    def abyss(self):
        """Build the command for assembly."""

        cmd = ['abyss-pe']
        cmd.append('v=-v')
        cmd.append('E=0')
        cmd.append('k={}'.format(self.args.kmer))
        cmd.append('np={}'.format(self.args.cpus))
        cmd.append("name='{}'".format(self.output_file))

        if self.is_paired:
            cmd.append("in='{} {}'".format(self.ends_1_file, self.ends_2_file))
        else:
            cmd.append("se='{}'".format(self.ends_1_file))

        if self.long_reads_file and not self.args.no_long_reads:
            cmd.append("long='{}'".format(self.long_reads_file))

        return ' '.join(cmd)

    def post_assembly(self):
        """This assember has a unique post assembly step."""

        src = os.path.realpath(self.output_file + '-unitigs.fa')
        dst = self.output_file

        # shutil.move(src['raw_contigs'].name)
        with open(src) as in_file, open(dst, 'w') as out_file:
            for line in in_file:
                out_file.write(line)


class TrinityAssembler(Assembler):
    """Wrapper for the trinity assembler."""

    @property
    def work_path(self):
        """The output directory name has unique requirements."""

        return os.path.join(self.args.work_dir, 'trinity')

    def __init__(self, args):
        super().__init__(args)
        self.steps = [self.trinity]

    def trinity(self):
        """Build the command for assembly."""

        cmd = ['Trinity']
        cmd.append('--seqType fa')
        cmd.append('--max_memory {}'.format(self.args.max_memory))
        cmd.append('--CPU {}'.format(self.args.cpus))
        cmd.append("--output '{}'".format(self.work_path))
        cmd.append('--full_cleanup')

        if self.is_paired:
            cmd.append("--left '{}'".format(self.ends_1_file))
            cmd.append("--right '{}'".format(self.ends_2_file))
        else:
            cmd.append("-single '{}'".format(self.ends_1_file))
            cmd.append('--run_as_paired')

        if self.long_reads_file and not self.args.no_long_reads:
            cmd.append("--long_reads_file '{}'".format(self.long_reads_file))

        if not self.args.bowtie2:
            cmd.append('--no_bowtie')

        return ' '.join(cmd)

    def post_assembly(self):
        """This assember has a unique post assembly step."""

        file_name = os.path.join(self.args.work_dir, 'trinity.Trinity.fasta')
        shutil.move(file_name, self.output_file)


class VeletAssembler(Assembler):
    """Wrapper for the Velvet assembler."""

    def __init__(self, args):
        super().__init__(args)
        self.steps = [self.velveth, self.velvetg]

    def velveth(self):
        """Build the command for assembly."""

        cmd = ['velveth']

        return ' '.join(cmd)

    def velvetg(self):
        """Build the command for assembly."""

        cmd = ['velvetg']

        return ' '.join(cmd)
