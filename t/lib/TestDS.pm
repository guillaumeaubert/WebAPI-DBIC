package TestDS;

use Test::Most;
use Plack::Test;
use Test::HTTP::Response;
use JSON::MaybeXS;
use URI;
use Devel::Dwarn;
use Carp;
use autodie;

use parent 'Exporter';


our @EXPORT = qw(
    run_request_spec_tests
    url_query
    dsreq dsresp_json_data dsresp_ok dsresp_created_ok
    get_data
    is_item
);


$Carp::Verbose = 1;

$ENV{PLACK_ENV} ||= 'development'; # ensure env var is set

$| = 1;


sub _get_authorization_user_pass {
    return( $ENV{DBI_USER}||"", $ENV{DBI_PASS}||"" );
}


sub run_request_spec_tests {
    my ($app, $spec_fh, $spec_src) = @_;
    $spec_fh  ||= \*DATA;
    $spec_src ||= (caller(0))[1];

    my @tests = split /\n\n/, slurp($spec_fh);

    my ($test_volume,$test_directories,$test_file) = File::Spec->splitpath($spec_src);
    (my $got_file = $test_file) =~ s/\.t$/.got/ or die "panic: can't edit $test_file";
    (my $exp_file = $test_file) =~ s/\.t$/.exp/ or die "panic: can't edit $test_file";
    $got_file = File::Spec->catpath( $test_volume, $test_directories, $got_file );
    $exp_file = File::Spec->catpath( $test_volume, $test_directories, $exp_file );

    open my $fh, ">", $got_file;
    make_request_from_spec($app, $fh, $_) for @tests;
    close $fh;

    eq_or_diff slurp($got_file), slurp($exp_file),
            "$test_file output matches expectations"
        and unlink $got_file;
}


sub make_request_from_spec {
    my ($app, $fh, $spec) = @_;
    my ($name, $curl, @rest) = split /\n/, $spec;

    $name =~ s/^NAME:\s+//i
        or die "'$name' doesn't begin with NAME:\n";
    $curl =~ s/^(GET|PUT|POST|DELETE|OPTIONS)\s//
        or die "'$curl' doesn't begin with GET, PUT, POST etc\n";
    my $method = $1;

    my (@headers, @header_names);
    while (@rest && $rest[0] =~ /^([-\w]+):\s+(.*)/) {
        push @headers, $1, $2;
        push @header_names, $1;
        shift @rest;
    }

    my $json = join '', @rest;
    my $data = (length $json) && JSON->new->decode($json);
    test_psgi $app, sub {
        printf $fh "=== %s\n", $name;

        my $req = dsreq( $method => $curl, \@headers, $data );
        my $res = shift->($req);

        printf $fh "Request:\n";
        printf $fh "%s %s\n", $method, $curl;
        printf $fh "%s: %s\n", $_, scalar $req->headers->header($_) for @header_names;
        printf $fh "%s\n", $json if length $json;

        printf $fh "Response:\n";
        note $res->headers->as_string;
        printf $fh "%s %s\n", $res->code, $res->message;
        for my $header ('Content-type') { # headers that are of interest
            printf $fh "%s: %s\n", $header, scalar $res->header($header);
        }
        if (my $content = $res->content) {
            if ($res->headers->content_type =~ /json/) {
                my $data = JSON->new->decode($content); # may throw exception
                $content = JSON->new->ascii->pretty->canonical->encode($data);
            }
            printf $fh "%s\n", $content;
        }
    };

    return;
}


sub slurp {
    my ($file) = @_;
    my $fh = (ref $file eq 'GLOB') && $file;
    open($fh, "<", $file) unless $fh;
    return do { local $/; <$fh> };
}


sub url_query {
    my ($url, %params) = @_;
    $url = URI->new( $url, 'http' );
    # encode any reference param values as JSON
    ref $_ and $_ = JSON->new->ascii->encode($_)
        for values %params;
    $url->query_form(%params);
    return $url;
}


sub dsreq {
    my ($method, $uri, $headers, $data) = @_;

    $headers = HTTP::Headers->new(@{$headers||[]});
    $headers->init_header('Content-Type' => 'application/json')
        unless $headers->header('Content-Type');
    $headers->init_header('Accept' => 'application/json')
        unless $headers->header('Accept');
    $headers->authorization_basic(_get_authorization_user_pass())
        unless $headers->header('Authorization');

    my $content;
    if ($data) {
        $content = JSON->new->pretty->encode($data);
    }
    note("$method $uri");
    my $req = HTTP::Request->new($method => $uri, $headers, $content);
    note $req->as_string if $ENV{WEBAPI_DBIC_DEBUG};
    return $req;
}

sub dsresp_json_data {
    my ($res) = @_;
    return undef unless $res->header('Content-type') =~ qr{^application/(?:hal\+)?json$};
    return undef unless $res->header('Content-Length');
    my $content = $res->content;
    my $data = JSON->new->decode($content);
    ok ref $data, 'response is a ref'
        or diag $content;
    return $data;
}

sub dsresp_ok {
    my ($res, $expect_status) = @_;
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    #diag $res->as_string;
    status_matches($res, $expect_status || 200)
        or diag $res->as_string;
    my $data;
    $res->header('Content-type')
        and $data = dsresp_json_data($res);
    return $data;
}

sub dsresp_created_ok {
    my ($res) = @_;
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    status_matches($res, 201)
        or diag $res->as_string;
    my $location = $res->header('Location');
    ok $location, 'has Location header';
    my $data = dsresp_json_data($res);
    return $location unless wantarray;
    return ($location, $data);
}


sub is_error {
    my ($data, $attributes) = @_;
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    is ref $data, 'HASH', "data isn't a hash";
    cmp_ok scalar keys %$data, '>=', $attributes, "set has less than $attributes attributes"
        if defined $attributes;
    return $data;
}


sub is_item {
    my ($data, $attributes) = @_;
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    is ref $data, 'HASH', "data isn't a hash";
    cmp_ok scalar keys %$data, '>=', $attributes, "set has less than $attributes attributes"
        if $attributes;
    return $data;
}


sub get_data {
    my ($app, $url) = @_;
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    my $data;
    test_psgi $app, sub { $data = dsresp_ok(shift->(dsreq( GET => $url ))) };
    return $data;
}

1;
