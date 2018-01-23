
use warnings;
use strict;

package Log::Report::Extract::Template;
use base 'Log::Report::Extract';

use Log::Report 'log-report-lexicon';

=chapter NAME
Log::Report::Extract::Template - collect translatable strings from template files

=chapter SYNOPSIS

 # First use of this module: extract msgids from various kinds
 # of text-files, usually web templates.
 # See script "xgettext-perl" for standard wrapper script

 my $extr = Log::Report::Extract::Template->new
   ( lexicon => '/usr/share/locale'
   , domain  => 'my-web-site'
   , pattern => 'TT2-loc'
   );
 $extr->process('website/page.html');  # many times
 $extr->showStats;
 $extr->write;

 # Second use: connect to Template::Toolkit
 # See DETAILS chapter below

 [% loc("Greetings {name},", name => client.name) %]
 [% | loc(name => client.name) %]Greetings {name}[% END %]
 [% 'Greetings {name}' | loc(name => client.name) %]


=chapter DESCRIPTION
This module helps maintaining the POT files which list translatable
strings from template files (or other flat text files) by updating the
list of message-ids which are kept in them.

After initiation, the M<process()> method needs to be called for each file
in the domain  and the existing PO files will get updated accordingly.

If no translations exist yet, one C<$textdomain.po> file will be
created as point to start.  Copy that file into C<$textdomain/$lang.po>

=chapter METHODS

=section Constructors

=c_method new OPTIONS

=requires domain DOMAIN
There is no syntax for specifying domains in templates (yet), so you
must be explicit about the collection we are making now.

=option  pattern PREDEFINED|CODE
=default pattern <undef>
See the DETAILS section below for a detailed explenation.
=cut

sub init($)
{   my ($self, $args) = @_;
    $self->SUPER::init($args);
    $self->{LRET_domain}  = $args->{domain}
        or error "template extract requires explicit domain";

    $self->{LRET_pattern} = $args->{pattern};
    $self;
}

=section Accessors
=method domain
=method pattern
=cut

sub domain()  {shift->{LRET_domain}}
sub pattern() {shift->{LRET_pattern}}

=section Processors

=method process FILENAME, OPTIONS
Update the domains mentioned in the FILENAME.  All textdomains defined
in the file will get updated automatically, but not written before
all files where processed.

=option  charset STRING
=default charset 'utf-8'
The character encoding used in this template file.

=option  pattern PREDEFINED|CODE
=default pattern <from new(pattern)>
Read the DETAILS section about this.
=cut

sub process($@)
{   my ($self, $fn, %opts) = @_;

    my $charset = $opts{charset} || 'utf-8';
    info __x"processing file {fn} in {charset}", fn=> $fn, charset => $charset;

    my $pattern = $opts{pattern} || $self->pattern
        or error __"need pattern to scan for, either via new() or process()";

    # Slurp the whole file
    local *IN;
    open IN, "<:encoding($charset)", $fn
        or fault __x"cannot read template from {fn}", fn => $fn;

    undef $/;
    my $text = <IN>;
    close IN;

    my $domain  = $self->domain;
    $self->_reset($domain, $fn);

    if(ref $pattern eq 'CODE')
    {   return $pattern->($fn, \$text);
    }
    elsif($pattern =~ m/^TT([12])-(\w+)$/)
    {   return $self->scanTemplateToolkit($1, $2, $fn, \$text);
    }
    else
    {   error __x"unknown pattern {pattern}", pattern => $pattern;
    }
    ();
}

sub scanTemplateToolkit($$$$)
{   my ($self, $version, $function, $fn, $textref) = @_;

    # Split the whole file on the pattern in four fragments per match:
    #       (text, leading, needed trailing, text, leading, ...)
    # f.i.  ('', '[% loc("', 'some-msgid', '", params) %]', ' more text')
    my @frags
      = $version==1 ? split(/[\[%]%(.*?)%[%\]]/s, $$textref)
      :               split(/\[%(.*?)%\]/s, $$textref);

    my $domain     = $self->domain;
    my $linenr     = 1;
    my $msgs_found = 0;

    # pre-compile the regexes, for performance
    my $pipe_func_block  = qr/^\s*\|\s*$function\b/;
    my $msgid_pipe_func  = qr/^\s*(["'])([^\r\n]+?)\1\s*\|\s*$function\b/;
    my $func_msgid_multi = qr/(\b$function\s*\(\s*)(["'])([^\r\n]+?)\2/s;

    while(@frags > 2)
    {   my ($skip_text, $take) = (shift @frags, shift @frags);
        $linenr += $skip_text =~ tr/\n//;
        if($take =~ $pipe_func_block)
        {   # [%|loc(...)%]$msgid[%END%]
            if(@frags < 2 || $frags[1] ne 'END')
            {   error __x"template syntax error, no END in {fn} line {line}"
                  , fn => $fn, line => $linenr;
            }
            my $msgid  = $frags[0];  # next content
            my $plural = $msgid =~ s/\|(.*)// ? $1 : undef;
            $self->store($domain, $fn, $linenr, $msgid, $plural);
            $msgs_found++;

            $linenr   += $take =~ tr/\n//;
            next;
        }

        if($take =~ $msgid_pipe_func)
        {   # [%|loc(...)%]$msgid[%END%]
            my $msgid  = $2;
            my $plural = $msgid =~ s/\|(.*)// ? $1 : undef;
            $self->store($domain, $fn, $linenr, $msgid, $plural);
            $msgs_found++;

            $linenr   += $take =~ tr/\n//;
            next;
        }

        # loc($msgid, ...) form, can appear more than once
        my @markup = split $func_msgid_multi, $take;
        while(@markup > 4)
        {   # quads with text, call, quote, msgid
            $linenr   += ($markup[0] =~ tr/\n//)
                      +  ($markup[1] =~ tr/\n//);
            my $msgid  = $markup[3];
            my $plural = $msgid =~ s/\|(.*)// ? $1 : undef;
            $self->store($domain, $fn, $linenr, $msgid, $plural);
            $msgs_found++;
            splice @markup, 0, 4;
        }
        $linenr += $markup[-1] =~ tr/\n//; # rest of container
    }
#   $linenr += $frags[-1] =~ tr/\n//; # final page fragment not needed

    $msgs_found;
}

#----------------------------------------------------
=chapter DETAILS

=section Scan Patterns

Various template systems use different conventions for denoting strings
to be translated.

=subsection Predefined for Template-Toolkit

There is not a single convertion for translations in C<Template-Toolkit>
(see M<Template>), so you need to specify which version you use and
which function you want to run.

For instance

   pattern => 'TT2-loc'

will scan for

   [% loc("msgid", key => value, ...) %]
   [% loc('msgid', key => value, ...) %]
   [% loc("msgid|plural", count, key => value, ...) %]

   [% INCLUDE
        title = loc('something')
    %]

   [% | loc(n => name) %]hi {n}[% END %]
   [% 'hi {n}' | loc(n => name) %]

For TT1, the brackets can either be '[%...%]' or '%%...%%'.  The function
name is treated case-sensitive.  Some people prefer 'l()'.

The code needed

   ... during initiation of the webserver
   my $lexicons   = 'some-directory-for-translation-tables';
   my $translator = Log::Report::Translator::POT->new(lexicons => $lexicons);
   Log::Report->translator($textdomain => $translator);

   ... your standard template driver
   sub handler {
      ...
      my $vars      = { ...all kinds of values... };
      $vars ->{loc} = \&translate;           # <--- this is extra

      my $output    = '';
      my $templater = Template->new(...);
      $templater->process($template_fn, $vars, \$output);
      print $output;
   }

   ... anywhere in the same file
   sub translate {
       my $textdomain = ...;   # your choice when running xgettext-perl
       my $lang       = ...;   # how do you figure that out?
       my $msg = Log::Report::Message->fromTemplateToolkit($textdomain, @_);
       $msg->toString($lang);
   }

To generate the pod tables, run in the shell something like

   xgettext-perl -p $lexicons --template TT2-loc \
      --domain $textdomain  $templates_dir

If you want to implement your own extractor --to avoid C<xgettext-perl>--
you need to run something like this:

  my $extr = Log::Report::Extract::Template->new
    ( lexicon => $output
    , charset => 'utf-8'
    , domain  => $domain
    , pattern => 'TT2-loc'
    );
  $extr->process($_) for @filenames;
  $extr->write;

=cut

1;
