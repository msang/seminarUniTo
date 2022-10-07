# Common Perl functions to manipulate UD repositories.
# Copyright © 2016 Dan Zeman <zeman@ufal.mff.cuni.cz>
# License: GNU GPL

package udlib;

use Carp;
use JSON::Parse 'json_file_to_perl';
use YAML qw(LoadFile);
use Cwd; # remember path to the current folder getcwd()
use utf8;



#------------------------------------------------------------------------------
# Reads the YAML file with information about languages from the repository
# docs-automation. Returns a reference to a hash indexed by the English names
# of the languages, with sub-fields 'flag', 'lcode', 'family'.
#------------------------------------------------------------------------------
sub get_language_hash
{
    my $path = shift;
    $path = 'docs-automation/codes_and_flags.yaml' if(!defined($path));
    return LoadFile($path);
}



#------------------------------------------------------------------------------
# Takes a name of a UD treebank repository, e.g., UD_Ancient_Greek-PROIEL.
# Decomposes it into language name and treebank name and returns the two
# strings. If language name contains underscores, they are replaced by spaces
# (it looks better in reports and it is also the required name form to access
# language information read from YAML by get_language_hash()).
#------------------------------------------------------------------------------
sub decompose_repo_name
{
    my $repo = shift;
    $repo =~ s:/$::;
    my $language;
    my $treebank;
    # Example: UD_Ancient_Greek-PROIEL
    if($repo =~ m/^UD_([A-Za-z_]+)(?:-([A-Za-z]+))?$/)
    {
        $language = $1;
        $treebank = $2;
        $language =~ s/_/ /g;
    }
    return ($language, $treebank);
}



#------------------------------------------------------------------------------
# Takes a name of a UD treebank repository, e.g., UD_Ancient_Greek-PROIEL.
# Returns the corresponding lowercase ltcode, which is expected as the prefix
# of the CoNLL-U data files within the treebank (e.g., grc_proiel). Can use
# already loaded language hash, otherwise tries to load it. Throws an exception
# if the repo name has wrong form or unknown language.
#------------------------------------------------------------------------------
sub get_ltcode_from_repo_name
{
    my $repo = shift;
    my $languages_from_yaml = shift;
    if(!defined($languages_from_yaml))
    {
        $languages_from_yaml = get_language_hash();
    }
    my ($language, $treebank) = udlib::decompose_repo_name($repo);
    if(defined($language))
    {
        if(exists($languages_from_yaml->{$language}))
        {
            my $langcode = $languages_from_yaml->{$language}{lcode};
            my $ltcode = $langcode;
            $ltcode .= '_'.lc($treebank) unless($treebank eq '');
            return $ltcode;
        }
        else
        {
            confess("Unknown language '$language'");
        }
    }
    else
    {
        confess("Cannot parse repo name '$repo'");
    }
}



#------------------------------------------------------------------------------
# Returns list of UD_* folders in a given folder. Default: the current folder.
#------------------------------------------------------------------------------
sub list_ud_folders
{
    my $path = shift;
    $path = '.' if(!defined($path));
    opendir(DIR, $path) or die("Cannot read the contents of '$path': $!");
    my @folders = sort(grep {-d "$path/$_" && m/^UD_.+/} (readdir(DIR)));
    closedir(DIR);
    return @folders;
}



#------------------------------------------------------------------------------
# Scans a UD folder for CoNLL-U files. Uses the file names to guess the
# language code.
#------------------------------------------------------------------------------
sub get_ud_files_and_codes
{
    my $udfolder = shift; # e.g. "UD_Czech"; not the full path
    my $path = shift; # path to the superordinate folder; default: the current folder
    $path = '.' if(!defined($path));
    my $name;
    my $langname;
    my $tbkext;
    if($udfolder =~ m/^UD_(([^-]+)(?:-(.+))?)$/)
    {
        $name = $1;
        $langname = $2;
        $tbkext = $3;
        $langname =~ s/_/ /g;
    }
    else
    {
        print STDERR ("WARNING: Unexpected folder name '$udfolder'\n");
    }
    # Look for training, development or test data.
    my $section = 'any'; # training|development|test|any
    my %section_re =
    (
        # Training data in big treebanks is split into multiple files.
        'training'    => 'train(-[a-z])?(-[0-9])?',
        'development' => 'dev',
        'test'        => 'test',
        'any'         => '(train(-[a-z])?(-[0-9])?|dev|test)'
    );
    opendir(DIR, "$path/$udfolder") or die("Cannot read the contents of '$path/$udfolder': $!");
    my @files = sort(grep {-f "$path/$udfolder/$_" && m/.+-ud-$section_re{$section}\.conllu$/} (readdir(DIR)));
    closedir(DIR);
    my $n = scalar(@files);
    my $code;
    my $lcode;
    my $tcode;
    if($n>0)
    {
        if($n>1 && $section ne 'any')
        {
            print STDERR ("WARNING: Folder '$path/$udfolder' contains multiple ($n) files that look like $section data.\n");
        }
        $files[0] =~ m/^(.+)-ud-$section_re{$section}\.conllu$/;
        $lcode = $code = $1;
        if($code =~ m/^([^_]+)_(.+)$/)
        {
            $lcode = $1;
            $tcode = $2;
        }
    }
    my %record =
    (
        'folder' => $udfolder,
        'name'   => $name,
        'lname'  => $langname,
        'tname'  => $tbkext,
        'code'   => $code,
        'ltcode' => $code, # for compatibility with some tools, this code is provided both as 'code' and as 'ltcode'
        'lcode'  => $lcode,
        'tcode'  => $tcode,
        'files'  => \@files,
        $section => $files[0]
    );
    #print STDERR ("$udfolder\tlname $langname\ttname $tbkext\tcode $code\tlcode $lcode\ttcode $tcode\t$section $files[0]\n");
    return \%record;
}



#------------------------------------------------------------------------------
# Reads the README file of a treebank and finds the metadata lines. Example:
#=== Machine-readable metadata (DO NOT REMOVE!) ================================
#Data available since: UD v1.0
#License: CC BY-NC-SA 3.0
#Includes text: yes
#Genre: news
#Lemmas: converted from manual
#UPOS: converted from manual
#XPOS: manual native
#Features: converted from manual
#Relations: converted from manual
#Contributors: Zeman, Daniel; Hajič, Jan
#Contributing: elsewhere
#Contact: zeman@ufal.mff.cuni.cz
#===============================================================================
#------------------------------------------------------------------------------
sub read_readme
{
    my $folder = shift;
    my $path = shift; # path to the superordinate folder; default: the current folder
    $path = '.' if(!defined($path));
    my $filename = (-f "$path/$folder/README.txt") ? "$path/$folder/README.txt" : "$path/$folder/README.md";
    open(README, $filename) or return undef;
    binmode(README, ':utf8');
    my %metadata;
    my @attributes = ('Data available since', 'License', 'Genre', 'Contributors',
        'Includes text', 'Lemmas', 'UPOS', 'XPOS', 'Features', 'Relations', 'Contributing', 'Contact');
    my $attributes_re = join('|', @attributes);
    my $current_section_heading = '';
    my $current_section_text = '';
    while(<README>)
    {
        # Remove leading and trailing whitespace characters.
        s/\r?\n$//;
        s/^\s+//;
        s/\s+$//;
        s/\s+/ /g;
        # Is this a top-level section heading?
        # Note: We regard the machine-readable metadata as a section of its own; it does not have a proper heading but starts with "===".
        if(m/^\#([^\#]+|$)/ || m/^===\s*(.*?)\s*=+/)
        {
            my $heading = lc($1);
            $heading =~ s/^\s+//;
            $heading =~ s/\s+$//;
            # Collapse "acknowledgments" and "acknowledgements", both are correct.
            $heading =~ s/acknowledge?ments?/acknowledgments/;
            # Save the previous section before starting a new one.
            if($current_section_heading ne '' && $current_section_text ne '')
            {
                # Metadata may be enclosed in <pre>...</pre> in order to improve the rendering on Github.
                # However, that could mean that <pre> is now the last line of the last section.
                # If we keep it there and copy it to a web page, it will ruin all subsequent formatting.
                $current_section_text =~ s/\s*<pre>\s*$/\n/is;
                $metadata{sections}{$current_section_heading} = $current_section_text;
            }
            # Clear the buffer for the next section.
            $current_section_heading = $heading;
            $current_section_text = '';
        }
        # We do not include the heading line in the text of the section, but we do include everything else, including empty lines.
        else
        {
            $current_section_text .= "$_\n";
        }
        if(m/^($attributes_re):\s*(.*)$/i)
        {
            my $attribute = $1;
            my $value = $2;
            $value = '' if(!defined($value));
            if(exists($metadata{$attribute}))
            {
                print(`pwd`) if($folder !~ m/^UD_/);
                print("WARNING: Repeated definition of '$attribute' in $folder/$filename\n");
            }
            $metadata{$attribute} = $value;
            # Make it easier to check the number of the first release (we need to know whether this dataset is planned for future and shall be excluded now).
            if($attribute eq 'Data available since')
            {
                if($metadata{$attribute} =~ m/^UD\s*v?(\d+\.\d+)$/i)
                {
                    $metadata{'firstrelease'} = $1;
                }
            }
        }
        elsif(m/change\s*log/i)
        {
            $metadata{'changelog'} = 1;
        }
    }
    # The last section should be the metadata, which we do not need saved as section.
    # But if the README does not follow the guidelines, a previous section may not
    # be terminated properly and we have to save it now.
    if($current_section_heading ne '' && $current_section_text ne '')
    {
        # Metadata may be enclosed in <pre>...</pre> in order to improve the rendering on Github.
        # However, that could mean that <pre> is now the last line of the last section.
        # If we keep it there and copy it to a web page, it will ruin all subsequent formatting.
        $current_section_text =~ s/\s*<pre>\s*$/\n/is;
        $metadata{sections}{$current_section_heading} = $current_section_text;
    }
    close(README);
    # Most README files in UD are MarkDown sources rather than plain text, and
    # the text of the sections we extracted may contain MarkDown syntax such as
    # italics and hypertext links. Provide a plain text version of the summary
    # for those who want to copy it to non-MarkDown environments.
    if(defined($metadata{sections}{summary}))
    {
        $metadata{sections}{summary_plaintext} = $metadata{sections}{summary};
        # Gradually identify and remove selected kinds of MarkDown syntax.
        my $hit;
        do
        {
            $hit = 0;
            $hit = 1 if($metadata{sections}{summary_plaintext} =~ s/\*\*\*([^*]+)\*\*\*/$1/s); # bold italic
            $hit = 1 if($metadata{sections}{summary_plaintext} =~ s/___([^_]+)___/$1/s); # bold
            $hit = 1 if($metadata{sections}{summary_plaintext} =~ s/\*\*([^*]+)\*\*/$1/s); # bold
            $hit = 1 if($metadata{sections}{summary_plaintext} =~ s/__([^_]+)__/$1/s); # bold
            $hit = 1 if($metadata{sections}{summary_plaintext} =~ s/\*([^*]+)\*/$1/s); # italic
            $hit = 1 if($metadata{sections}{summary_plaintext} =~ s/_([^_]+)_/$1/s); # italic
            $hit = 1 if($metadata{sections}{summary_plaintext} =~ s/\`([^`]+)\`/$1/s); # code `
            $hit = 1 if($metadata{sections}{summary_plaintext} =~ s/!\[.*?\]\(.*?\)//s); # image
            $hit = 1 if($metadata{sections}{summary_plaintext} =~ s/\[(.*?)\]\(.*?\)/$1/s); # link
        }
        while($hit);
    }
    return \%metadata;
}



#------------------------------------------------------------------------------
# Generates a human-readable information about a treebank, based on README and
# data, intended for the UD web (i.e. using MarkDown syntax).
#------------------------------------------------------------------------------
sub generate_markdown_treebank_overview
{
    my $folder = shift;
    # We need to know the number of the latest release in order to generate the links to search engines.
    my $release = shift;
    if($release !~ m/^\d+\.\d+$/)
    {
        # Let's be mean and throw an exception. We do not want to generate docs
        # pages with wrong or empty release numbers in links.
        confess("Unrecognized UD release number '$release'.");
    }
    my $crelease = $release;
    $crelease =~ s/\.//;
    my $treebank_name = $folder;
    $treebank_name =~ s/[-_]/ /g;
    my $language_name = $folder;
    $language_name =~ s/^UD_//;
    $language_name =~ s/-.*//;
    $language_name =~ s/_/ /g;
    my $filescan = get_ud_files_and_codes($folder);
    my $metadata = read_readme($folder);
    my $md = "\# $treebank_name\n\n";
    if(!defined($metadata))
    {
        $md .= "<b>ERROR:</b> Cannot read the README file: $!";
        return $md;
    }
    # Language-specific documentation, e.g. for Polish: http://universaldependencies.org/pl/index.html
    $md .= "Language: [$language_name](/$filescan->{lcode}/index.html) (code: `$filescan->{lcode}`)";
    my $language_data = get_language_hash(); # we could supply path to the yaml file; but let the function try the default path now
    if(defined($language_data) && exists($language_data->{$language_name}{family}))
    {
        my $family = $language_data->{$language_name}{family};
        $family =~ s/^IE,/Indo-European,/;
        $md .= "<br/>\nFamily: $family";
    }
    $md .= "\n\n";
    $md .= "This treebank has been part of Universal Dependencies since the $metadata->{'Data available since'} release.\n\n";
    $md .= "The following people have contributed to making this treebank part of UD: ";
    $md .= join(', ', map {my $x = $_; if($x =~ m/^(.+),\s*(.+)$/) {$x = "$2 $1"} $x} (split(/\s*;\s*/, $metadata->{Contributors})));
    $md .= ".\n\n";
    $md .= "Repository: [$folder](https://github.com/UniversalDependencies/$folder)<br />\n";
    $md .= "Search this treebank on-line: [PML-TQ](https://lindat.mff.cuni.cz/services/pmltq/\#!/treebank/ud$filescan->{code}$crelease)<br />\n";
    $md .= "Download all treebanks: [UD $release](/#download)\n\n";
    $md .= "License: $metadata->{License}";
    $md .= ". The underlying text is not included; the user must obtain it separately and then merge with the UD annotation using a script distributed with UD" if($metadata->{'Includes text'} eq 'no');
    $md .= "\n\n";
    $md .= "Genre: ";
    $md .= join(', ', split(/\s+/, $metadata->{Genre}));
    $md .= "\n\n";
    my $scrambled_email = $metadata->{Contact};
    $scrambled_email =~ s/\@/&nbsp;(æt)&nbsp;/g;
    $scrambled_email =~ s/\./&nbsp;•&nbsp;/g;
    $md .= "Questions, comments?\n";
    $md .= "General annotation questions (either $language_name-specific or cross-linguistic) can be raised in the [main UD issue tracker](https://github.com/UniversalDependencies/docs/issues).\n";
    $md .= "You can report bugs in this treebank in the [treebank-specific issue tracker on Github](https://github.com/UniversalDependencies/$folder/issues).\n";
    $md .= "If you want to collaborate, please contact [$scrambled_email].\n";
    if($metadata->{Contributing} eq 'here')
    {
        $md .= "Development of the treebank happens directly in the UD repository, so you may submit bug fixes as pull requests against the dev branch.\n";
    }
    elsif($metadata->{Contributing} eq 'here source')
    {
        $md .= "Development of the treebank happens in the UD repository but not directly in the final CoNLL-U files.\n";
        $md .= "You may submit bug fixes as pull requests against the dev branch but you have to go to the folder called `not-to-release` and locate the source files there.\n";
        $md .= "Contact the treebank maintainers if in doubt.\n";
    }
    elsif($metadata->{Contributing} eq 'elsewhere')
    {
        $md .= "Development of the treebank happens outside the UD repository.\n";
        $md .= "If there are bugs, either the original data source or the conversion procedure must be fixed.\n";
        $md .= "Do not submit pull requests against the UD repository.\n";
    }
    elsif($metadata->{Contributing} eq 'to be adopted')
    {
        $md .= "The UD version of this treebank currently does not have a maintainer.\n";
        $md .= "If you know the language and want to help, please consider adopting the treebank.\n";
    }
    $md .= "\n";
    $md .= "| Annotation | Source |\n";
    $md .= "|------------|--------|\n";
    foreach my $annotation (qw(Lemmas UPOS XPOS Features Relations))
    {
        $md .= "| $annotation | ";
        if($metadata->{$annotation} eq 'manual native')
        {
            $md .= "annotated manually";
            # It probably does not make sense to speak about "UD style" lemmatization.
            # And it would be definitely wrong with XPOS.
            unless($annotation =~ m/^(Lemmas|XPOS)$/)
            {
                $md .= ", natively in UD style";
            }
            $md .= " |\n";
        }
        elsif($metadata->{$annotation} eq 'converted from manual')
        {
            $md .= "annotated manually in non-UD style, automatically converted to UD |\n";
        }
        elsif($metadata->{$annotation} eq 'converted with corrections')
        {
            $md .= "annotated manually in non-UD style, automatically converted to UD, with some manual corrections of the conversion |\n";
        }
        elsif($metadata->{$annotation} eq 'automatic')
        {
            $md .= "assigned by a program, not checked manually |\n";
        }
        elsif($metadata->{$annotation} eq 'automatic with corrections')
        {
            $md .= "assigned by a program, with some manual corrections, but not a full manual verification |\n";
        }
        elsif($metadata->{$annotation} eq 'not available')
        {
            $md .= "not available |\n";
        }
        elsif($metadata->{$annotation} =~ m/\w/)
        {
            $md .= "(unrecognized value: \"$metadata->{$annotation}\") |\n";
        }
        else
        {
            $md .= "(undocumented) |\n";
        }
    }
    $md .= "\n";
    $md .= "\#\# Description\n".escape_jekyll($metadata->{sections}{summary});
    $md .= "\n".$metadata->{sections}{introduction};
    $md .= "\#\# Acknowledgments\n".escape_jekyll($metadata->{sections}{acknowledgments});
    return $md;
}



#------------------------------------------------------------------------------
# Reads a (MarkDown) text and makes it processable by Jekyll, i.e., escapes all
# character sequences that Jekyll could mistake for instructions. Specifically,
# double curly braces in BibTeX are dangerous.
#------------------------------------------------------------------------------
sub escape_jekyll
{
    my $text = shift;
    # Wrap every occurrence of '{{' or '}}' in the Jekyll escape block {% raw %} ... {% endraw %}.
    $text =~ s/(\{\{|\}\})/\{\% raw \%\}$1\{\% endraw \%\}/g;
    return $text;
}



#------------------------------------------------------------------------------
# Reads a CoNLL-U file and collects statistics about features.
#------------------------------------------------------------------------------
sub collect_features_from_conllu_file
{
    my $file = shift; # relative or full path
    my $hash = shift; # ref to hash where the statistics are collected
    my $key = shift; # identification of the current dataset in the hash (e.g. language code)
    open(FILE, $file) or die("Cannot read $file: $!");
    while(<FILE>)
    {
        if(m/^\d+\t/)
        {
            chomp();
            my @fields = split(/\t/, $_);
            my $features = $fields[5];
            unless($features eq '_')
            {
                my @features = split(/\|/, $features);
                foreach my $feature (@features)
                {
                    my ($f, $vv) = split(/=/, $feature);
                    # There may be several values delimited by commas.
                    my @values = split(/,/, $vv);
                    foreach my $v (@values)
                    {
                        $hash->{$f}{$v}{$key}++;
                        $hash->{$f}{$v}{TOTAL}++;
                    }
                }
            }
        }
    }
    return $hash;
}



#------------------------------------------------------------------------------
# Reads all CoNLL-U files in a folder and collects statistics about features.
#------------------------------------------------------------------------------
sub collect_features_from_ud_folder
{
    my $udfolder = shift; # relative or full path
    my $hash = shift; # ref to hash where the statistics are collected
    my $key = shift; # identification of the current dataset in the hash (e.g. language code)
    opendir(DIR, $udfolder) or die("Cannot read the contents of '$udfolder': $!");
    my @files = sort(grep {-f "$udfolder/$_" && m/.+\.conllu$/} (readdir(DIR)));
    closedir(DIR);
    foreach my $file (@files)
    {
        collect_features_from_conllu_file("$udfolder/$file", $hash, $key);
    }
}



#------------------------------------------------------------------------------
# Finds all UD subfolders in the current folder, scans them for CoNLL-U files,
# reads these files and collects statistics about feature values in them.
#------------------------------------------------------------------------------
sub scan
{
    my @folders = list_ud_folders();
    my %hash;
    foreach my $folder (@folders)
    {
        my $record = get_ud_files_and_codes($folder);
        # Skip folders without data.
        next if(!defined($record->{lcode}));
        collect_features_from_ud_folder($folder, \%hash, $record->{lcode});
    }
    ###!!! Temporary debugging. List languages that use VerbForm=Ger.
    my %gerhash = %{$hash{VerbForm}{Ger}};
    my @keys = sort(grep {$gerhash{$_}>0} (keys(%gerhash)));
    print STDERR ("VerbForm=Ger\t", join(' ', map {"$_($gerhash{$_})"} (@keys)), "\n");
}



#------------------------------------------------------------------------------
# Compares UD release numbers and returns -1, 0, or 1 if the first number is
# less than, equal to, or greater than the second number.
#------------------------------------------------------------------------------
sub cmp_release_numbers
{
    my $a = shift;
    my $b = shift;
    my $amaj = $a;
    my $amin = 0;
    my $bmaj = $b;
    my $bmin = 0;
    if($a =~ m/^(\d+)\.(\d+)$/)
    {
        $amaj = $1;
        $amin = $2;
    }
    if($b =~ m/^(\d+)\.(\d+)$/)
    {
        $bmaj = $1;
        $bmin = $2;
    }
    if($amaj < $bmaj)
    {
        return -1;
    }
    elsif($amaj > $bmaj)
    {
        return 1;
    }
    elsif($amin < $bmin)
    {
        return -1;
    }
    elsif($amin > $bmin)
    {
        return 1;
    }
    else
    {
        return 0;
    }
}



#==============================================================================
# Functions to check various requirements placed by the UD ecosystem on a UD
# treebank. This is not the validation of a CoNLL-U file (for that see the
# script validate.py) but rather various checks about file naming conventions,
# metadata in the README file, documentation etc.
#==============================================================================



#------------------------------------------------------------------------------
# Checks whether a UD repository contains the expected files.
#------------------------------------------------------------------------------
sub check_files
{
    my $udpath = shift; # path to the folder with UD treebanks as subfolders (default: current folder, i.e., '.')
    my $folder = shift; # treebank folder name, e.g. 'UD_Czech-PDT'
    my $key = shift; # language and treebank code, e.g. 'cs_pdt' ###!!! We could compute it automatically from the folder name but we would need the language YAML file as a parameter instead.
    my $errors = shift; # reference to array where we can add error messages
    my $n_errors = shift; # reference to error counter
    my $sizes = shift; # optional hash ref; the caller may be interested in the train-dev-test sizes that we compute here, and we will put them for the caller in this hash if provided
    $sizes = {} if(!defined($sizes));
    my $ok = 1;
    # We need to change the current folder to the treebank folder. In order to
    # be able to return when we are done, remember the current folder.
    my $current_path = getcwd();
    $udpath = '.' if(!defined($udpath));
    my $treebank_path = "$udpath/$folder";
    chdir($treebank_path) or confess("Cannot change current folder to '$treebank_path': $!");
    # Check the existence of the README file.
    if(!-f 'README.txt' && !-f 'README.md')
    {
        $ok = 0;
        push(@{$errors}, "[L0 Repo files] $folder: missing README.txt|md\n");
        $$n_errors++;
    }
    if(-f 'README.txt' && -f 'README.md')
    {
        $ok = 0;
        push(@{$errors}, "[L0 Repo files] $folder: both README.txt and README.md are present\n");
        $$n_errors++;
    }
    # Check the existence of the LICENSE file.
    if(!-f 'LICENSE.txt')
    {
        $ok = 0;
        push(@{$errors}, "[L0 Repo files] $folder: missing LICENSE.txt\n");
        $$n_errors++;
    }
    # Check the existence of the CONTRIBUTING file.
    if(!-f 'CONTRIBUTING.md')
    {
        $ok = 0;
        push(@{$errors}, "[L0 Repo files] $folder: missing CONTRIBUTING.md\n");
        $$n_errors++;
    }
    # Check the data files.
    my $prefix = "$key-ud";
    my $train_found = 0;
    my $nwtrain = 0;
    my $nwdev = 0;
    my $nwtest = 0;
    my $stats = {};
    # In general, every treebank should have at least the test data.
    # If there are more data files, zero or one of each of the following is expected: train, dev.
    # There are exceptions for large treebanks that must split their train files because of Github size limits (the splitting is undone in the released UD packages).
    # Exception 1: Czech PDT has four train files: train-c, train-l, train-m, train-v.
    # Exception 2: German HDT has two train files: train-a, train-b.
    # Exception 3: Russian SynTagRus has three train files: train-a, train-b, train-c.
    my %train_exceptions =
    (
        'UD_Czech-PDT'         => {'desc' => 'cs_pdt-ud-train-[clmv].conllu',      'files' => ['train-c', 'train-l', 'train-m', 'train-v']},
        'UD_German-HDT'        => {'desc' => 'de_hdt-ud-train-[ab]-[12].conllu',   'files' => ['train-a-1', 'train-a-2', 'train-b-1', 'train-b-2']},
        'UD_Russian-SynTagRus' => {'desc' => 'ru_syntagrus-ud-train-[abc].conllu', 'files' => ['train-a', 'train-b', 'train-c']}
    );
    # No other CoNLL-U files are expected.
    # It is also expected that if there is dev, there is also train.
    if(exists($train_exceptions{$folder}))
    {
        $train_found = 1;
        foreach my $trainpart (@{$train_exceptions{$folder}{files}})
        {
            my $trainpartfile = "$prefix-$trainpart.conllu";
            if(-f $trainpartfile)
            {
                my $fstats = collect_statistics_about_ud_file($trainpartfile);
                $nwtrain += $fstats->{nword};
                add_statistics($stats, $fstats);
            }
            else
            {
                $train_found = 0;
                $ok = 0;
                push(@{$errors}, "[L0 Repo files] $folder: missing at least one file of $train_exceptions{$folder}{desc}");
                $$n_errors++;
                last;
            }
        }
    }
    else # normal treebank, no exceptions
    {
        if(-f "$prefix-train.conllu")
        {
            # Not finding train is not automatically an error. The treebank can be test-only.
            $train_found = 1;
            my $fstats = collect_statistics_about_ud_file("$prefix-train.conllu");
            $nwtrain = $fstats->{nword};
            add_statistics($stats, $fstats);
        }
    }
    # Look for development data. They are optional and not finding them is not an error.
    if(-f "$prefix-dev.conllu")
    {
        my $fstats = collect_statistics_about_ud_file("$prefix-dev.conllu");
        $nwdev = $fstats->{nword};
        add_statistics($stats, $fstats);
        # If there is dev data, there should also be training data!
        if(!$train_found)
        {
            $ok = 0;
            push(@{$errors}, "[L0 Repo files] $folder: missing training data although there is dev data\n");
            $$n_errors++;
        }
    }
    # Look for test data. Unlike train and dev, test data is mandatory!
    if(-f "$prefix-test.conllu")
    {
        my $fstats = collect_statistics_about_ud_file("$prefix-test.conllu");
        $nwtest = $fstats->{nword};
        add_statistics($stats, $fstats);
    }
    else
    {
        $ok = 0;
        push(@{$errors}, "[L0 Repo files] $folder: missing test data file $prefix-test.conllu\n");
        $$n_errors++;
    }
    my $nwall = $nwtrain+$nwdev+$nwtest;
    # Make the sizes available for the caller so they do not have to compute them themselves.
    $sizes->{'train'} = $nwtrain;
    $sizes->{'dev'} = $nwdev;
    $sizes->{'test'} = $nwtest;
    $sizes->{'all'} = $nwall;
    $sizes->{'stats'} = $stats;
    # Check the proportion of the sizes of train, dev, and test. The minimum sizes
    # are only a recommendation, as individual treebanks may have good reasons why
    # they need a different split. Hence we have a number of exceptions here.
    # Note that the keys of the following hash can be regular expressions.
    # This section is about sizes, not about existence. So an exception for the
    # test file means that it can be smaller than 10K words, but it still must
    # exist, which is checked above.
    my %split_exceptions =
    (
        # UD_Akkadian-RIAO: I think they told me that the treebank would grow; in the first version, they have only 20K test and no train.
        'UD_Akkadian-RIAO'             => {'train' => 1},
        # Exception: UD_Armenian-ArmTDP decided to have only about 5K test, do not ping them. (I don't remember whether I actually discussed it with Marat.)
        'UD_Armenian-ArmTDP'           => {'test' => 1},
        # UD_Czech-CLTT: The data needs a lot of fixes but ultimately I may want to re-split it, too. No exception at the moment.
        # Exception: UD_English-Atis keeps the train-dev-test split from the original corpus (it is small but it is roughly 80-10-10%).
        # Exception: UD_Turkish-Atis is parallel with UD_English-Atis (see above) and uses the same split.
        'UD_(English|Turkish)-Atis'    => {'dev' => 1, 'test' => 1},
        # Exception: UD_English-ESL are just below 10K test, and they do not participate in shared tasks anyway.
        'UD_English-ESL'               => {'test' => 1},
        # Exception: UD_English-GUMReddit has just 1840 words test. It does not participate in shared tasks (and if so, it can be merged with GUM).
        'UD_English-GUMReddit'         => {'test' => 1},
        # Exception: UD_Faroese-FarPaHC has 8644 words test. I think I did not ask them about it but they have already relased it this way.
        'UD_Faroese-FarPaHC'           => {'test' => 1},
        # Exception: UD_French-FQB is a test-only treebank (or use cross-validation, or add it to training data of Sequoia).
        'UD_French-FQB'                => {'train' => 1},
        # Exception: UD_French-ParisStories is just below 10K test, and the total treebank is slightly below 30K.
        'UD_French-ParisStories'       => {'test' => 1},
        # Exception: UD_French-Rhapsodie (formerly Spoken) is just below 10K test, and the total treebank is only slightly over 30K.
        'UD_French-Rhapsodie'          => {'test' => 1},
        'UD_French-Spoken'             => {'test' => 1},
        # Exception: UD_German-LIT is a test-only treebank (intended primarily for linguistic research).
        'UD_German-LIT'                => {'train' => 1, 'dev' => 1},
        # Exception: UD_Hindi_English-HIENCS has only 3K test; they do not participate in shared tasks.
        'UD_Hindi_English-HIENCS'      => {'test' => 1},
        # Exception: UD_Italian-TWITTIRO overlaps with POSTWITA and tries to match its data split.
        'UD_Italian-TWITTIRO'          => {'test' => 1},
        # UD_Manx-Cadhan: No exception but wait. 2021-05-06 Kevin writes: I have another 20k words that are mostly correct but need one more editing pass. I decided to stick with the 20k in test for now, with the aim of doing a 3-way split for the next release (if that's ok). My aim is to eventually get to 100k total.
        # UD_Old_East_Slavic-Birchbark: 2022-10-05 Olga writes: This treebank contains all available linguistic material for the period. Birchbark letters are small documents and on average 100-200 words are excavated each year. So the treebank will grow but slowly. I do not want to switch dev and train since (i) train data was already released and (ii) there are some unanalysable fragments in train which we add intentionally as we believe it can still help for training models.
        'UD_Old_East_Slavic-Birchbark' => {'train' => 1},
        # UD_Old_East_Slavic-RNC: No exception but wait. 2021-05-05 Olga writes: Another 20k portion of the RNC orv data is planned as dev, it has not been released yet. I would keep it as is if possible: the current 20 k test were reported as test in some of our experiments.
        # UD_Pomak-Philotis: Test has only 8804 words. Stella: Well, yes, we followed the 10%-10%-80% rule.
        'UD_Pomak-Philotis'            => {'test' => 1},
        # Exception: UD_Sanskrit-Vedic is just below 10K test, and the total treebank is only slightly over 20K.
        'UD_Sanskrit-Vedic'            => {'test' => 1},
        # Exception: UD_Scottish_Gaelic-ARCOSG is close to 10K test tokens but they could not get there if they did not want to split documents.
        'UD_Scottish_Gaelic-ARCOSG'    => {'test' => 1},
        # Exception: UD_Turkish-FrameNet uses a 80-10-10% split, although the treebank is rather small (also, the sizes are computed in terms of number of frames rather than words).
        'UD_Turkish-FrameNet'          => {'test' => 1},
        # Exception: UD_Turkish-Penn keeps the train-dev-test split from the original treebank where there are only 3K words dev and 4K words test.
        'UD_Turkish-Penn'              => {'dev' => 1, 'test' => 1},
        # Exception: ParTUT has some portions smaller because of other limitations (sync across languages and with UD_Italian-ISDT).
        'UD_.+-ParTUT'                 => {'train' => 1, 'dev' => 1, 'test' => 1},
        # Exception: PUD parallel data (including Japanese-PUDLUW) are currently test only, even if in some languages there is more than 20K words.
        'UD_.+-PUD(LUW)?'              => {'train' => 1, 'dev' => 1}
    );
    my $allow_smalltrain_re = '^('.join('|', grep {$split_exceptions{$_}{train}} (keys(%split_exceptions))).')$';
    my $allow_smalldev_re   = '^('.join('|', grep {$split_exceptions{$_}{dev}}   (keys(%split_exceptions))).')$';
    my $allow_smalltest_re  = '^('.join('|', grep {$split_exceptions{$_}{test}}  (keys(%split_exceptions))).')$';
    # For small and growing treebanks, we expect the files to appear roughly in the following order:
    # 1. test (>=10K tokens if possible);
    # 2. train (if it can be larger than test or if this is the only treebank of the language and train is a small sample);
    # 3. dev (if it can be at least 10K tokens and if train is larger than both test and dev).
    if($nwtest==0 && ($nwtrain>0 || $nwdev>0))
    {
        $ok = 0;
        push(@{$errors}, "[L0 Repo train-dev-test] $folder: train or dev exists but there is no test\n");
        $$n_errors++;
    }
    if($nwall>10000 && $nwtest<10000 && $folder !~ m/$allow_smalltest_re/)
    {
        $ok = 0;
        push(@{$errors}, "[L0 Repo train-dev-test] $folder: more than 10K words (precisely: $nwall) available but test has only $nwtest words\n");
        $$n_errors++;
    }
    if($nwall>20000 && $nwtrain<10000 && $folder !~ m/$allow_smalltrain_re/)
    {
        $ok = 0;
        push(@{$errors}, "[L0 Repo train-dev-test] $folder: more than 20K words (precisely: $nwall) available but train has only $nwtrain words\n");
        $$n_errors++;
    }
    if($nwall>30000 && $nwdev<5000 && $folder !~ m/$allow_smalldev_re/)
    {
        $ok = 0;
        push(@{$errors}, "[L0 Repo train-dev-test] $folder: more than 30K words (precisely: $nwall) available but dev has only $nwdev words\n");
        $$n_errors++;
    }
    # Check that the treebank is not ridiculously small. Minimum size required since release 2.10.
    if($stats->{nsent} < 20 || $stats->{nword} < 100)
    {
        $ok = 0;
        my $ss = $stats->{nsent} > 1 ? 's' : '';
        my $ws = $stats->{nword} > 1 ? 's' : '';
        push(@{$errors}, "[L0 Repo treebank-size] $folder: treebank is too small: found only $stats->{nsent} sentence$ss and $stats->{nword} word$ws\n");
        $$n_errors++;
    }
    # Check all files and folders in the treebank folder to see if there are any unpermitted extra files.
    opendir(DIR, '.') or confess("Cannot read the contents of the folder '$treebank_path': $!");
    my @files = readdir(DIR);
    closedir(DIR);
    # Some extra files are tolerated in the Github repository although we do not include them in the release package; these are not reported.
    my @tolerated =
    (
        # tolerated but not released
        '\.\.?',
        '\.git(ignore|attributes)?',
        '\.travis\.yml',
        'not-to-release',
        # expected and released
        'README\.(txt|md)',
        'LICENSE\.txt',
        'CONTRIBUTING\.md',
        'stats\.xml'
    );
    if(exists($train_exceptions{$folder}))
    {
        push(@tolerated, '('.$train_exceptions{$folder}{desc}.'|'.$prefix.'-(dev|test)\.conllu)');
    }
    else
    {
        push(@tolerated, $prefix.'-(train|dev|test)\.conllu');
    }
    my $tolerated_re = join('|', @tolerated);
    my @extrafiles = map
    {
        $_ .= '/' if(-d $_);
        $_
    }
    grep
    {
        !m/^($tolerated_re)$/
    }
    (@files);
    # Some treebanks have exceptional extra files that have been approved and released previously.
    # The treebanks without underlying text need a program that merges the CoNLL-U files with the separately distributed text.
    my %extra_exceptions =
    (
        'UD_Arabic-NYUAD'         => '^merge\.jar$',
        'UD_English-ESL'          => '^merge\.py$',
        'UD_English-GUMReddit'    => '^get_text\.py$',
        'UD_Hindi_English-HIENCS' => '^(merge/?|crawl_tweets\.py)$',
        'UD_Japanese-KTC'         => '^merge',
        'UD_Japanese-BCCWJ'       => '^merge',
        'UD_Japanese-BCCWJLUW'    => '^merge'
    );
    if(exists($extra_exceptions{$folder}))
    {
        @extrafiles = grep {!m/$extra_exceptions{$folder}/} (@extrafiles);
    }
    if(scalar(@extrafiles) > 0)
    {
        $ok = 0;
        push(@{$errors}, "[L0 Repo files] $folder extra files: ".join(', ', sort(@extrafiles))."\n");
        $$n_errors += scalar(@extrafiles);
    }
    # Change current folder back where we were when entering this function.
    chdir($current_path) or confess("Cannot change current folder back to '$currentpath': $!");
    return $ok;
}



#------------------------------------------------------------------------------
# Checks whether metadata in the README file provides required information.
#------------------------------------------------------------------------------
sub check_metadata
{
    my $folder = shift; # folder name, e.g. 'UD_Czech-PDT', not path
    my $metadata = shift; # reference to hash returned by udlib::read_readme()
    my $errors = shift; # reference to array of error messages
    my $n_errors = shift; # reference to error counter
    my $ok = 1;
    # New contributors sometimes forget to add it. Old contributors sometimes modify it for no good reason ('Data available since' should never change!)
    # And occasionally people delete the metadata section completely, despite being told not to do so (Hebrew team in the last minute of UD 2.0!)
    if($metadata->{'Data available since'} =~ m/UD\s*v([0-9]+\.[0-9]+)/)
    {
        my $claimed = $1;
        # The value 'Data available since' must not change from release to release.
        # It must forever refer to the first release of the treebank in UD.
        # Therefore, this script will remember the correct value, too, and shout if it changes in the README.
        my @new_treebanks_by_release =
        (
            '1.0'  => ['Czech-PDT', 'English-EWT', 'Finnish-TDT', 'French-GSD', 'German-GSD', 'Hungarian-Szeged', 'Irish-IDT', 'Italian-ISDT', 'Spanish-GSD', 'Swedish-Talbanken'],
            '1.1'  => ['Basque-BDT', 'Bulgarian-BTB', 'Croatian-SET', 'Danish-DDT', 'Finnish-FTB', 'Greek-GDT', 'Hebrew-HTB', 'Indonesian-GSD', 'Persian-Seraji'],
            '1.2'  => ['Ancient_Greek-Perseus', 'Ancient_Greek-PROIEL', 'Arabic-PADT', 'Dutch-Alpino', 'Estonian-EDT', 'Gothic-PROIEL', 'Hindi-HDTB', 'Japanese-KTC', 'Latin-ITTB', 'Latin-Perseus', 'Latin-PROIEL', 'Norwegian-Bokmaal', 'Old_Church_Slavonic-PROIEL', 'Polish-PDB', 'Portuguese-Bosque', 'Romanian-RRT', 'Slovenian-SSJ', 'Tamil-TTB'],
            '1.3'  => ['Catalan-AnCora', 'Czech-CAC', 'Czech-CLTT', 'Dutch-LassySmall', 'English-ESL', 'English-LinES', 'Galician-CTG', 'Chinese-GSD', 'Kazakh-KTB', 'Latvian-LVTB', 'Portuguese-GSD', 'Russian-GSD', 'Russian-SynTagRus', 'Slovenian-SST', 'Spanish-AnCora', 'Swedish-LinES', 'Turkish-IMST'],
            '1.4'  => ['Coptic-Scriptorium', 'Galician-TreeGal', 'Japanese-GSD', 'Sanskrit-UFAL', 'Slovak-SNK', 'Swedish_Sign_Language-SSLC', 'Ukrainian-IU', 'Uyghur-UDT', 'Vietnamese-VTB'],
            '2.0'  => ['Arabic-NYUAD', 'Belarusian-HSE', 'English-ParTUT', 'French-FTB', 'French-ParTUT', 'French-Sequoia', 'Italian-ParTUT', 'Korean-GSD', 'Lithuanian-HSE', 'Norwegian-Nynorsk', 'Urdu-UDTB'],
            '2.1'  => ['Afrikaans-AfriBooms', 'Arabic-PUD', 'Buryat-BDT', 'Cantonese-HK', 'Czech-FicTree', 'Czech-PUD', 'English-PUD', 'Finnish-PUD', 'French-PUD', 'German-PUD', 'Hindi-PUD', 'Chinese-CFL', 'Chinese-HK', 'Chinese-PUD', 'Italian-PoSTWITA', 'Italian-PUD', 'Japanese-PUD', 'Kurmanji-MG', 'Marathi-UFAL', 'North_Sami-Giella', 'Norwegian-NynorskLIA', 'Portuguese-PUD', 'Romanian-Nonstandard', 'Russian-PUD', 'Serbian-SET', 'Spanish-PUD', 'Swedish-PUD', 'Telugu-MTG', 'Turkish-PUD', 'Upper_Sorbian-UFAL'],
            '2.2'  => ['Amharic-ATT', 'Armenian-ArmTDP', 'Breton-KEB', 'English-GUM', 'Faroese-OFT', 'French-Rhapsodie', 'Indonesian-PUD', 'Japanese-BCCWJ', 'Japanese-Modern', 'Komi_Zyrian-IKDP', 'Komi_Zyrian-Lattice', 'Korean-Kaist', 'Korean-PUD', 'Naija-NSC', 'Old_French-SRCMF', 'Polish-LFG', 'Russian-Taiga', 'Tagalog-TRG', 'Thai-PUD', 'Warlpiri-UFAL', 'Yoruba-YTB'],
            '2.3'  => ['Akkadian-PISANDUB', 'Bambara-CRB', 'Erzya-JR', 'Hindi_English-HIENCS', 'Maltese-MUDT'],
            '2.4'  => ['Assyrian-AS', 'Classical_Chinese-Kyoto', 'Estonian-EWT', 'French-FQB', 'German-HDT', 'German-LIT', 'Italian-VIT', 'Karelian-KKPP', 'Lithuanian-ALKSNIS', 'Mbya_Guarani-Dooley', 'Mbya_Guarani-Thomas', 'Old_East_Slavic-RNC', 'Old_East_Slavic-TOROT', 'Polish-PUD', 'Turkish-GB', 'Welsh-CCG', 'Wolof-WTB'],
            '2.5'  => ['Bhojpuri-BHTB', 'Chinese-GSDSimp', 'English-Pronouns', 'Italian-TWITTIRO', 'Komi_Permyak-UH', 'Livvi-KKPP', 'Moksha-JR', 'Romanian-SiMoNERo', 'Scottish_Gaelic-ARCOSG', 'Skolt_Sami-Giellagas', 'Swiss_German-UZH'],
            '2.6'  => ['Albanian-TSA', 'English-GUMReddit', 'Icelandic-PUD', 'Latin-LLCT', 'Sanskrit-Vedic', 'Tagalog-Ugnayan'],
            '2.7'  => ['Akkadian-RIAO', 'Akuntsu-TuDeT', 'Apurina-UFPA', 'Chukchi-HSE', 'Faroese-FarPaHC', 'Finnish-OOD', 'Icelandic-IcePaHC', 'Indonesian-CSUI', 'Khunsari-AHA', 'Manx-Cadhan', 'Munduruku-TuDeT', 'Nayini-AHA', 'Old_Turkish-Tonqq', 'Persian-PerDT', 'Soi-AHA', 'South_Levantine_Arabic-MADAR', 'Tamil-MWTT', 'Tupinamba-TuDeT', 'Turkish-BOUN', 'Turkish_German-SAGT'],
            '2.8'  => ['Beja-NSC', 'Frisian_Dutch-Fame', 'Guajajara-TuDeT', 'Icelandic-Modern', 'Irish-TwittIrish', 'Italian-Valico', 'Kaapor-TuDeT', 'Kangri-KDTB', 'Kiche-IU', 'Latin-UDante', 'Low_Saxon-LSDC', 'Makurap-TuDeT', 'Romanian-ArT', 'Turkish-FrameNet', 'Turkish-Kenet', 'Turkish-Penn', 'Turkish-Tourism', 'Western_Armenian-ArmTDP', 'Yupik-SLI'],
            '2.9'  => ['Armenian-BSUT', 'Bengali-BRU', 'English-Atis', 'French-ParisStories', 'Japanese-BCCWJLUW', 'Japanese-GSDLUW', 'Japanese-PUDLUW', 'Javanese-CSUI', 'Karo-TuDeT', 'Ligurian-GLT', 'Neapolitan-RB', 'Tatar-NMCTT', 'Turkish-Atis', 'Xibe-XDT', 'Yakut-YKTDT'],
            '2.10' => ['Ancient_Hebrew-PTNK', 'Cebuano-GJA', 'Guarani-OldTuDeT', 'Hebrew-IAHLTwiki', 'Hittite-HitTB', 'Italian-MarkIT', 'Madi-Jarawara', 'Old_East_Slavic-Birchbark', 'Pomak-Philotis', 'Teko-TuDeT', 'Umbrian-IKUVINA']
        );
        my %new_treebanks_by_release = @new_treebanks_by_release;
        my $last_release = $new_treebanks_by_release[-2];
        my $correct;
        foreach my $release (keys(%new_treebanks_by_release))
        {
            foreach my $treebank (@{$new_treebanks_by_release{$release}})
            {
                if("UD_$treebank" eq $folder)
                {
                    $correct = $release;
                    last;
                }
            }
        }
        if(defined($correct) && $claimed ne $correct)
        {
            $ok = 0;
            push(@{$errors}, "[L0 Repo readme] $folder README: 'Data available since: $claimed' is not true. This treebank was first released in UD v$correct.\n");
            $$n_errors++;
        }
        elsif(!defined($correct) && cmp_release_numbers($claimed, $last_release) <= 0)
        {
            $ok = 0;
            push(@{$errors}, "[L0 Repo readme] $folder README: 'Data available since: $claimed' is not true. This treebank was not yet released.\n");
            $$n_errors++;
        }
    }
    else
    {
        $ok = 0;
        push(@{$errors}, "[L0 Repo readme] $folder README: Unknown format of Data available since: '$metadata->{'Data available since'}'\n");
        $$n_errors++;
    }
    if($metadata->{Genre} !~ m/\w/)
    {
        $ok = 0;
        push(@{$errors}, "[L0 Repo readme] $folder README: Missing list of genres: '$metadata->{Genre}'\n");
        $$n_errors++;
    }
    else
    {
        # Originally (until UD 2.2) it was not an error if people invented their genres in addition to the predefined ones.
        # However, some treebanks do not follow prescribed syntax (e.g. place commas between genres) or just have typos here
        # (e.g. besides "news" there is also "new" or "newswire"), so we better ban unregistered genres and check it automatically.
        # Note that a copy of the list of known genres is also in evaluate_treebank.pl and in docs-automation/genre_symbols.json.
        my @official_genres = ('academic', 'bible', 'blog', 'email', 'fiction', 'government', 'grammar-examples', 'learner-essays', 'legal', 'medical', 'news', 'nonfiction', 'poetry', 'reviews', 'social', 'spoken', 'web', 'wiki');
        my @genres = split(/\s+/, $metadata->{Genre});
        my @unknown_genres = grep {my $g = $_; my @found = grep {$_ eq $g} (@official_genres); scalar(@found)==0} (@genres);
        if(scalar(@unknown_genres)>0)
        {
            $ok = 0;
            my $ug = join(' ', sort(@unknown_genres));
            push(@{$errors}, "[L0 Repo readme] $folder README: Unknown genre '$ug'\n");
            $$n_errors++;
        }
    }
    if($metadata->{License} !~ m/\w/)
    {
        $ok = 0;
        push(@{$errors}, "[L0 Repo readme] $folder README: Missing identification of license in README: '$metadata->{License}'\n");
        $$n_errors++;
    }
    if($metadata->{'Includes text'} !~ m/^(yes|no)$/i)
    {
        $ok = 0;
        push(@{$errors}, "[L0 Repo readme] $folder README: Metadata 'Includes text' must be 'yes' or 'no' but the current value is: '$metadata->{'Includes text'}'\n");
        $$n_errors++;
    }
    foreach my $annotation (qw(Lemmas UPOS XPOS Features Relations))
    {
        if($metadata->{$annotation} !~ m/\w/)
        {
            $ok = 0;
            push(@{$errors}, "[L0 Repo readme] $folder README: Missing information on availability and source of $annotation\n");
            $$n_errors++;
        }
        elsif($metadata->{$annotation} !~ m/^(manual native|converted from manual|converted with corrections|automatic|automatic with corrections|not available)$/)
        {
            $ok = 0;
            push(@{$errors}, "[L0 Repo readme] $folder README: Unknown value of metadata $annotation: '$metadata->{$annotation}'\n");
            $$n_errors++;
        }
    }
    if($metadata->{Contributing} !~ m/\w/)
    {
        $ok = 0;
        push(@{$errors}, "[L0 Repo readme] $folder README: Missing metadata Contributing (where and how to contribute)\n");
        $$n_errors++;
    }
    elsif($metadata->{Contributing} !~ m/^(here|here source|elsewhere|to be adopted)$/)
    {
        $ok = 0;
        push(@{$errors}, "[L0 Repo readme] $folder README: Unknown value of metadata Contributing: '$metadata->{Contributing}'\n");
        $$n_errors++;
    }
    if($metadata->{Contributors} !~ m/\w/)
    {
        $ok = 0;
        push(@{$errors}, "[L0 Repo readme] $folder README: Missing list of contributors: '$metadata->{Contributors}'\n");
        $$n_errors++;
    }
    if($metadata->{Contact} !~ m/\@/)
    {
        $ok = 0;
        push(@{$errors}, "[L0 Repo readme] $folder README: Missing contact e-mail: '$metadata->{Contact}'\n");
        $$n_errors++;
    }
    # Check other sections of the README file.
    if(!defined($metadata->{sections}{summary}))
    {
        $ok = 0;
        push(@{$errors}, "[L0 Repo readme] $folder README: Section Summary not found.\n");
        $$n_errors++;
    }
    elsif(length($metadata->{sections}{summary})<40)
    {
        $ok = 0;
        push(@{$errors}, "[L0 Repo readme] $folder README: Section Summary is too short.\n");
        $$n_errors++;
    }
    elsif(length($metadata->{sections}{summary})>500)
    {
        $ok = 0;
        push(@{$errors}, "[L0 Repo readme] $folder README: Section Summary is too long.\n");
        $$n_errors++;
    }
    elsif($metadata->{sections}{summary} =~ m/see \[release checklist\]/)
    {
        $ok = 0;
        push(@{$errors}, "[L0 Repo readme] $folder README: Section Summary still contains the templatic text. Please put a real summary there.\n");
        $$n_errors++;
    }
    if(!$metadata->{changelog})
    {
        $ok = 0;
        push(@{$errors}, "[L0 Repo readme] $folder README: README does not contain 'ChangeLog'\n");
        $$n_errors++;
    }
    # Add a link to the guidelines for README files. Add it to the last error message.
    # Do not make it a separate error message (just in case we get rid of $n_errors and use scalar(@errors) in the future).
    unless($ok)
    {
        $errors->[-1] .= "See http://universaldependencies.org/release_checklist.html#treebank-metadata for guidelines on machine-readable metadata.\n";
        $errors->[-1] .= "See http://universaldependencies.org/release_checklist.html#the-readme-file for general guidelines on README files.\n";
    }
    return $ok;
}



#------------------------------------------------------------------------------
# Checks whether documentation contains a summary page about a language.
#------------------------------------------------------------------------------
sub check_documentation
{
    my $udpath = shift; # path to the folder with UD treebanks and docs as subfolders (default: current folder, i.e., '.')
    my $folder = shift; # treebank folder name, e.g. 'UD_Czech-PDT' (here we need it only for the error messages)
    my $lcode = shift; ###!!! We could compute it automatically from the folder name but we would need the language YAML file as a parameter instead.
    my $errors = shift; # reference to array of error messages
    my $n_errors = shift; # reference to error counter
    my $ok = 1;
    $udpath = '.' if(!defined($udpath));
    my $indexpath = "$udpath/docs/_$lcode/index.md";
    if(! -f $indexpath)
    {
        $ok = 0;
        push(@{$errors}, "[L0 Repo lang-spec-doc] $folder: Language '$lcode' does not have the one-page documentation summary in the docs repository.\nSee http://universaldependencies.org/contributing_language_specific.html for instructions on how to write documentation.\n");
        $$n_errors++;
    }
    else
    {
        # So the file exists but does it really contain anything useful?
        # Some people just create an almost empty file without bothering to put the contents there.
        my $doc;
        open(IDX, $indexpath);
        while(<IDX>)
        {
            $doc .= $_;
        }
        close(IDX);
        # Czech documentation has over 16000 B.
        # Swedish documentation has over 4500 B.
        # Yoruba is probably incomplete but it still has over 3500 B.
        # Let's require 2500 B as a minimum and hope that people don't just put a sequence of whitespace characters there.
        if(length($doc) < 2500)
        {
            $ok = 0;
            push(@{$errors}, "[L0 Repo lang-spec-doc] $folder: Language '$lcode' does not have the one-page documentation summary in the docs repository (the file exists but it seems incomplete).\nSee http://universaldependencies.org/contributing_language_specific.html for instructions on how to write documentation.\n");
            $$n_errors++;
        }
    }
    return $ok;
}



#==============================================================================
# Functions to collect statistics about UD data.
#==============================================================================



#------------------------------------------------------------------------------
# Examines a UD treebank and counts the number of tokens in all .conllu files.
#------------------------------------------------------------------------------
sub collect_statistics_about_ud_treebank
{
    my $treebank_path = shift;
    my $treebank_code = shift;
    my $prefix = "$treebank_code-ud";
    # All .conllu files with the given prefix in the given folder are considered disjunct parts of the treebank.
    # Hence we do not have to bother with Czech exceptions in file naming etc.
    # But we have to be careful if we look at a future release where the folders may not yet be clean.
    opendir(DIR, $treebank_path) or confess("Cannot read folder $treebank_path: $!");
    my @files = grep {m/^$prefix-.+\.conllu$/} (readdir(DIR));
    closedir(DIR);
    my $stats =
    {
        'nsent' => 0,
        'ntok'  => 0,
        'nfus'  => 0,
        'nword' => 0
    };
    foreach my $file (@files)
    {
        add_statistics($stats, collect_statistics_about_ud_file("$treebank_path/$file"));
    }
    return $stats;
}



#------------------------------------------------------------------------------
# Counts the number of tokens in a .conllu file.
#------------------------------------------------------------------------------
sub collect_statistics_about_ud_file
{
    my $file_path = shift;
    my $nsent = 0;
    my $ntok = 0;
    my $nfus = 0;
    my $nword = 0;
    open(CONLLU, $file_path) or confess("Cannot read file $file_path: $!");
    while(<CONLLU>)
    {
        # Skip comment lines.
        next if(m/^\#/);
        # Empty lines separate sentences. There must be an empty line after every sentence including the last one.
        if(m/^\s*$/)
        {
            $nsent++;
        }
        # Lines with fused tokens do not contain features but we want to count the fusions.
        elsif(m/^(\d+)-(\d+)\t(\S+)/)
        {
            my $i0 = $1;
            my $i1 = $2;
            my $size = $i1-$i0+1;
            $ntok -= $size-1;
            $nfus++;
        }
        else
        {
            $ntok++;
            $nword++;
        }
    }
    close(CONLLU);
    my $stats =
    {
        'nsent' => $nsent,
        'ntok'  => $ntok,
        'nfus'  => $nfus,
        'nword' => $nword
    };
    return $stats;
}



#------------------------------------------------------------------------------
# Sums statistics of two .conllu files, as they are returned by the functions
# collect_statistics_about_ud_file() and collect_statistics_about_ud_treebank().
# Takes two hash references and adds the numbers from the second hash to the
# first hash, i.e., the first hash will be modified in-place!
#------------------------------------------------------------------------------
sub add_statistics
{
    my $tgt = shift; # hash ref
    my $src = shift; # hash ref
    $tgt->{nsent} += $src->{nsent};
    $tgt->{ntok}  += $src->{ntok};
    $tgt->{nfus}  += $src->{nfus};
    $tgt->{nword} += $src->{nword};
    return $tgt;
}



#==============================================================================
# Deprecated functions. These will be removed in the future.
#==============================================================================



#------------------------------------------------------------------------------
# Returns reference to hash of known UD treebank codes (key = treebank name,
# without the UD_ prefix but with underscores instead of spaces; value =
# language_treebank code). Reads the JSON file in the docs repository.
# Takes the path to the main UD folder (contains docs as subfolder). Default: .
#------------------------------------------------------------------------------
sub get_ltcode_hash
{
    my $path = shift;
    print STDERR ("WARNING: udlib::get_ltcode_hash() is obsolete because the file lcodes.json in docs is no longer maintained!\n");
    print STDERR ("WARNING: Use udlib::get_language_hash() instead, which reads docs-automation/codes_and_flags.yaml.\n");
    $path = '.' if(!defined($path));
    if (-d "$path/docs")
    {
        $path .= '/docs';
    }
    my $lcodes;
    if (-f "$path/gen_index/lcodes.json")
    {
        $lcodes = json_file_to_perl("$path/gen_index/lcodes.json");
        # For example:
        # $lcodes->{'Finnish-FTB'} eq 'fi_ftb'
    }
    die("Cannot find or read $path/docs/gen_index/lcodes.json") if (!defined($lcodes));
    return $lcodes;
}



#------------------------------------------------------------------------------
# Same as get_ltcode_hash() but collects only language names/codes, without the
# optional treebank identifier.
#------------------------------------------------------------------------------
sub get_lcode_hash
{
    my $path = shift;
    my $ltcodes = get_ltcode_hash($path);
    my %lcodes;
    foreach my $key (keys(%{$ltcodes}))
    {
        my $lkey = $key;
        my $lcode = $ltcodes->{$lkey};
        # Remove treebank name/code if any. Keep only language name/code.
        $lkey =~ s/-.*//;
        $lcode =~ s/_.*//;
        if(!exists($lcodes{$lkey}))
        {
            $lcodes{$lkey} = $lcode;
        }
        # Sanity check: all treebanks with one language name should use the same language code.
        else
        {
            if($lcodes{$lkey} ne $lcode)
            {
                die("Code conflict for language '$lkey': old code '$lcodes{$lkey}', new code '$lcode'");
            }
        }
    }
    return \%lcodes;
}



1;
