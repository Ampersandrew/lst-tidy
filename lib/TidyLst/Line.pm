package TidyLst::Line;

use strict;
use warnings;

use Mouse;
use Carp;

use File::Basename qw(dirname);
use Cwd  qw(abs_path);
use lib dirname(dirname abs_path $0);

use TidyLst::Data qw(getEntityFirstTag isFauxTag);
use TidyLst::Log;
use TidyLst::LogFactory qw(getLogger);
use TidyLst::Token;
use TidyLst::Options qw(getOption);

has 'tagColumns' => (
   traits   => ['Hash'],
   isa      => 'HashRef[ArrayRef[TidyLst::Token]]',
   default  => sub { {} },
   handles  => {
      column       => 'accessor',
      columns      => 'keys',
      deleteColumn => 'delete',
      hasColumn    => 'exists',
      noTokens     => 'is_empty',
      clearTokens  => 'clear',
   },
);

has 'type' => (
   is       => 'rw',
   isa      => 'Str',
   required => 1,
);

has 'file' => (
   is       => 'rw',
   isa      => 'Str',
   required => 1,
);

has 'unsplit' => (
   is       => 'rw',
   isa      => 'Str',
   required => 1,
);

has 'num' => (
   is        => 'rw',
   isa       => 'Int',
   predicate => 'hasNum',
);

has 'mode' => (
   is       => 'rw',
   isa      => 'Int',
   predicate => 'hasMode',
);

has 'format' => (
   is       => 'rw',
   isa      => 'Int',
   predicate => 'hasFormat',
);

has 'header' => (
   is       => 'rw',
   isa      => 'Int',
   predicate => 'hasHeader',
);


=head2 appendToValue

   Append the supplied value to the end of every Token on the given column

=cut

sub appendToValue {

   my ($self, $column, $value) = @_;

   for my $token ( @{ $self->column($column) } ) {
      $token->value($token->value . $value);
   }
}


=head2 addToBonusAndPreReport

   This all the bONUS and standalong PRE tokens in the line to the Bonus and
   pre report.

=cut

sub addToBonusAndPreReport {
   my ($self) = @_;

   COLUMNS:
   for my $column ($self->columns) {
      if ($column !~ qr{^BONUS|^PRE}) {
         next COLUMNS;
         for my $token (@{$self->column($column)}) {
            addToBonusAndPreReport($token, $self->type);
         }
      }
   }
}


=head2 add

   This operation adds a TidyLst::Token object to the line

=cut

sub add {
   my ($self, $token) = @_;

   if (!$self->column($token->tag)) {
      $self->column($token->tag, []) 
   }

   push @{ $self->column($token->tag) }, $token;
}

sub cloneNoTokens {
   my ($self) = @_;

   my $line = TidyLst::Line->new(
      'type'    => $self->type, 
      'file'    => $self->file,
      'unsplit' => '',
      'format'  => $self->format,
      'header'  => $self->header,
      'mode'    => $self->mode,
      'num'     => $self->num,
   );

   $line;
}



=head2 columnHasSingleToken

   Returns true if the given column has a single value.

=cut

sub columnHasSingleToken {

   my ($self, $column) = @_;

   $self->hasColumn($column) && scalar @{$self->column($column)} == 1;
}


=head2 columnLength

   Calculate how long this column would be if its tokens were separated with
   tabs.

=cut

sub columnLength {
   my ($self, $key, $tabLength) = @_;

   my $length = 0;

   if ($self->hasColumn($key)) {

      # Anything with a faux tag only has the legnth of the value of its first column
      if (isFauxTag($key)) {

         my $value = $self->valueInFirstTokenInColumn($key);
         $length = defined $value ? length $value : 0;

      } else {

         my @column = @{ $self->column($key) };
         my $final  = pop @column;

         # All elements except the last must be rounded to the next tab
         for my $token ( @column ) {

            my $tokLength = length $token->fullRealToken;
            my $rndLength = roundUpToLength($tokLength, $tabLength);

            # If the token is already a multiple of the tab lenght, add room
            # for a separator
            if ($tokLength == $rndLength) {
               $tokLength += $tabLength;
            } else {
               $tokLength = $rndLength;
            }

            $length += $tokLength;
         }

         # The final item is not rounded to the tab length
         $length += length $final->fullRealToken;
      }
   }

   $length;
}


=head2 checkClear

   Check that the tags in this column are in the correct order for any CLEAR
   tags that may be present.   

=cut

sub checkClear {

   my ($self, $column) = @_;

   my $log = getLogger();

   my ($clearPat, $valPat);

   if ($column eq "SA") {

      # The SA tag is special because it is only checked
      # up to the first (

      $clearPat =  qr/\.?CLEAR.?([^(]*)/;
      $valPat   =  qr/^([^(]*)/;

   } else {

      $clearPat =  qr/\.?CLEAR.?(.*)/;
      $valPat   =  qr/(.*)/;
   }

   for my $token ( @{$self->column($column)} ) {

      my %value_found;

      if ($token->value =~ $clearPat) {

         # A clear tag either clears the whole thing, in which case it
         # must be at the very beginning, or it clears a particular
         # value, in which case it must be before any such value.
         if ( $1 ne "" ) {

            # Let's check if the value was found before
            if (exists $value_found{$1}) {
               $log->notice(
                  qq{"$column:$1" found before "} 
                  . $token->fullRealValue . q{"},
                  $self->file, 
                  $self->num )
            }

         } else {

            # Let's check if any value was found before
            if (keys %value_found) {
               $log->notice(
                  qq{"$column" tag found before "} 
                  . $token->fullRealValue . q{"}, 
                  $self->file, 
                  $self->num )
            }
         }

      } elsif ($token->value =~ $valPat) {

         # Let's store the value
         $value_found{$1} = 1;

      } else {
         $log->error(
            "Didn't anticipate this tag: " . $token->fullRealValue, 
            $self->file, 
            $self->num);
      }
   }
}



=head2 entityToken

   Return the token that holds the name of this entity

=cut

sub entityToken {
   my ($self) = @_;

   # Look up the name of the column that holds the name
   my $nameTag = getEntityFirstTag($self->type);

   $self->hasColumn($nameTag) && $self->firstTokenInColumn($nameTag)
}


=head2 entityName

   Return the name of this entity

=cut

sub entityName {
   my ($self) = @_;

   my $token = $self->entityToken;

   # There is only a faux tag on this token, so just return the value as that
   # is the name.
   defined $token && ref $token eq 'TidyLst::Token' && $token->value;
}


=head2 extractPreLine

   Extract all the Deity and standalone PRE tags from a line and create a new
   line from them

=cut

sub extractPreLine {

   my ($self) = @_;

   my $line = $self->cloneNoTokens;

   my $token = $self->entityToken;

   $line->add($token);

   COLUMNS:
   for my $column ($self->columns) {

      if ($column !~ /^\!?PRE/ &&  $column !~ /^DEITY/) {
         next COLUMNS;
      }

      for my $token (@{$self->column($column)}) {
         $line->add($token);
      }

      $self->deleteColumn($column);
   }

   $line;
}


=head2 extractSkillLine

   Extract all the skill related tags from a line and create a new line from them

=cut

sub extractSkillLine {

   my ($self) = @_;

   my $line = $self->cloneNoTokens;

   my $token = $self->entityToken;

   $line->add($token);

   for my $column (qw(
      CSKILL:.CLEAR     CCSKILL
      CSKILL            MODTOSKILLS
      MONSKILL          MONNONSKILLHD
      SKILLLIST         STARTSKILLPTS
      )) {

      if ($self->hasColumn($column)) {
         for my $token (@{$self->column($column)}) {
            $line->add($token);
         }
         $self->deleteColumn($column);
      }
   }
   $line;
}


=head2 extractSpellLine

   Extract all the spell related tags from a line and create a new line from
   them

=cut

sub extractSpellLine {

   my ($self) = @_;

   my $line = $self->cloneNoTokens;
   $line->add($self->entityToken);

   for my $column ( qw(
      BONUS:CASTERLEVEL    BONUS:DC
      BONUS:SCHOOL         BONUS:SPECIALTYSPELLKNOWN
      BONUS:SPELL          BONUS:SPELLCAST
      BONUS:SPELLCASTMULT  BONUS:SPELLKNOWN
      BONUSSPELLSTAT       CASTAS
      HASSPELLFORMULA      ITEMCREATE
      KNOWNSPELLS          KNOWNSPELLSFROMSPECIALTY
      MEMORIZE             PROHIBITED
      SPELLBOOK            SPELLKNOWN
      SPELLLEVEL           SPELLLIST
      SPELLSTAT            SPELLTYPE
      )) {

      if ($self->hasColumn($column)) {
         for my $token (@{$self->column($column)}) {
            $line->add($token);
         }
         $self->deleteColumn($column);
      }
   }
   $line;
}


=head2 firstColumnMatches

   Returns true if this line has the given token and the full token matches the
   given pattern.

=cut

sub firstColumnMatches {

   my ($self, $column, $pattern) = @_;

   if ($self->hasColumn($column)) {
      my @column = @{$self->column($column)};
      my $token  = $column[0];
      return $token->fullToken =~ $pattern;
   }

   return 0;   
}


=head2 firstTokenInColumn

   Get the token which is first in the column, returns undef if the column is
   not present in the line.

=cut

sub firstTokenInColumn {

   my ($self, $column) = @_;

   if ($self->hasColumn($column)) {
      my @column = @{$self->column($column)};
      return $column[0];
   }

   return undef;   
}


=head2 valueInFirstTokenInColumn

   Get the value of the token which is first in the column, returns undef if
   the column is not present in the line.

=cut

sub valueInFirstTokenInColumn {

   my ($self, $column) = @_;

   if ($self->hasColumn($column)) {
      my $token = $self->firstTokenInColumn($column);
      return $token->value
   }

   return undef;   
}


=head2 hasType

   This operation checks whether the line has the given type in its tokens.

=cut


sub hasType {
   my ($self, $type) = @_;

   if ($self->hasColumn('TYPE')) {
      my @types = @{ $self->column('TYPE') };
      for my $token (@types) {
         return 1 if $token->value =~ $type;
      }
   }
   return 0;
}


=head2 isType

   This opertaion checks whether the line has the given lineType.

=cut

sub isType {
   my ($self, $lineType) = @_;

   $self->type eq $lineType;
}


=head2 joinWith

   Join the entries in the supplied colum together with the supplied seaparator
   and return the result.

=cut

sub joinWith {
   my ($self, $key, $sep) = @_;

   return "" unless $self->hasColumn($key);

   my @column = @{ $self->column($key) };

   my $final = pop @column;

   my $text;
   for my $token ( @column ) {
      $text .= $token->fullRealToken . $sep;
   }

   $text .= $final->fullRealToken;
}


=head2 levelForWizardOrCleric

   For spell lines, get the level of the spell for Wizards or Clerics. If this
   is not a spell line or not a Wizard or Cleric spell, return -1;

=cut

sub levelForWizardOrCleric {

   my ($self) = @_;

   if ($self->isType('SPELL') && $self->hasColumn('CLASSES')) {

      for my $token (@{$self->column('CLASSES')}) {
         for my $class (split '\|', $token->value) {
            if ($class =~ qr{(Wizard|Cleric)=(\d+)$}) {
               return $2;
            }
         }
      }

      return -1
   }
}


=head2 mergeLines

   Merge the tokens of the other line (oLine) into this line.

=cut

sub mergeLines {

   my ($self, $oLine) = @_;

   my $entTok = $self->entityToken;

   for my $column (grep {$_ ne $entTok->tag} $oLine->columns) {
      for my $token (@{$oLine->column($column)}) {
         $self->add($token);
      }
   }
}

=head2 roundUpToLength

   Round this length to the smallest multiple of length passed in that can hold it.

=cut

sub roundUpToLength {
   my ($length, $tabLength) = @_;

   int (($length + $tabLength - 1) / $tabLength) * $tabLength;
} 


=head2 replaceTag

   When called with two arguments, this replaces the tag in every token in the
   column with the new tag. This creates a new column, it then deletes the
   old column.

   If only given one argument, it deletes the tokens in that column

   both versions give a report of the tokens removed from the line.

=cut

sub replaceTag {

   my ($self, $oldTag, $newTag) = @_;
   my $log = getLogger();

   for my $token ( @{ $self->column($oldTag) } ) {

      $log->warning(
         qq{Removing "} . $token->fullToken . q{".},
         $self->file,
         $self->num
      );

      if (defined $newTag) {
         $token->tag($newTag);
         $self->add($token);

         $log->warning(
            qq{Replaced with "} . $token->fullToken . q{".},
            $self->file,
            $self->num
         );
      }
   }

   $self->deleteColumn($oldTag);
}

=head2 tokenFor

   Create a new token that has the correct linetype, line number and file name
   to be on this line.

=cut

sub tokenFor {
   my ($self, @args) = @_;

   my $token = $self->entityToken;

   defined $token && $token->clone(@args);
}


##############################################################################

=head2 _splitToken

   Split a token which has been separated by | into separate tokens.
   Mostly used to split the old style SOURCE tokens.

=cut

sub _splitToken {

   my ($self, $column) = @_;
   my $log = getLogger();

   my @newTokens;

   for my $token (@{ $self->column($column) }) {
      if( $token->value =~ / [|] /xms ) {
         for my $tag (split '\|', $token->fullToken) {
            push @newTokens, $token->clone(fullToken => $tag);
         }

         $log->warning(
            qq{Spliting "} . $token->fullToken . q{"},
            $self->file,
            $self->num
         );

      } else {
         push @newTokens, $token;
      }
   }

   # delete the existing column and add back the tokens, if the tokens were
   # no split, this should end up where we started.
   $self->deleteColumn($column);

   for my $token (@newTokens) {
      $self->add($token);
   }
}


__PACKAGE__->meta->make_immutable;

1;
