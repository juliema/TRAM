##     Manual for aTRAM

Here are the required commands for running aTRAM as well as a few things to keep in mind for maximum efficiency.


## Setup:
To determine if aTRAM can run on your computer:
  perl configure.pl 
  
  This script will tell you if you need to download any new programs. If you do make sure they are in your $PATH. You can either add them directly to your /usr/bin directory or add the path to the programs to your $PATH. 
configure.pl will check for de novo aligners including velvet, trinity and SOAPdenovo, you only need to have one of these available. It will aslo check that you have muscle and blast, these programs are required.

configure.pl





Running on a cluster:

max_processes should equal number of threads

makelibraries.pl max processes is set to 4
