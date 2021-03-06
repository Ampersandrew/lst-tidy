package TidyLst::Formatter;

use strict;
use warnings;

use Mouse;

# expand library path so we can find TidyLst modules
use File::Basename qw(dirname);
use Cwd  qw(abs_path);
use lib dirname(dirname abs_path $0);

use TidyLst::Data qw(
   getHeader
   getOrderForLineType
   isFauxTag
   );

use TidyLst::LogFactory qw(getLogger);

has 'columns' => (
   traits   => ['Hash'],
#   is       => 'ro',
   isa      => 'HashRef[Int]',
   default  => sub { {} },
   handles  => {
      column       => 'accessor',
      columns      => 'keys',
      deleteColumn => 'delete',
      hasColumn    => 'exists',
      noTokens     => 'is_empty',
   },
);

has 'order' => (
   traits   => ['Array'],
   isa      => 'ArrayRef[Str]',
   default  => sub { [] },
   handles  => {
      'clear'       => 'clear',
      'add'         => 'push',
      'order'       => 'elements',
      'isUnordered' => 'is_empty',
   },
);

has 'type' => (
   is       => 'rw',
   isa      => 'Str',
   required => 1,
);

has 'tabLength' => (
   is       => 'ro',
   isa      => 'Int',
   required => 1,
);

has 'firstColumnLength' => (
   is       => 'ro',
   isa      => 'Int',
   predicate => 'hasFirstColumnLength',
);



=head2 adjustLengthsForHeaders

   For each column inthis object, it adjusts the value maximum of its current
   value or the length of the header for that column.

=cut

sub adjustLengthsForHeaders {

   my ($self) = @_;

   # Potentially adding columns, clear the order so it will be recalculated
   # next time we format a line or header line.
   $self->clear;

   for my $col ($self->columns) {

      my $len = length getHeader($col, $self->type);

      if($self->column($col) < $len) {
         $self->column($col, $len)
      }
   }
}


=head2 adjustLengths

   Takes a TidyLst::Line and for each column in the Line, it adjusts the value
   of the column in this object to the maximum of this object's current value or
   the $line's column length.

   After this operation has run, columns has an entry for each column that has
   been seen on any line processed using adjustLengths. The value of the column is
   the maximum length of that column in all the lines processed.

=cut

sub adjustLengths {

   my ($self, $line) = @_;

   # Potentially adding columns, clear the order so it will be recalculated
   # next time we format a line or header line.
   $self->clear;

   for my $col ($line->columns) {

      my $len;
      if (isFauxTag($col)) {
         $len = length $line->valueInFirstTokenInColumn($col)
      } else {
         $len = $line->columnLength($col, $self->tabLength);
      }

      if ($self->hasColumn($col)) {
         if($self->column($col) < $len) {
            $self->column($col, $len)
         }
      } else {
         $self->column($col, $len)
      }
   }
}


=head2 constructFirstColumnLine

   Make a text line for the columns in this Line. Each of the columns present
   in this Formatter will be present. The second column is at a costant offset
   from the left hand margin. This first column occupies the space necessary to
   hold its widest value. Other columns are separated by a single tab.

=cut

sub constructFirstColumnLine {
   my ($self, $line) = @_;

   if ($self->isUnordered) {
      $self->orderColumns;
   }

   my $fileLine = "";
   my $toAdd;

   COLUMNS:
   for my $col ($self->order) {

      next COLUMNS unless $self->hasColumn($col);
      
      my $column;

      if (! $fileLine) {

         if (isFauxTag($col)) {
            $column = $line->valueInFirstTokenInColumn($col)
         } else {
            my $token = $line->firstTokenInColumn($col);
            $column   = $token->fullRealToken();
         }

         $column = defined $column ? $column : "";

         my $dataLength = length $column;

         my $toFitIn = 
            $self->hasFirstColumnLength ? 
               $self->firstColumnLength : 
               $self->column($col);

         $toAdd = $self->getPadding($dataLength, $toFitIn);

      } else {

         $toAdd  = 1;
         $column = $line->hasColumn($col) ? $line->joinWith($col, "\t") : "";

      }

      $fileLine .= $column . "\t" x $toAdd;
   }

   # Remove the extra tabs at the end
   $fileLine =~ s/\t+$//;

   $fileLine;
}


=head2 constructHeaderLine

   Make a header line for the columns of this group of lines, with each of the
   columns in this object present in the header and occupying the amount of space
   specified in the column attribute of this object.

=cut

sub constructHeaderLine {
   my ($self) = @_;

   if ($self->isUnordered) {
      $self->orderColumns;
   }
   
   my $headerLine;

   # Do the defined columns first
   for my $col ($self->order) {

      my $header = getHeader($col, $self->type);

      my $dataLength = length $header;

      my $toAdd  = $self->getPadding($dataLength, $self->column($col));

      $headerLine .= $header . "\t" x $toAdd;
   }

   # Remove the extra tabs at the end
   $headerLine =~ s/\t+$//;

   $headerLine;
}


=head2 constructLine

   Make a text line for the columns in this Line. Each of the columns present
   in this Formatter will be present and occupying the amount of space
   specified in the column attribute of this Formatter object.  Space will be
   left for columns not present in this Line.

=cut

sub constructLine {
   my ($self, $line) = @_;

   if ($self->isUnordered) {
      $self->orderColumns;
   }

   my $fileLine;

   ALL_COLUMNS:
   for my $col ($self->order) {

      my $column;
      my $dataLength;

      if (isFauxTag($col)) {
         $column     = $line->valueInFirstTokenInColumn($col);
         $dataLength = length $column;
      } else {
         $column     = $line->joinWith($col, "\t");
         $dataLength = $line->columnLength($col, $self->tabLength);
      }

      if (!defined $column) {
         $column = "";
      }
      
      my $toAdd = $self->getPadding($dataLength, $self->column($col));

      $fileLine .= $column . "\t" x $toAdd;
   }

   # Remove the extra tabs at the end
   $fileLine =~ s/\t+$//;

   $fileLine;
}


=head2 getPadding

   Get the integer number of padding tabs necessary to make the column
   following this one line up.

=cut

sub getPadding  {

   my ($self, $dataLength, $colLength) = @_;

   # If trying to fit this into a column where it doesn't fit
   if ($colLength < $dataLength) {
      $colLength = $dataLength
   }

   my $columnLength = roundUpToLength($colLength, $self->tabLength);

   # Make sure there is a tab between the widest value in this column and
   # the next column (if it happens to be a multiple of tablength).
   if ($columnLength == $colLength) {
      $columnLength += $self->tabLength;
   }

   my $padding = $columnLength - $dataLength;
   my $roundedPadding = roundUpToLength($padding, $self->tabLength);

   return int($roundedPadding / $self->tabLength);
}


=head2 orderColumns

   Gets the defined order for this linetype, sorts the columns in this
   formatter into that order and puts the left over columns in sorted order at the
   end.

=cut

sub orderColumns {
   my ($self) = @_;

   my %columns = map { $_ => 1 } $self->columns;
   my $order   = getOrderForLineType($self->type);
   my $fileLine;

   # Do the defined columns first
   for my $col (@{$order}) {

      # if the column is in this object add it to the order and then delete it
      # from %columns so we can put the left overs at the end
      if ($self->hasColumn($col)) {
         $self->add($col);
         delete $columns{$col};
      }
   }

   for my $col (sort keys %columns) {
      $self->add($col);
   }
}

=head2 roundUpToLength

   Round this length to the smallest multiple of length passed in that can hold it.

=cut

sub roundUpToLength {
   my ($length, $tabLength) = @_;

   int (($length + $tabLength - 1) / $tabLength) * $tabLength;
} 

1;
