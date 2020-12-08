#!perl
use strict;
use warnings;
use Getopt::Long;
use WWW::Mechanize::Chrome;
use WWW::Mechanize::Chrome::URLBlacklist;
use Log::Log4perl ':easy';
use File::Temp 'tempdir';
use File::Path;

Log::Log4perl->easy_init($ERROR);

GetOptions(
    'm|meeting-id=s' => \my $meeting_id,
    'n|name=s'       => \my $name,
);

my $d = tempdir(CLEANUP => 1 );
my $profile = "$d/profile/test1";
mkpath $profile;
my $mech = WWW::Mechanize::Chrome->new(
    headless => 0,
    data_directory => $d,
    profile => $profile,
    enable_first_run => 1,
);

my $bl = WWW::Mechanize::Chrome::URLBlacklist->new(
    blacklist => [
        qr!\bgoogleadservices\b!,
        qr!^\Qchrome-extension://invalid/!,
        qr!^\Qhttps://api.amplitude.com/!,
        qr!^\Qhttps://api.callstats.io/!,
    ],
    whitelist => [
        qr!\bmeet\.jit\.si\b!,
        qr!\bweb-cdn.jitsi.net\b!,
    ],

    # fail all unknown URLs
    default => 'failRequest',
    # allow all unknown URLs
    # default => 'continueRequest',

    on_default => sub {
        warn "*** Ignored URL $_[0] (action was '$_[1]')",
    },
);
$bl->enable($mech);

$mech->target->send_message('Browser.grantPermissions',
    permissions => ['videoCapture','audioCapture'],
)->get;

$mech->get("https://meet.jit.si/$meeting_id");

$mech->sleep(1);

my $name_field = $mech->selector( 'div.prejoin-input-area input', one => 1 );
$mech->set_field( field => $name_field, value => $name );
$mech->sleep(0.1);
$mech->click({ selector => '//*[@data-testid="prejoin.joinMeeting"]' });

$mech->sleep(1);
$mech->click({ selector => '.chrome-extension-banner__close-container' });

#$mech->sleep(10);

my $window_info = $mech->target->send_message('Browser.getWindowForTarget')->get;
#use Data::Dumper; warn Dumper $window_info;

$mech->target->send_message('Browser.setWindowBounds',
    windowId => $window_info->{windowId},
    bounds => {
        'height' => 1600,
        'top' => 0,
        'width' => 2560,
        'left' => 0,
    },
)->get;
$mech->target->send_message('Browser.setWindowBounds',
    windowId => $window_info->{windowId},
    bounds => {
        windowState => 'fullscreen',
    },
)->get;

my $received = $mech->target->add_listener('Network.webSocketFrameReceived', sub {
    my $d = $_[0]->{params}->{response}->{payloadData};
    use Data::Dumper;
    warn d;
});

# Consider entering chat via the console?!


while(1) {
    $mech->sleep(60);
};
