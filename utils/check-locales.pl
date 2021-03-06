#!/usr/bin/perl

use strict;
use warnings;
use File::Basename;
use Getopt::Long;

my $debug = 0;
my $errors = 0;
my $replace = 0;

my(%inheritance_chains) = (
    "pt-BR" => ["pt-PT"],
    "pt-PT" => ["pt-BR"],
    "zh-CN" => ["zh-TW"],
    "zh-TW" => ["zh-CN"],
);

my $locale_dir = "chrome/locale";
my(@locales) = map(basename($_), glob("chrome/locale/*"));
my $master = "en-US";
foreach my $locale (@locales) {
    if (! $inheritance_chains{$locale}) {
        $inheritance_chains{$locale} = [];
    }
}
foreach my $locale (keys %inheritance_chains) {
    my $base = substr($locale, 0, 2);
    foreach my $other (grep(/^$base/, @locales)) {
        next if ($other eq $locale);
        next if (grep(/^$other$/, @{$inheritance_chains{$locale}}));
        push(@{$inheritance_chains{$locale}}, $other);
    }
}

die if (! GetOptions("replace" => \$replace,
                     "debug" => \$debug));

foreach my $locale (sort keys %inheritance_chains) {
    foreach my $file (map(basename($_), glob("$locale_dir/$master/*.dtd"))) {
        &check_dtd($locale, $file);
    }

    foreach my $file (map(basename($_),
                          glob("$locale_dir/$master/*.properties"))) {
        &check_properties($locale, $file);
    }
}

exit($errors);

sub check_dtd {
    my($locale, $file) = @_;
    &check_generic($locale, $file, qr/^<!ENTITY\s+(\S+)/, qr/\&(?!quot)(?!;)/,
                   qr/^<!--/, ">\n");
}

sub check_properties {
    my($locale, $file) = @_;
    &check_generic($locale, $file, qr/^([^=]+)=/, qr/^[^_].*\&(?!quot)(?!;)/);
}

my(%replaced);

sub check_generic {
    my($locale, $file, $pattern, $error_pattern, $ignore_pattern,
       $record_separator) = @_;
    my(@keys, %strings);
    local($/) = $record_separator ? $record_separator : "\n";
    foreach my $ancestor ($locale, @{$inheritance_chains{$locale}}, $master) {
        my $fname = "$locale_dir/$ancestor/$file";
        if (! -f $fname) {
            next;
        }
        &debug("Reading $fname");
        open(MASTER, "<", $fname) or die;
        while (<MASTER>) {
            next if (/^$/);
            next if (/-\*-.*-\*-/);
            # Ignore initial blank lines when $record_separator isn't "\n"
            s/^\n+//;
            next if ($ignore_pattern && /$ignore_pattern/);
            if (! /$pattern/) {
                &error("Unrecognized record $. of $ancestor/$file: $_");
                next;
            }
	    if ($error_pattern and /$error_pattern/) {
		&error("Bad content on record $. of $ancestor/$file: $_");
                next;
	    }
            if ($replaced{"$ancestor/$file/$1"}) {
                &debug("Ignoring replaced key $1 in $ancestor/$file");
                next;
            }
            &debug("Read key $1 from $ancestor/$file");
            my $n = {value => $_, locale => $ancestor};
            if ($strings{$1}) {
                push(@{$strings{$1}}, $n);
            }
            else {
                push(@keys, $1);
                $strings{$1} = [$n];
            }
        }
        close(MASTER);
    }
    foreach my $key (@keys) {
        if ($strings{$key}->[-1]->{"locale"} ne $master) {
            &error("Extra key $key in $locale/$file");
            next;
        }
        if ($strings{$key}->[0]->{"locale"} eq $locale) {
            &debug("Good key $key in $locale/$file");
            &check_substitutions(\%strings, $key, $locale, $file);
            next;
        }
        if ($replace) {
            open(F, ">>", "$locale_dir/$locale/$file") or die;
            print(F $strings{$key}->[0]->{"value"}) or die;
            close(F) or die;
            $replaced{"$locale/$file/$key"} = 1;
            &debug("Replaced $key in $locale/$file from " .
                   "$strings{$key}->[0]->{'locale'}");
            next;
        }
        &error("Key $key is missing from $locale/$file");
    }
}

sub check_substitutions {
    my($strings, $key, $locale, $file) = @_;
    return if ($locale eq $master);
    return if ($strings->{$key}->[0]->{"locale"} ne $locale);
    my $master_string = $strings->{$key}->[-1]->{"value"};
    my $translated_string = $strings->{$key}->[0]->{"value"};
    return if ($master_string eq $translated_string);
    my(%master_subs) = &get_substitutions($master_string);
    my(%translated_subs) = &get_substitutions($translated_string);
    foreach my $sub (keys %master_subs) {
        if (! $translated_subs{$sub}) {
            &error("Key $key is missing substitution $sub in $locale/$file");
        }
    }
    foreach my $sub (keys %translated_subs) {
        if (! $master_subs{$sub}) {
            &error("Key $key has extra substitution $sub in $locale/$file");
        }
    }
}

sub get_substitutions {
    local($_) = @_;
    my(@subs) = /(%(?:\d+$)?[Sx])/g;
    my(%subs);
    map($subs{$_}++, @subs);
    %subs;
}

sub debug {
    print(@_, "\n") if ($debug);
}

my(%warned);

sub warning {
    my($msg) = @_;
    return if ($warned{$msg});
    warn("$msg\n");
    $warned{$msg} = 1;
}

sub error {
    my($msg) = @_;
    &warning($msg);
    $errors++;
}
