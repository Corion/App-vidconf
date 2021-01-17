#!perl
use strict;
use warnings;
use 5.012;
use Getopt::Long;
use WWW::Mechanize::Chrome;
use WWW::Mechanize::Chrome::URLBlacklist;
use Log::Log4perl ':easy';
use File::Temp 'tempdir';
use File::Path;

Log::Log4perl->easy_init($ERROR);
#Log::Log4perl->easy_init($DEBUG);

GetOptions(
    'm|meeting-id=s' => \my $meeting_id,
    'n|name=s'       => \my $name,
);


sub camera_is_available() {
}

sub camera_is_recording() {
}

my %conf = (
    camera_device_plugin => [],
    camera_setup => [
        "gio mount -u gphoto2://Canon_Inc._Canon_Digital_Camera/",
        "gphoto2 --stdout --capture-movie | ffmpeg -i - -vcodec rawvideo -pix_fmt yuv420p -threads 0 -f v4l2 /dev/video0",
    ],
);

my $d = tempdir(CLEANUP => 1 );
my $profile = "$d/profile/test1";
mkpath $profile;
my $mech = WWW::Mechanize::Chrome->new(
    headless => 0,
    data_directory => $d,
    profile => $profile,
    enable_first_run => 1,
    mute_audio => 0,
);

my $bl = WWW::Mechanize::Chrome::URLBlacklist->new(
    blacklist => [
        qr!\bgoogleadservices\b!,
        qr!^https://telemetry.servers.getgo.com/!,
    ],
    whitelist => [
        qr!^https://global.gotomeeting.com/!,
        qr!^https://weblibrary.cdn.getgo.com/!,
        qr!^https://join.gotomeeting.com/!,
        qr!^https://app.gotomeeting.com/!,
        qr!^https://authentication.logmeininc.com/!,
        qr!^https://apiglobal.gotomeeting.com/!,
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

$mech->get("https://global.gotomeeting.com/join/$meeting_id");

$mech->wait_until_visible(xpath => '//*[@role="radio" and @value="voip"]');

# Select voip as input method (instead of pstn dial-in)
$mech->click({ xpath => '//*[@role="radio" and @value="voip"]' });

# Continue
$mech->click({ xpath => '//button' });

# Select microphone and speakers, later
$mech->sleep(1);

# Continue
say "Waiting for default mic and speakers";
$mech->wait_until_visible(xpath => '//button[text() = "Save and continue"]');
say "Clicking default mic and speakers";
$mech->click({ xpath => '//button[text() = "Save and continue"]', first => 1 });

# There are some redirects maybe before the "please wait" screen
$mech->sleep(2);

# Check/loop whether the meeting is open yet
my $notopen = '//h2[starts-with(text(),"Waiting for ")]';
while( my @wait = $mech->xpath( $notopen )) {
    say "Waiting for meeting to open";
    $mech->wait_until_invisible(xpath => $notopen, max_wait => 5);
};

# Now, enter our name, etc. - this is not yet implemented

# Now, set up camera
# Then, click on @data-automation-id="button-settings"
# Then, click on button[@id="video-tab"]
# Then, click on div[ @data-automation-id="panel-webcam"] toi enable/disable the webcam

my $received = $mech->target->add_listener('Network.webSocketFrameReceived', sub {
    my $d = $_[0]->{params}->{response}->{payloadData};
    use Data::Dumper;
    warn $d;
});

# Consider entering chat via the console?!


while(1) {
    $mech->sleep(60);
};
