package Koha::Plugin::Com::BibLibre::LLMSearch;

## It's good practice to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);
use Template;
use Mojo::JSON qw(decode_json);

use Koha::DateUtils qw( dt_from_string );

## Here we set our plugin version
our $VERSION = "1.2";
our $MINIMUM_VERSION = "23.11";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'LLM Search',
    author          => 'A. Suzuki',
    date_authored   => '2025-05-26',
    date_updated    => "2026-09-23",
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
    description     => 'Brings a new way to query koha in natural language using LLM assistant',
    namespace       => 'llmsearch',
};

## This is the minimum code required for a plugin's 'new' method
## More can be added, but none should be removed
sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

sub install {
    my ( $self, $args ) = @_;
    my $table = $self->get_qualified_table_name('stats');
    warn "Install LLMSEARCH";
    return C4::Context->dbh->do("
           CREATE TABLE IF NOT EXISTS $table (
               id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
               timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
               categorycode VARCHAR(10),
               branchcode VARCHAR(10),
               enrolled_year YEAR,
               birth_year YEAR,
               sort1 VARCHAR(80),
               sort2 VARCHAR(80),
               opac_lang VARCHAR(10),
               tokens_sent INT UNSIGNED,
               tokens_received INT UNSIGNED
               ) ENGINE=InnoDB;
               ");
}

sub upgrade {
    my ( $self, $args ) = @_;

    my $dt = dt_from_string();
    $self->store_data( { last_upgraded => $dt->ymd('-') . ' ' . $dt->hms(':') } );

    return 1;
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    my $default_welcome = "Hello! I am the library bot and I'll do my best to assist you in your research!";
    my $defaults = { base_url                 => 'https://api.mistral.ai/v1/chat/completions',
                     api_key                  => '',
                     model                    => 'mistral-small-latest',
                     welcome                  => $default_welcome,
                     system_prompt            => '',
                     is_public                => 0,
                     allowed_cat              => '',
                     enable_stats             => 0,
                     max_tool_rounds          => 5,
                     debug_mode               => 0,
    };

    unless ($cgi->param('save')) {
        my $template = $self->get_template({ file => 'configure.tt' });
        foreach my $key (keys %$defaults) {
            my $param_value = $self->retrieve_data($key);
            if (defined $param_value) {
                $template->param($key => $param_value);
            }
            else {
                $template->param($key => $defaults->{$key});
            }
        }
        $self->output_html( $template->output() );
    }
    else {
        my $config = { %$defaults };
        foreach my $key (keys %$defaults) {
            my $param_value = $cgi->param($key);
            if (defined $param_value) {
                $config->{$key} = $param_value;
            }
        }
        $self->store_data( $config );
        $self->store_data({last_configured_by => C4::Context->userenv->{'number'}});
        $self->go_home();
    }
}

sub is_allowed {
    my ( $self ) = @_;
    return 1 if $self->retrieve_data('is_public') eq 'on';
    
    my $borrowernumber = C4::Context->userenv->{'number'} // 0;
    return 0 unless $borrowernumber;

    my $allowed_cat = $self->retrieve_data('allowed_cat');
    return 1 unless $allowed_cat;

    my $patron = Koha::Patrons->find($borrowernumber)->unblessed();
    foreach my $category (split(' ', $allowed_cat)) {
        return 1 if $category eq $patron->{categorycode};
    }

    return 0;
}

sub opac_js {
    my ( $self ) = @_;
    warn "is_allowed: " . $self->is_allowed();
    return '' unless $self->is_allowed();
    return '<script src="https://cdn.jsdelivr.net/npm/dompurify/dist/purify.min.js"></script>'
        . '<script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>'
        . '<script>' . $self->mbf_read('chat.js') . '</script>';
}

sub opac_head {
    my ( $self ) = @_;
    warn "is_allowed: " . $self->is_allowed();
    return '' unless $self->is_allowed();
    return '<style>' . $self->mbf_read('chat.css') . '</style>';
}

sub api_routes {
    my ( $self, $args ) = @_;
    my $spec_str;
    $spec_str = $self->mbf_read('openapi.json');
    my $spec = decode_json($spec_str);
    return $spec;
}

sub static_routes {
    my ( $self, $args ) = @_;

    my $spec_str = $self->mbf_read('staticapi.json');
    my $spec     = decode_json($spec_str);

    return $spec;
}

sub api_namespace {
    my ( $self ) = @_;
    return 'llmsearch';
}
1;
