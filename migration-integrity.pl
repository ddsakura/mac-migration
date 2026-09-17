#!/usr/bin/perl
# macOS core Perl modules only. Paths are byte strings encoded as base64 in JSON.
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname basename);
use File::Spec;
use Fcntl qw(:mode :DEFAULT);
use Digest::SHA;
use MIME::Base64 qw(encode_base64);
use JSON::PP;

my $json = JSON::PP->new->canonical->ascii;
my $manifest = 'manifest.json';
my $marker = 'backup-format';
my $temporary;
END { unlink $temporary if defined $temporary && -f $temporary; }
sub fail { die "Integrity/preflight: $_[0]\n"; }
sub b64 { encode_base64($_[0], '') }
sub present { -e $_[0] || -l $_[0] }
sub canonical {
    my ($path) = @_;
    $path = File::Spec->rel2abs($path);
    # Resolve existing ancestors (including macOS /var -> /private/var).
    return abs_path($path) // fail("cannot resolve $path") if present($path);
    my $parent = dirname($path);
    fail("cannot resolve $path") if $parent eq $path;
    return canonical($parent) if basename($path) eq '.';
    return dirname(canonical($parent)) if basename($path) eq '..';
    return File::Spec->canonpath(canonical($parent) . '/' . basename($path));
}
sub within { $_[0] eq $_[1] || index($_[0], $_[1] eq '/' ? '/' : "$_[1]/") == 0 }
sub disjoint {
    my ($a, $b) = map { canonical($_) } @_;
    fail("overlapping paths: $a <-> $b") if within($a, $b) || within($b, $a);
}
sub inventory {
    my ($root, $metadata, $skip_special) = @_;
    my @entries;
    my $walk;
    $walk = sub {
        my ($path, $relative) = @_;
        my @st = lstat($path);
        fail("missing/unreadable path (base64): " . b64($path)) unless @st;
        my $entry = {path_b64 => b64($relative)};
        if (S_ISLNK($st[2])) {
            my $target = readlink($path);
            defined $target or fail("cannot read link: " . b64($path));
            $entry->{type} = 'symlink';
            $entry->{target_b64} = b64($target);
        } elsif (S_ISDIR($st[2])) {
            $entry->{type} = 'directory';
        } elsif (S_ISREG($st[2])) {
            sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW) or fail("cannot read file: " . b64($path));
            binmode $fh;
            my @opened = stat($fh);
            fail('file changed during verification (relative path base64): ' . b64($relative))
                unless $opened[0] == $st[0] && $opened[1] == $st[1];
            $entry->{type} = 'file';
            $entry->{sha256} = Digest::SHA->new(256)->addfile($fh)->hexdigest;
            my @after = stat($fh);
            close $fh or fail('read close failed');
            fail('file changed during verification (relative path base64): ' . b64($relative))
                unless $after[7] == $st[7] && $after[9] == $st[9];
        } else { return if $skip_special; fail('unsupported file type: ' . b64($path)); }
        push @entries, $entry;
        if ($entry->{type} eq 'directory') {
            opendir(my $dh, $path) or fail('cannot enumerate: ' . b64($path));
            my @names = sort grep { $_ ne '.' && $_ ne '..' } readdir($dh);
            closedir $dh;
            for my $name (@names) {
                next if $metadata && $relative eq '' && $name eq $manifest;
                $walk->("$path/$name", $relative eq '' ? $name : "$relative/$name");
            }
        }
    };
    $walk->($root, '');
    return \@entries;
}
sub read_all {
    my ($path) = @_;
    fail("metadata must be a regular file: $path") if -l $path || !-f $path;
    open(my $fh, '<:raw', $path) or fail("cannot open $path");
    local $/;
    my $content = <$fh>;
    close $fh or fail("cannot close $path");
    return $content;
}
sub structure {
    my ($root, @ids) = @_;
    fail('backup root must be a real directory') if -l $root || !-d $root;
    for my $name (qw(developer dotfiles ssh defaults extensions)) {
        fail("backup structural path must be a directory: $name")
            if present("$root/$name") && (-l "$root/$name" || !-d "$root/$name");
    }
    for my $id (@ids) {
        fail("AI data root must not be a symlink: $id") if -l "$root/developer/$id";
    }
}
my ($command, @args) = @ARGV;
defined $command or fail('missing command');
if ($command eq 'create' || $command eq 'verify') {
    my ($root) = @args;
    structure($root);
    if ($command eq 'verify' && !present("$root/$manifest") && !present("$root/$marker")) {
        print "WARNING: 舊版備份沒有校驗資訊，未驗證檔案完整性。\n";
        exit 0;
    }
    fail('missing/unsupported backup-format') unless read_all("$root/$marker") eq "mac-migration-v1\n";
    if ($command eq 'create') {
        my $data = {format => 'mac-migration', version => 1, algorithm => 'SHA-256',
                    path_encoding => 'base64-bytes', entries => inventory($root, 1)};
        $temporary = "$root/.manifest.tmp.$$";
        sysopen(my $out, $temporary, O_WRONLY | O_CREAT | O_EXCL, 0600) or fail('cannot create manifest');
        print {$out} $json->encode($data), "\n" or fail('cannot write manifest');
        close $out or fail('cannot close manifest');
        rename $temporary, "$root/$manifest" or fail('cannot publish manifest');
        undef $temporary;
        print "已建立版本化 SHA-256 檔案清單。\n";
    } else {
        my $data = eval { $json->decode(read_all("$root/$manifest")) };
        fail('invalid manifest JSON') unless ref($data) eq 'HASH';
        fail('unsupported manifest format/version') unless ($data->{format} // '') eq 'mac-migration'
            && ($data->{version} // '') eq '1' && ($data->{algorithm} // '') eq 'SHA-256'
            && ($data->{path_encoding} // '') eq 'base64-bytes' && ref($data->{entries}) eq 'ARRAY';
        # Compare a fresh inventory, never interpret untrusted paths as filesystem commands.
        fail('校驗失敗：缺檔、額外檔案、檔案內容或符號連結不符。')
            unless $json->encode($data->{entries}) eq $json->encode(inventory($root, 1));
        print "SHA-256／符號連結校驗通過。\n";
    }
} elsif ($command eq 'compare') {
    fail('staged copy differs from source') unless
        $json->encode(inventory($args[0], 0, 1)) eq $json->encode(inventory($args[1], 0, 1));
} elsif ($command eq 'disjoint') {
    disjoint(@args);
} elsif ($command eq 'backup-preflight') {
    my ($output, @sources) = @args;
    for my $src (@sources) {
        next unless -d $src;
        my ($out, $source) = (canonical($output), canonical($src));
        fail("拒絕備份自身：輸出位於來源內: $src -> $output") if within($out, $source);
    }
} elsif ($command eq 'structure') {
    structure(@args);
} elsif ($command eq 'destinations') {
    my ($root, $home, @destinations) = @args;
    my @resolved;
    for my $dest (@destinations) {
        fail("destination must be absolute: $dest") unless $dest =~ m{^/};
        fail("destination root must not be a symlink: $dest") if -l $dest;
        my $path = canonical($dest);
        fail("unsafe destination: $dest") if within(canonical($home), $path);
        disjoint($root, $dest);
        for my $other (@resolved) { disjoint($other, $path); }
        push @resolved, $path;
    }
} else { fail("unknown command: $command"); }
