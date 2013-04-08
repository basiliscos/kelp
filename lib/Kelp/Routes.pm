package Kelp::Routes;

use Carp;

use Kelp::Base;
use Kelp::Routes::Pattern;

attr base   => '';
attr routes => [];
attr cache  => {};
attr names  => {};

sub add {
    my ( $self, $pattern, $descr ) = @_;
    $self->_parse_route( {}, $pattern, $descr );
}

sub clear {
    $_[0]->routes( [] );
    $_[0]->cache(  {} );
    $_[0]->names(  {} );
}

sub _camelize {
    my ( $string, $base ) = @_;
    return $string unless $string;
    my @parts = split( /\#/, $string );
    my $sub = pop @parts;
    @parts = map {
        join '', map { ucfirst lc } split /\_/
    } @parts;
    unshift @parts, $base if $base;
    return join( '::', @parts, $sub );
}

sub _parse_route {
    my ( $self, $parent, $key, $val ) = @_;

    # Scalar, e.g. path => 'bar#foo'
    # CODE, e.g. path => sub { ... }
    if ( !ref($val) || ref($val) eq 'CODE' ) {
        $val = { to => $val };
    }

    # Sanity check
    if ( ref($val) ne 'HASH' ) {
        carp "Route description must be a SCALAR, CODE or HASH. Skipping.";
        return;
    }

    # 'to' is required
    if ( !exists $val->{to} ) {
        carp "Route is missing destination. Skipping.";
        return;
    }

    # Format destination
    if ( !ref $val->{to} ) {
        $val->{to} = _camelize( $val->{to}, $self->base );
    }

    # Handle the value part
    if ( ref($key) eq 'ARRAY' ) {
        my ( $method, $pattern ) = @$key;
        if ( !grep { $method eq $_ } qw/GET POST PUT DELETE/ ) {
            carp "Using an odd method: $method";
        }
        $val->{via} = $method;
        $key = $pattern;
    }

    # Only SCALAR and Regexp allowed
    if ( ref($key) && ref($key) ne 'Regexp' ) {
        carp "Pattern $key can not be computed.";
        return;
    }

    $val->{pattern} = $key;

    my $tree;
    if ( $tree = delete $val->{tree} ) {
        if ( ref($tree) ne 'ARRAY' ) {
            carp "Tree must be an ARRAY. Skipping.";
            $tree = undef;
        }
        else {
            $val->{bridge} = 1;
        }
    }
    $tree //= [];

    # Parrent defined?
    if (%$parent) {
        if ( $parent->{name} ) {
            $val->{name} = $parent->{name} . '_' . $val->{name};
        }
        $val->{pattern} = $parent->{pattern} . $val->{pattern};
    }

    # Create pattern object
    push @{ $self->routes }, Kelp::Routes::Pattern->new(%$val);

    # Add route index to names
    if ( my $name = $val->{name} ) {
        if ( exists $self->names->{$name} ) {
            carp "Redefining route name $name";
        }
        $self->names->{$name} = scalar( @{ $self->routes } ) - 1;
    }

    while (@$tree) {
        my ( $k, $v ) = splice( @$tree, 0, 2 );
        $self->_parse_route( $val, $k, $v );
    }
}

sub url {
    my $self = shift;
    my $name = shift // croak "Route name is missing";
    my %args = @_ == 1 ? %{ $_[0] } : @_;

    return $name unless exists $self->names->{$name};
    my $route = $self->routes->[ $self->names->{$name} ];
    return $route->build(%args);
}

sub match {
    my ( $self, $path, $method ) = @_;

    # Look for this path and method in the cache. If found,
    # return the array of routes that matched the previous time.
    # If not found, then returl all routes.
    my $key = $path . ':' . ( $method // '' );
    my $routes =
      exists $self->cache->{$key}
      ? $self->cache->{$key}
      : $self->routes;

    # Look through all routes, grep the ones that match
    # and sort them by 'bridge' and 'pattern'
    my @processed =
      sort { $b->bridge <=> $a->bridge || $a->pattern cmp $b->pattern }
      grep { $_->match( $path, $method ) } @$routes;

    return $self->cache->{$key} = \@processed;
}

1;

__END__

=pod

=head1 NAME

Kelp::Routes - Routing for a Kelp app

=head1 SYNOPSIS

    my $r = Kelp::Routes->new( base => 'MyApp' );

    # Simple
    $r->add( '/home', 'home' );

    # With method
    $r->add( [ POST => '/item' ], 'items#add' );

    # Captures
    $r->add( '/user/:id',     'user#view' );       # Required
    $r->add( '/pages/?id',    'pages#view' );      # Optional
    $r->add( '/*article/:id', 'articles#view' );   # Wildcard

    # Extended options
    $r->add(
        '/resource/:id' => {
            via   => 'GET',               # match only GET
            to    => 'resources#view',    # send to MyApp::Resources::View
            check => { id => '\d+' },     # match only id =~ /\d+/
            name  => 'resource'           # name this route 'resource'
        }
    );

    # URL building
    say $r->url( 'resource', id => 100 );    # '/resource/100'

    # Bridges
    $r->add(
        '/users', {
            to     => 'users#auth',
            bridge => 1
        }
    );
    $r->add( '/users/edit' => 'user#edit' );
    # Will go through the bridge code first

    # Nested routes and bridges
    $r->add(
        '/users' => {
            to   => 'users#auth',
            tree => [
                '/home' => 'users#home',
                [ POST => '/edit' ] => 'users#edit',
                '/prefs' => {
                    to   => 'users#prefs',
                    tree => [
                        '/email' => 'users#prefs#email',
                        '/login' => 'users#prefs#login'
                    ]
                }
            ]
        }
    );

=head1 DESCRIPTION

Routing is at the core of each web application. It provides the connection
between each HTTP request and the code.

Kelp provides a simple, yet sophisticated router. It utilizes Perl 5.10's
regular expressions, which makes it fast, robust and reliable.

The routing process can roughly be broken down into three steps:

=over

=item B<Adding routes>

First you create a router object:

    my $r = Kelp::Routes->new();

Then you add your application's routes and their descriptions:

    $r->add( '/path' => 'Module::function' );
    ...

=cut

=item B<Matching>

Once you have your routes added, you can match with the L</match> subroutine.

    $r->match( $path, $method );

The Kelp framework already does matching for you, so you may never
have to do your own matching. The above example is provided only for
reference.

=cut

=item B<Building URLs from routes>

You can name each of your routes and use that later to build a URL:

    $r->add( '/begin' => { to => 'function', name => 'home' } );
    my $url = $r->url('home');    # /begin

This can be used in views and other places where you need the full URL of
a route.

=cut

=back

=head1 PLACEHOLDERS

Each route is matched via a regular expression. You can write your own regular
expressions or you can use Kelp's I<placeholders>. Placeholders are variables
you place in the route path. They are identified by a prefix character and
their names must abide to the rules of a regular Perl variable. If necessary,
curly braces can be used to separate placeholders from the rest of the path.

There are three types of place holders: explicit, optional and wildcards.

=head2 Explicit

These placeholders begin with a column (C<:>) and must have a value in order for the
route to match. All characters are matched, except for the forward slash.

    $r->add( '/user/:id' => 'module#sub' );
    # /user/a       -> match (id = 'a')
    # /user/123     -> match (id = 123)
    # /user/        -> no match
    # /user         -> no match
    # /user/10/foo  -> no match

    $r->add( '/page/:page/line/:line' => 'module#sub' );
    # /page/1/line/2        -> match (page = 1, line = 2)
    # /page/bar/line/foo    -> match (page = 'bar', line = 'foo')
    # /page/line/4          -> no match
    # /page/5               -> no match

    $r->add( '/{:a}ing/{:b}ing' => 'module#sub' );
    # /walking/singing      -> match (a = 'walk', b = 'sing')
    # /cooking/ing          -> no match
    # /ing/ing              -> no match

=head2 Optional

Optional placeholders begin with a question mark C<?> and denote an optional
value. You may also specify a default value for the optional placeholder via
the L</defaults> option. Again, like the explicit placeholders, the optional
ones capture all characters, except the forward slash.

    $r->add( '/data/?id' => 'module#sub' );
    # /bar/foo          -> match ( id = 'foo' )
    # /bar/             -> match ( id = undef )
    # /bar              -> match ( id = undef )

    $r->add( '/:a/?b/:c' => 'module#sub' );
    # /bar/foo/baz      -> match ( a = 'bar', b = 'foo', c = 'baz' )
    # /bar/foo          -> match ( a = 'bar', b = undef, c = 'foo' )
    # /bar              -> no match
    # /bar/foo/baz/moo  -> no match

Optional default values may be specified via the C<defaults> option.

    $r->add(
        '/user/?name' => {
            to       => 'module#sub',
            defaults => { name => 'hank' }
        }
    );

    # /user             -> match ( name = 'hank' )
    # /user/            -> match ( name = 'hank' )
    # /user/jane        -> match ( name = 'jane' )
    # /user/jane/cho    -> no match

=head2 Wildcards

The wildcard placeholders expect a value and capture all characters, including
the forward slash.

    $r->add( '/:a/*b/:c'  => 'module#sub' );
    # /bar/foo/baz/bat  -> match ( a = 'bar', b = 'foo/baz', c = 'bat' )
    # /bar/bat          -> no match

=head2 Using curly braces

Curly braces may be used to separate the placeholders from the rest of the
path:

    $r->add( '/{:a}ing/{:b}ing' => 'module#sub' );
    # /looking/seeing       -> match ( a = 'look', b = 'see' )
    # /ing/ing              -> no match

    $r->add( '/:a/{?b}ing' => 'module#sub' );
    # /bar/hopping          -> match ( a = 'bar', b = 'hopp' )
    # /bar/ing              -> match ( a = 'bar' )
    # /bar                  -> no match

    $r->add( '/:a/{*b}ing/:c' => 'module#sub' );
    # /bar/hop/ping/foo     -> match ( a = 'bar', b = 'hop/p', c = 'foo' )
    # /bar/ing/foo          -> no match

=head1 BRIDGES

The L</match> subroutine will stop and return the route that best matches the
specified path. If that route is marked as a bridge, then L</match> will
continue looking for a match and will eventually return an array of one or
more routes. Bridges can be used for authentication or other route
preprocessing.

    $r->add( '/users', { to => 'Users::auth', bridge => 1 } );
    $r->add( '/users/:action' => 'Users::dispatch' );

The above example will require F</users/profile> to go through two
controllers: C<Users::auth> and C<Users::dispatch>:

    my $arr = $r->match('/users/view');
    # $arr is an array of two routes now, the bridge and the last one matched

=head1 TREES

A quick way to add bridges is to use the L</tree> option. It allows you to
define all routes under a bridge. Example:

    $r->add(
        '/users' => {
            to   => 'users#auth',
            name => 'users',
            tree => [
                '/profile' => {
                    name => 'profile',
                    to   => 'users#profile'
                },
                '/settings' => {
                    name => 'settings',
                    to   => 'users#settings',
                    tree => [
                        '/email' => { name => 'email', to => 'users#email' },
                        '/login' => { name => 'login', to => 'users#login' }
                    ]
                }
            ]
        }
    );

The above call to C<add> causes the following to occur under the hood:

=over

=item *

The paths of all routes inside the tree are joined to the path of their
parent, so the following five new routes are created:

    /users                  -> MyApp::Users::auth
    /users/profile          -> MyApp::Users::profile
    /users/settings         -> MyApp::Users::settings
    /users/settings/email   -> MyApp::Users::email
    /users/settings/login   -> MyApp::Users::login

=item *

The names of the routes are joined with C<_> to the name of their parent:

    /users                  -> 'users'
    /users/profile          -> 'users_profile'
    /users/settings         -> 'users_settings'
    /users/settings/email   -> 'users_settings_email'
    /users/settings/login   -> 'users_settings_login'

=item *

The C</users> and C</users/settings> routes are automatically marked as
bridges, because they contain a tree.

=back

=head1 ATTRIBUTES

=head2 base

Sets the base class for the routes destinations.

    my $r = Kelp::Routes->new( base => 'MyApp' );

This will prepend C<MyApp::> to all route destinations.

    $r->add( '/home' => 'home' );          # /home -> MyApp::home
    $r->add( '/user' => 'user#home' );     # /user -> MyApp::User::home
    $r->add( '/view' => 'User::view' );    # /view -> MyApp::User::view

By default this value is an empty string and it will not prepend anything.
However, if it is set, then it will always be used. If you need to use
a route located in another package, you'll have to wrap it in a local sub:

    # Problem:

    $r->add( '/outside' => 'Outside::Module::route' );
    # /outside -> MyApp::Outside::Module::route
    # (most likely not what you want)

    # Solution:

    $r->add( '/outside' => 'outside' );
    ...
    sub outside {
        return Outside::Module::route;
    }

=head1 SUBROUTINES

=head2 add

Adds a new route definition to the routes array.

    $r->add( $path, $destination );

C<$path> can be a path string, e.g. C<'/user/view'> or an ARRAY containing a
method and a path, e.g. C<[ PUT =E<gt> '/item' ]>.

C<$destination> can be a destination string, e.g. C<'Users::item'>, a hash
containing more options or a CODE reference:

    my $r = Kelp::Routes->new( base => 'MyApp' );

    # /home -> MyApp::User::home
    $r->add( '/home' => 'user#home' );

    # GET /item/100 -> MyApp::Items::view
    $r->add(
        '/item/:id', {
            to  => 'items#view',
            via => 'GET'
        }
    );

    # /system -> CODE
    $r->add( '/system' => sub { return \%ENV } );

=head3 Destination Options

=head4 to

Sets the destination for the route. It should be a subroutine name or CODE
reference. It could also be a shortcut, in which case it will get properly
camelized.

    $r->add( '/user' => 'users#home' );       # /home -> MyApp::Users::home
    $r->add( '/sys'  => sub { ... } );        # /sys -> execute code
    $r->add( '/item' => 'Items::handle' );    # /item -> MyApp::Items::handle
    $r->add( '/item' => { to => 'Items::handle' } );    # Same as above

=head4 via

Specifies an HTTP method to be considered by L</match> when matching a route.

    # POST /item -> MyApp::Items::add
    $r->add(
        '/item' => {
            via => 'POST',
            to  => 'items#add'
        }
    );

The above can be shortened with like this:

    $r->add( [ POST => '/item' ] => 'items#add' );

=head4 name

Give the route a name, that can be used to build a URL later via the L</url>
subroutine.

    $r->add(
        '/item/:id/:name' => {
            to   => 'items#view',
            name => 'item'
        }
    );

    # Later
    $r->url( 'item', id => 8, name => 'foo' );    # /item/8/foo

=head4 check

A hashref of checks to perform on the captures. It should contain capture
names and stringified regular expressions. Do not use C<^> and C<$> to denote
beginning and ending of the matched expression, because it will get embedded
in a bigger Regexp.

    $r->add(
        '/item/:id/:name' => {
            to    => 'items#view',
            check => {
                id   => '\d+',          # id must be a digit
                name => 'open|close'    # name can be 'open' or 'close'
            }
          }
    );

=head4 defaults

Set default values for optional placeholders.

    $r->add(
        '/pages/?id' => {
            to       => 'pages#view',
            defaults => { id => 2 }
        }
    );

    # /pages    -> match ( id = 2 )
    # /pages/   -> match ( id = 2 )
    # /pages/4  -> match ( id = 4 )

=head4 bridge

If set to one this route will be treated as a bridge. Please see L</bridges>
for more information.

=head4 tree

Creates a tree of sub-routes. See L</trees> for more information and examples.

=head2 match

Returns an array of L<Kelp::Routes::Pattern> objects that match the path
and HTTP method provided. Each object will contain a hash with the named
placeholders in L<Kelp::Routes::Pattern/named>, and an array with their
values in the order they were specified in the pattern in
L<Kelp::Routes::Pattern/param>.

    $r->add( '/:id/:name', "route" );
    for my $pattern ( @{ $r->match('/15/alex') } ) {
        $pattern->named;    # { id => 15, name => 'alex' }
        $pattern->param;    # [ 15, 'alex' ]
    }

Routes that used regular expressions instead of patterns will only initialize
the C<param> array with the regex captures, unless those patterns are using
named captures in which case the C<named> hash will also be initialized.

=head1 SEE ALSO

L<Kelp>, L<Routes::Tiny>, L<Forward::Routes>

=head1 CREDITS

Author: Stefan Geneshky - minimal@cpan.org

=head1 ACKNOWLEDGEMENTS

This module was inspired by L<Routes::Tiny>.

The concept of bridges was borrowed from L<Mojolicious>

=head1 LICENSE

Same as Perl itself.

=cut