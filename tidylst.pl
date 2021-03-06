#!/usr/bin/perl

use strict;
use warnings;
use Fatal qw( open close );             # Force some built-ins to die on error
use English qw( -no_match_vars );       # No more funky punctuation variables

my $VERSION        = "1.04.00";
my $VERSION_DATE   = "2019-02-07";
my ($PROGRAM_NAME) = "TidyLst";
my ($SCRIPTNAME)   = ( $PROGRAM_NAME =~ m{ ( [^/\\]* ) \z }xms );
$SCRIPTNAME        = "PCGen " . $SCRIPTNAME;
my $VERSION_LONG   = "$SCRIPTNAME version: $VERSION -- $VERSION_DATE";

my $today = localtime;

use Carp;
use FileHandle;
use Pod::Html ();  # We do not import any function for
use Pod::Text ();  # the modules other than "system" modules
use Pod::Usage ();
use File::Find ();

# Expand the local library path so we can find TidyLst modules
use File::Basename qw(dirname fileparse);
use Cwd qw(abs_path);
use lib dirname(abs_path $0) . '/lib';

use TidyLst::Convert qw(convertEntities);
use TidyLst::Data qw(
   BLOCK BLOCK_HEADER COMMENT FIRST_COLUMN LINE LINE_HEADER MAIN
   NO NO_HEADER SINGLE SUB YES
   addSourceToken
   addTagsForConversions
   constructValidTags
   isValidGamemode
   isValidTag
   seenSourceToken
   setFileHeader
   updateValidity
   );
use TidyLst::File;
use TidyLst::Line;
use TidyLst::Log;
use TidyLst::LogFactory qw(getLogger);
use TidyLst::LogHeader;
use TidyLst::Options qw(getOption isConversionActive parseOptions setOption);
use TidyLst::Parse qw(
   create_dir
   extractTag
   isParseableFileType
   isWriteableFileType
   normaliseFile
   parseSystemFiles
   processFile
   );
use TidyLst::Report qw(
   closeExportListFileHandles
   makeExportListString
   openExportListFileHandles
   printToExportList
   );
use TidyLst::Validate qw(scanForDeprecatedTokens validateLine);

# Subroutines
sub generate_css;

# Print version information
print STDERR "$VERSION_LONG\n";

setFileHeader("# $today -- reformatted by $SCRIPTNAME v$VERSION\n");

#######################################################################
# Parameter parsing

# Parse the command line options and set the error message if there are any issues.
my $errorMessage = "\n" . parseOptions(@ARGV);
my $dumpValidEntities = 0;

# Test function or display variables or anything else I need.
if ( getOption('test') ) {

   $dumpValidEntities = 1;
   # print "No tests set\n";
   # exit;
}

# The command line has been processed, if conversions have been requested, make
# sure the tag validity data in Reformat.pm is updated. In order to convert a
# tag it must be recognised as valid.
addTagsForConversions();

# Create the singleton logging object
my $log = getLogger();

#######################################################################
# Redirect STDERR if requeseted

if (getOption('outputerror')) {
   open STDERR, '>', getOption('outputerror');
   print STDERR "Error log for $VERSION_LONG\n";
   print STDERR qq{On the files in "} . getOption('inputpath') . qq{" on $today\n};
}

#######################################################################
# Path options

if (!getOption('inputpath') && !getOption('filetype') &&
   !(getOption('man') || getOption('htmlhelp')))
{
   $errorMessage .= "\n-inputpath parameter is missing\n";
   setOption('help', 1);
}

# Verify that the outputpath exists
if ( getOption('outputpath') && !-d getOption('outputpath') ) {

   $errorMessage = "\nThe directory " . getOption('outputpath') . " does not exist.";

   Pod::Usage::pod2usage(
      {
         -msg     => $errorMessage,
         -exitval => 1,
         -output  => \*STDERR,
      }
   );
   exit;
}

#######################################################################
# Diplay usage information

if ( getOption('help') or $TidyLst::Options::error ) {
   Pod::Usage::pod2usage(
      {
         -msg     => $errorMessage,
         -exitval => 1,
         -output  => \*STDERR
      }
   );
   exit;
}

#######################################################################
# Display the man page

if (getOption('man')) {
   Pod::Usage::pod2usage(
      {
         -msg     => $errorMessage,
         -verbose => 2,
         -output  => \*STDERR
      }
   );
   exit;
}

# Generate the HTML page

if ( getOption('htmlhelp') ) {

   my $lower = lc $PROGRAM_NAME;
   my $root  = $lower =~ qr/\.pl$/ ? $lower =~ s/^(.\+)\.pl$/${1}/r : $lower;
   my $name  = $root . ".pl";

   if( !-e "$root.css" ) {
      generate_css("$root.css");
   }

   Pod::Html::pod2html(
      "--infile=${name}",
      "--outfile=${root}.html",
      "--css=${root}.css",
      "--title=${root} -- Reformat the PCGEN .lst files",
      '--header',
   );

   exit;
}

#######################################################################
# -systempath option
#
# If a system path was passed on the command line, call the function to
# generate the "game mode" variables.

if ( getOption('systempath') ne q{} ) {
   parseSystemFiles(getOption('systempath'));
}

# For some tags, validity is based on the system mode variables
updateValidity();

# PCC processing
my %files = ();

# Will hold the file to parse (including path) as the key, the value is the
# filetype
my %filesToParse;

# Holds the name of files that are modified by the script.
my @modifiedFiles;

#####################################
# Verify if the inputpath was given

if (getOption('inputpath')) {

   # Construct the valid tags for all file types
   constructValidTags();

   ##########################################################
   # Files that needs to be open for special conversions

   if (getOption('exportlist')) {
      openExportListFileHandles();
   }

   ##########################################################
   # Parse all the .pcc file to find the other file to parse

   # First, we list the .pcc files in the directory
   my @pccList;
   my %fileListNotPCC;
   my %fileListMissing;

   # Regular expressions for the files that must be skiped by mywanted.
   my @filetoskip = (
      qr(^\.\#),              # Files begining with .# (CVS conflict and deleted files)
      qr(^custom),            # Customxxx files generated by PCGEN
      qr(placeholder\.txt$),  # The CMP directories are full of these
      qr(\.zip$)i,            # Archives present in the directories
      qr(\.rar$)i,
      qr(\.jpg$),             # JPEG image files present in the directories
      qr(\.png$),             # PNG image files present in the directories
      qr(readme\.txt$),       # Readme files
      qr(\.bak$),             # Backup files
      qr(\.java$),            # Java code files
      qr(\.htm$),             # HTML files
      qr(\.xml$),
      qr(\.css$),

      qr(\.DS_Store$),        # Used with Mac OS
   );

   # Regular expressions for the directory that must be skiped by mywanted
   my @dirtoskip = (
      qr(cvs$)i,              # /cvs directories
      qr([.]svn[/])i,         # All .svn directories
      qr([.]svn$)i,           # All .svn directories
      qr([.]git[/])i,         # All .git directories
      qr([.]git$)i,           # All .git directories
      qr(customsources$)i,    # /customsources (for files generated by PCGEN)
      qr(gamemodes)i,         # for the system gameModes directories
   );

   sub mywanted {

      # We skip the files from directory matching the REGEX in @dirtoskip
      for my $regex (@dirtoskip) {
         return if $File::Find::dir =~ $regex;
      }

      # We also skip the files that match the REGEX in @filetoskip
      for my $regex (@filetoskip) {
         return if $_ =~ $regex;
      }

      # It's not a directory and ends with pcc
      if ( !-d && m/ [.] pcc \z /xmsi ) {
         push @pccList, $File::Find::name;
      }

      # It's not a directory and doesn't end with pcc
      #
      # All the lst files end up here, along with any other file. Anything not
      # specifically referenced later by a pcc will be reported as spurious
      # extra files
      if ( !-d && !/ [.] pcc \z /xmsi ) {
         $fileListNotPCC{$File::Find::name} = lc $_;
      }
   }

   File::Find::find( \&mywanted, getOption('inputpath') );

   $log->header(TidyLst::LogHeader::get('PCC'));

   # Second we parse every .PCC and look for filetypes
   for my $pccName ( sort @pccList ) {
      open my $pcc_fh, '<', $pccName;

      # Needed to find the full path
      my ($dummy, $currentbasedir) = fileparse($pccName);

      my %found = (
         'book type'    => NO,
         'gamemode'     => q{},
         'header'       => NO,
         'lst'          => NO,
         'source long'  => q{},
         'source short' => q{},
      );

      my $mustWrite      = NO;
      my @pccLines       = ();
      my %foundFileType;
      my @gameModes;
      my $gameModesRef = \@gameModes;

      PCC_LINE:
      for my $pccLine ( <$pcc_fh> ) {

         chomp $pccLine;
         $mustWrite += $pccLine =~ s/[\x0d\x0a]//g; # Remove the real and weird CR-LF
         $mustWrite += $pccLine =~ s/\s+$//;        # Remove any tralling white spaces

         push @pccLines, $pccLine;

         # This is a PCC file, there is only one tag on a line
         my ($tag, $value) = extractTag(
            $pccLine,
            'PCC',
            $pccName,
            $pcc_fh->input_line_number,
         );

         # If extractTag returns a defined $value, no further processing is
         # neeeded. If $value is not defined, then the tag that was returned
         # should be processed further.

         my $fullToken = (not defined $value) ? $tag : "$tag:$value" ;

         my $token =  TidyLst::Token->new(
            fullToken => $fullToken,
            lineType  => 'PCC',
            file      => $pccName,
            line      => $pcc_fh->input_line_number,
         );

         if (not defined $value) {

            # All of the individual tag parsing and correcting happens here,
            # this potentally modifies the tag
            $token->process();

            # If the tag has been altered, the the PCC file needs to be
            # written and the line should be overwritten.
            if ($token->origToken ne $token->fullRealToken) {
               $mustWrite = 1;
               $pccLines[-1] = $token->fullRealToken;
            }
         }

         if ($token->tag) {

            # Used to do this near the end, but if its active we want it to do its thing
            # before we check 'GAMEMODE'
            if ( $token->tag eq 'GAME' && isConversionActive('PCC:GAME to GAMEMODE') ) {

               $token->tag('GAMEMODE');

               $pccLines[-1] = $token->fullRealToken;
               $log->warning(
                  q(Replacing ") . $token->origToken . q(" by ") . $token->fullRealToken . q("),
                  $pccName,
                  $pcc_fh->input_line_number,
               );
               $found{'gamemode'} = $token->value;
               $mustWrite = 1;
            }

            if (isParseableFileType($token->tag)) {

               # Keep track of the filetypes found
               $foundFileType{$token->tag}++;

               # Extract the name of the LST file from the token->value, and
               # store it back into token->value
               $token->value($token->value =~ s/^([^|]*).*/$1/r);

               my $file = TidyLst::File->new(
                  'gameMode'     => $gameModesRef,
                  'originalName' => $token->value,
                  'pccDirectory' => $currentbasedir,
                  'type'         => $token->tag,
               );
               
               my $lstFile = $file->inputName;

               $filesToParse{$lstFile} = $file;

               # Check to see if the file exists
               if ( !-e $lstFile ) {

                  $fileListMissing{$lstFile} = [ $pccName, $pcc_fh->input_line_number ];
                  delete $filesToParse{$lstFile};

               # Remember some types of file, as there might be a need to
               # process them first.
               } elsif (
                     $token->tag eq 'ALIGNMENT'
                  || $token->tag eq 'CLASS'
                  || $token->tag eq 'DOMAIN'
                  || $token->tag eq 'SAVE'
                  || $token->tag eq 'SPELL'
                  || $token->tag eq 'STAT'
               ) {

                  $files{$token->tag}{$lstFile} = 1;
               }

               # not a spurious extra file
               if (exists $fileListNotPCC{$lstFile}) {
                  delete $fileListNotPCC{$lstFile}
               }
               $found{'lst'} = 1;

            } elsif ( $token->tag =~ m/^\#/ ) {

               if ($token->tag =~ $TidyLst::Data::headerPattern) {
                  $found{'header'} = 1;
               }

            } elsif (isValidTag('PCC', $token->tag)) {

               # All the tags that do not have a file should be caught here

               # Get the SOURCExxx tags for future ref.
               if (isConversionActive('SOURCE line replacement')
                  && (  $token->tag eq 'SOURCELONG'
                     || $token->tag eq 'SOURCESHORT'
                     || $token->tag eq 'SOURCEWEB'
                     || $token->tag eq 'SOURCEDATE' ) )

               {
                  # If a token with the same tag has been seen in this directory
                  if (seenSourceToken($currentbasedir, $token) && $currentbasedir !~ /custom|altpcc/i ) {

                     $log->notice(
                        $token->tag . " already found for $currentbasedir",
                        $pccName,
                        $pcc_fh->input_line_number,
                     );

                  } else {
                     addSourceToken($currentbasedir, $token);
                  }

                  # For the PCC report
                  if ( $token->tag eq 'SOURCELONG' ) {
                     $found{'source long'} = $token->value;
                  } elsif ( $token->tag eq 'SOURCESHORT' ) {
                     $found{'source short'} = $token->value;
                  }

               } elsif ( $token->tag eq 'GAMEMODE' ) {

                  # Verify that the GAMEMODEs are valid and match the filer.
                  my $gameModeOption = getOption('gamemode');
                  my $gameModeRegex  = $gameModeOption ? qr{ \A (?: $gameModeOption  ) \z }xmsi : qr{ . }xms;
                  my $validGameMode  = $gameModeOption ? 0 : 1;

                  $found{'gamemode'} = $token->value;
                  @gameModes = split /[|]/, $token->value;

                  # First the filter is applied
                  for my $mode (@gameModes) {
                     if ( $mode =~ $gameModeRegex ) {
                        $validGameMode = 1;
                     }
                  }

                  # Then we check if the game mode is valid only if the game
                  # modes have not been filtered out
                  if ($validGameMode) {
                     for my $mode (@gameModes) {
                        if ( ! isValidGamemode($mode) ) {
                           $log->notice(
                              qq{Invalid GAMEMODE "$mode" in "$_"},
                              $pccName,
                              $pcc_fh->input_line_number,
                           );
                        }
                     }
                  }

                  if ( !$validGameMode ) {

                     # We set the variables that will kick us out of the while
                     # loop that read the file and that will prevent the file
                     # from being written.

                     $mustWrite       = NO;
                     $found{'header'} = NO;
                     last PCC_LINE;
                  }

               } elsif ( $token->tag eq 'BOOKTYPE' || $token->tag eq 'TYPE' ) {

                  # Found a TYPE tag
                  $found{'book type'} = 1;
               }
            }

         } elsif ( $pccLine =~ m/ \A [#] /xms ) {

            if ($pccLine =~ $TidyLst::Data::headerPattern) {
               $found{'header'} = 1;
            }

         } elsif ( $pccLine =~ m/ <html> /xmsi ) {
            $log->error(
               "HTML file detected. Maybe you had a problem with your git checkout.\n",
               $pccName
            );
            $mustWrite = NO;
            last PCC_LINE;
         }
      }

      close $pcc_fh;

      if ( !$found{'book type'} && $found{'lst'} ) {
         $log->notice( 'No BOOKTYPE tag found', $pccName );
      }

      if (!$found{'gamemode'}) {
         $log->notice( 'No GAMEMODE tag found', $pccName );
      }

      if ( $found{'gamemode'} && getOption('exportlist') ) {
         printToExportList('PCC',
            makeExportListString(@found{('source long', 'source short', 'gamemode')}, $pccName));
      }

      # Do we copy the .PCC???
      if ( getOption('outputpath') && ($mustWrite || !$found{'header'}) && isWriteableFileType("PCC") ) {
         my $newPccFile = $pccName;
         my $inputpath  = getOption('inputpath');
         my $outputpath = getOption('outputpath');
         $newPccFile =~ s/${inputpath}/${outputpath}/i;

         # Needed to find the full path
         my ($file, $basedir) = fileparse($newPccFile);

         # Create the subdirectory if needed
         create_dir($basedir, getOption('outputpath'));

         open my $newPccFh, '>', $newPccFile;

         # We keep track of the files we modify
         push @modifiedFiles, $pccName;

         # While the first line is any sort of comment about pretty lst or TidyLst,
         # we remove it
         REMOVE_HEADER:
         while (  $pccLines[0] =~ $TidyLst::Data::CVSPattern
               || $pccLines[0] =~ $TidyLst::Data::headerPattern) {
            shift @pccLines;
            last REMOVE_HEADER if not defined $pccLines[0];
         }

         print {$newPccFh} $TidyLst::Data::TidyLstHeader;

         for my $line (@pccLines) {
            print {$newPccFh} "$line\n";
         }

         close $newPccFh;
      }
   }

   # Is there anything to parse?
   if ( !keys %filesToParse ) {

      $log->error(
         qq{Could not find any .lst file to parse.},
         getOption('inputpath')
      );

      $log->error(
         qq{Is your -inputpath parameter valid? (} . getOption('inputpath') . ")",
         getOption('inputpath')
      );

      if ( getOption('gamemode') ) {
         $log->error(
            qq{Is your -gamemode parameter valid? (} . getOption('gamemode') . ")",
            getOption('inputpath')
         );
         exit;
      }
   }

   # Missing .lst files must be printed
   if ( keys %fileListMissing ) {

      $log->header(TidyLst::LogHeader::get('Missing LST'));

      for my $lstfile ( sort keys %fileListMissing ) {
         $log->notice(
            "Can't find the file: $lstfile",
            @{$fileListMissing{$lstfile}}
         );
      }
   }

   # If the gamemode filter is active, we do not report files not refered to.
   if ( keys %fileListNotPCC && !getOption('gamemode') ) {

      $log->header(TidyLst::LogHeader::get('Unreferenced'));

      my $basepath = getOption('basepath');

      for my $file ( sort keys %fileListNotPCC ) {
         $file =~ s/${basepath}//i;
         $file =~ tr{/}{\\} if $^O eq "MSWin32";

         $log->notice("$file\n", "");
      }
   }
}

$log->header(TidyLst::LogHeader::get('LST'));

my @filesToParse_sorted = ();
my %temp_filesToParse   = %filesToParse;

# This bit used to be separate checks and it only pulled files forward if
# certain conversions were active. It turns out that that ordering was
# mututally exclusive and we can just do it all, all the time. I've left the
# separate comments explaining why some files are pulled to the front of the
# list.
#
# ALIGNMENT SAVE and STAT are files that were previously in the gamemode, put
# them first so we can extract valid Alignments, saves and stats for validating
# later files (not done at the moment - Jan 2019).
#
# The CLASS files must be put early in the filesToParse_sorted array in
# order for them to be dealt with before the SPELL files.
#
# The SPELL file must be loaded before the EQUIPMENT in order to properly
# generate the EQMOD tags

for my $filetype (qw(ALIGNMENT SAVE STAT CLASS SPELL)) {
   for my $file_name ( sort keys %{ $files{$filetype} } ) {
      push @filesToParse_sorted, $file_name;
      delete $temp_filesToParse{$file_name};
   }
}

# We sort the files that need to be parsed.
push @filesToParse_sorted, sort keys %temp_filesToParse;

FILE_TO_PARSE:
for my $fileName (@filesToParse_sorted) {

   my $modified = processFile($filesToParse{$fileName});

   # We keep track of the files we modify
   if ($modified) {
      push @modifiedFiles, $fileName;
   }
}

# Print a report with the modified files
if ( getOption('outputpath') && scalar(@modifiedFiles) ) {

   my $outputpath = getOption('outputpath');

   if ($^O eq "MSWin32") {
      $outputpath =~ tr{/}{\\}
   }

   $log->header(TidyLst::LogHeader::get('Created'), getOption('outputpath'));

   my $inputpath = getOption('inputpath');
   for my $file (@modifiedFiles) {
      $file =~ s{ ${inputpath} }{}xmsi;
      $file =~ tr{/}{\\} if $^O eq "MSWin32";
      $log->notice( "$file\n", "" );
   }

   print STDERR "================================================================\n";
}

# Print a report for the BONUS and PRExxx usage
if (getOption('bonusreport')) {
   TidyLst::Report::reportBonus();
}

if (getOption('report')) {
   TidyLst::Report::report('Valid');
}

if (TidyLst::Report::foundInvalidTags()) {
   TidyLst::Report::report('Invalid');
}

if (getOption('xcheck')) {
   TidyLst::Report::doXCheck();
}

# Close the files that were opened for special reports

if ( getOption('exportlist') ) {
   closeExportListFileHandles();
}

if ($dumpValidEntities) {
   TidyLst::Data::dumpValidEntities();
}

# Close the redirected STDERR if needed
if (getOption('outputerror')) {
   close STDERR;
   print STDOUT "\cG"; # An audible indication that PL has finished.
}


# Generate a new .css file for the .html help file.

sub generate_css {
   my ($newfile) = shift;

   open my $css_fh, '>', $newfile or die "Can't open ${newfile} for writing.";

   print {$css_fh} << 'END_CSS';
BODY {
   font: small verdana, arial, helvetica, sans-serif;
   color: black;
   background-color: white;
}

A:link    {color: #0000FF}
A:visited {color: #666666}
A:active  {color: #FF0000}


H1 {
   font: bold large verdana, arial, helvetica, sans-serif;
   color: black;
}


H2 {
   font: bold large verdana, arial, helvetica, sans-serif;
   color: maroon;
}


H3 {
   font: bold medium verdana, arial, helvetica, sans-serif;
   color: blue;
}


H4 {
   font: bold small verdana, arial, helvetica, sans-serif;
   color: maroon;
}


H5 {
   font: bold small verdana, arial, helvetica, sans-serif;
   color: blue;
}


H6 {
   font: bold small verdana, arial, helvetica, sans-serif;
   color: black;
}


UL {
   font: small verdana, arial, helvetica, sans-serif;
   color: black;
}


OL {
   font: small verdana, arial, helvetica, sans-serif;
   color: black;
}


LI
{
   font: small verdana, arial, helvetica, sans-serif;
   color: black;
}

TH {
   font: small verdana, arial, helvetica, sans-serif;
   color: blue;
}


TD {
   font: small verdana, arial, helvetica, sans-serif;
   color: black;
}

TD.foot {
   font: medium sans-serif;
   color: #eeeeee;
   background-color="#cc0066"
}

DL {
   font: small verdana, arial, helvetica, sans-serif;
   color: black;
}


DD {
   font: small verdana, arial, helvetica, sans-serif;
   color: black;
}


DT {
   font: small verdana, arial, helvetica, sans-serif;
   color: black;
}


CODE {
   font: small Courier, monospace;
}


PRE {
   font: small Courier, monospace;
}


P.indent {
   font: small verdana, arial, helvetica, sans-serif;
   color: black;
   background-color: white;
   list-style-type : circle;
   list-style-position : inside;
   margin-left : 16.0pt;
}

PRE.programlisting
{
   list-style-type : disc;
   margin-left : 16.0pt;
   margin-top : -14.0pt;
}


INPUT {
   font: bold small verdana, arial, helvetica, sans-serif;
   color: black;
   background-color: white;
}


TEXTAREA {
   font: bold small verdana, arial, helvetica, sans-serif;
   color: black;
   background-color: white;
}

.BANNER {
   background-color: "#cccccc";
   font: bold medium verdana, arial, helvetica, sans-serif;
}
END_CSS

   close $css_fh;
}

__END__

=head1 NAME

tidylist.pl -- Reformat the PCGEN .lst files

Version: 1.00.00

=head1 DESCRIPTION

B<tidylst.pl> is a script that parses PCGEN .lst files and generates
new ones with ordered fields. The original order was given by Mynex.

The script is also able to do some conversions of the .lst so that old
versions are made compatible with the latest release of PCGEN.

=head1 INSTALLATION

=head2 Get Perl

I'm using perl v5.24.1 built for debian but any standard distribution should
work. Note with Windows 10, you can install various versions of linux as a
service and these make running perl very easy.

he script uses only two nonstandard modules, which you can get from cpan,
or if you use a package manager (activestate, debian etc.) you can get them
from there, for instance for debian:

   apt install libmouse-perl
   apt-install libmousex-nativetraits-perl

and for activestate:

  ppm install Mouse
  ppm install MouseX-NativeTraits    

=head2 Put the script somewhere

Once Perl is installed on your computer, you just have to find a home for the
script. After that, all you have to do is type B<perl tidylst.pl> with the
proper parameters to make it work.

=head1 SYNOPSIS

  # parse all the files in PATH, create the new ones in NEWPATH
  # and produce a report of the TAG in usage
  perl tidylst.pl -inputpath=<PATH> -outputpath=<NEWPATH> -report
  perl tidylst.pl -i=<PATH> -o=<NEWPATH> -r

  # parse all the files in PATH and write the error messages in ERROR_FILE
  # without creating any new files
  perl tidylst.pl -inputpath=<PATH> -outputerror=<ERROR_FILE>
  perl tidylst.pl -i=<PATH> -e=<ERROR_FILE>

  # parse all the files in PATH and write the error messages in ERROR_FILE
  # without creating any new files
  # A compilation of cross-checking (xcheck) errors will not be displayed and
  # only the messages of warning level notice or worst will be outputed.
  perl tidylst.pl -noxcheck -warninglevel=notice -inputpath=<PATH> -outputerror=<ERROR_FILE>
  perl tidylst.pl -nx -wl=notice -i=<PATH> -e=<ERROR_FILE>

  # parse all the files in PATH and created new ones in NEWPATH
  # by applaying the conversion pcgen5713. The output is redirected
  # to ERROR_FILE
  perl tidylst.pl -inputpath=<PATH> -outputpath=<NEWPATH> \
                                -outputerror=<ERROR_FILE> -convert=pcgen5713
  perl tidylst.pl -i=<PATH> -o=<NEWPATH> -e=<ERROR_FILE> -c=pcgen5713

  # display the usage guide lines
  perl tidylst.pl -help
  perl tidylst.pl -h
  perl tidylst.pl -?

  # display the complete documentation
  perl tidylst.pl -man

  # generate and attemp to display a html file for
  # the complete documentation
  perl tidylst.pl -htmlhelp

=head1 PARAMETERS

=head2 B<-inputpath> or B<-i>

The path of a directory which will be scanned for .pcc files. A list of files
to parse will be built from the .pcc files found. Only the known filetypes will
be parsed.

If an B<-inputpath> is given without an B<-outputpath>, the script parses the
lst files and produces warning messages. It does not write any new files.

=head2 B<-basepath> or B<-b>

The path of the base data directory. This is the root of the data "tree", it is
used to replace the @ character in the paths of LST files specified in.PCC
files. If no B<-basepath> option is given, the value of B<-inputpath> is used
to replace the @ character.

=head2 B<-vendorpath> or B<-v>

The path of the vendor data directory. The path to a LST file given in a .pcc
may be prefixed with a * character. A path will be constructed replacing the *
with the vale of this option and a separating /. If this file exists it will be
parsed. If it does not exist, the * is replaced with a @ and the script tries
it to see if it is a file. Thus if no vendor path is supplied, it falls back to
the basepath.

=head2 B<-systempath> or B<-s>

The path of the game mode files used for the .lst files in B<-inputpath>. These
files will be parsed to get a list of valid alignment abbreviations, valid
statistic abbrreviations, valid game modes and globaly defined variables.

If the B<-gamemode> parameter is used, only the system files found in the
proper game mode directory will be parsed.

=head2 B<-outputpath> or B<-o>

This is only used if B<-inputpath> is defined. Any files generated by the
script will be written to a directory tree under B<-outputpath> which mirrors
the tree under B<-inputpath>.

Note: the output directory must be created before calling the script.

=head2 B<-outputerror> or B<-e>

Redirect STDERR to a file. All the warnings and errors produced by this script
are printed to STDERR.

=head2 B<-gamemode> or B<-gm>

Apply a filter on the GAMEMODE values and only read and/or reformat the files that
meet the filter.

e.g. -gamemode=35e

=head2 B<-tablength> or B<-t>

Change the default length of a tab. The default is 8 spaces

e.g. -t=6

=head2 B<-report> or B<-r>

Produce a report on the valid tags found in all the .lst and .pcc files. The report for
invalid tags is always printed.

=head2 B<-nojep>

Disable the new extractVariables function for the formula. This makes the
script use the old style formula parser.

=head2 B<-noxcheck> or B<-nx>

By default, tidylst.pl verifies that values refered to by other tags are valid
entities. It produces a report of any missing or inconsistent values.

These default checks may be disabled using this flag.

=head2 B<-warninglevel> or B<-wl>

Select the level of warnings displayed. Less critical levels include the more
critical ones. ex. B<-wl=info> will produce messages for levels info, notice,
warning and error but will not produce the debug level messages.

The possible levels are:

=over 12

=item B<error>, B<err> or B<3>

Critical errors that need to be checked.  These .lst files are unlikely to work
properly with PCGen.

=item B<warning>, B<warn> or B<4>

Important messages that should be verified. All the conversion messages are
at this level.

=item B<notice> or B<5>

The normal messages including common syntax mistakes and unknown tags.

=item B<informational>, B<info> or B<6> (default)

This level can be very noisy. It includes messages that warn about style, best
practices and about deprecated tags.

=item B<debug> or B<7>

Messages used by the programmer to debug the script.

=back

=head2 B<-exportlist>

Generate files which list entities with a the file and line where they are
located. This is very useful when correcting the problems found by the cross
check.

The files generated are:

=over 12

=item * class.csv

=item * domain.csv

=item * equipment.csv

=item * equipmod.csv

=item * feat.csv

=item * language.csv

=item * pcc.csv

=item * skill.csv

=item * spell.csv

=item * variable.csv

=back

=head2 B<-missingheader> or B<-mh>

List all the requested headers (with the getHeader function) that are not
defined in the %tagheader hash. When a header is not defined, the tag is used
in the generated header lines.

=head2 B<-help>, B<-h> or B<-?>

Print a brief help message and exit.

=head2 B<-man>

Print the manual page and exit. You might want to pipe the output to your
favorite pager (e.g. more).

=head2 B<-htmlhelp>

Generate an .html file and a .css file with the complete documentation.


=head1 MANIFEST

The distribution of this script includes the following files:

=over 8

=item * tidylst.pl

The script itself.

=item * tidylst.pl.html

HMTL version of the perldoc for the script. You can generate this file
by typing C<perl tidylst.pl -htmlhelp>.

=item * tidylst.pl.css

Style sheet files for tidylst.pl.html

=back

=head1 COPYRIGHT

Tidylst and its accociated perl modules are Copyright 2019 Andrew Wilson <mailto:andrew@rivendale.net>

This program is a rewritten version of prettylst.pl. Prettylst was written/maintianed by

Copyright 2002 to 2006 by E<Eacute>ric E<quot>Space MonkeyE<quot> Beaudoin -- <mailto:beaudoer@videotron.ca>

Copyright 2006 to 2010 by Andrew E<quot>Tir GwaithE<quot> McDougall -- <mailto:tir.gwaith@gmail.com>

Copyright 2007 by Richard Bowers

Copyright 2008 Phillip Ryan

All rights reserved.  You can redistribute and/or modify this program under the
same terms as Perl itself.

See L<http://www.perl.com/perl/misc/Artistic.html>.
