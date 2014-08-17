package WebAPI::DBIC::Router;

=head1 NAME

WebAPI::DBIC::Router - Route URL paths to resources

=head1 DESCRIPTION

This is currently a wrapper for L<Path::Router>.

The intention is to allow support for other routers.

=cut

use Moo;

use Carp qw(croak);

use Path::Router;
use Plack::App::Path::Router;


has router => (
    is => 'ro',
    default => sub { Path::Router->new },
);


sub add_route {
    my ($self, %args) = @_;

    my $path        = delete $args{path};
    my $validations = delete $args{validations} || {};
    my $defaults    = delete $args{defaults}    || {};
    my $target      = delete $args{target}      or croak "target not specified";
    croak "Unknown params (@{[ sort keys %args ]})" if %args;

    $self->router->add_route($path,
        validations => $validations,
        defaults => $defaults,
        target => $target,
    );
}


sub to_psgi_app {
    my $self = shift;
    return Plack::App::Path::Router->new( router => $self->router )->to_app; # return Plack app
}


sub uri_for { # called by WebAPI::DBIC::Resource::Role::Router
    return shift->router->uri_for(@_);
}


1;
