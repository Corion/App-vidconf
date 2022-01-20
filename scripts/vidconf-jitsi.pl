#!perl
use strict;
use warnings;
use Getopt::Long;
use IO::Async;
use Tickit::Async;
use WWW::Mechanize::Chrome;
use WWW::Mechanize::Chrome::URLBlacklist;
use Log::Log4perl ':easy';
use File::Temp 'tempdir';
use File::Path;

use feature 'signatures';
no warnings 'experimental';

use Tickit; # well, later we might move this prerequisite somewhere else
use Tickit::Widget::Box;
use Tickit::Console;
use Tickit::Widget::Static;
use Tickit::Widget::VBox;
use Tickit::Widget::Statusbar;
use Tickit::Widget::FloatBox;

Log::Log4perl->easy_init($WARN);

GetOptions(
    'm|meeting-id=s' => \my $meeting_id,
    'n|name=s'       => \my $name,
    'c|camera=s'       => \my $camera_name,
);

my %conf = (
    #camera_name          => qr/^Dummy video device/,
    #v4l2-ctl --list-devices , grep for that name
    camera_device_plugin => [],
    camera_ready_test => [],
    camera_model => 'Canon EOS 5D Mark II',
    camera_setup => [
        "gio mount -u gphoto2://Canon_Inc._Canon_Digital_Camera/",
        # 'gphoto2 --stdout --capture-movie | ffmpeg -i - -vcodec rawvideo -pix_fmt yuv420p -threads 0 -f v4l2 /dev/video0',
        'gphoto2 --camera ${camera_model} --stdout --capture-movie | ffmpeg -i - -vcodec rawvideo -pix_fmt yuv420p -threads 0 -f v4l2 /dev/video0',
    ],
);

#sub prepare_camera( $conf ) {
#    my %devices;
#    my $last_device;
#    for (`v4l2-ctl --list-devices`) {
#        if( /^(\S.+)/ ) {
#            $last_device = $1;
#            $devices[ $last_device ] = [];
#        }
#        if( /^\s+(.*)/ ) {
#            push @{$devices[ $last_device ]}, $1;
#        };
#    };
#}

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
        qr!^\Qchrome-extension://invalid/!,
        qr!^\Qhttps://api.amplitude.com/!,
        qr!^\Qhttps://api.callstats.io/!,
    ],
    whitelist => [
        qr!\bmeet\.jit\.si\b!,
        qr!\bweb-cdn.jitsi.net\b!,
        qr!\byoutube\b!,
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

my @chat;
my $chat_scrollback = 3000;

my $tickit;

my $console = Tickit::Console->new(
    timestamp_format => String::Tagged->new_tagged( "%H:%M ", fg => undef )
        ->apply_tag( 0, 5, fg => "hi-blue" ),
    datestamp_format => String::Tagged->new_tagged( "-- day is now %Y/%m/%d --",
        fg => "grey" ),
    on_line => sub( $tab, $text ) {
        $text =~ s!\s$!!;
        if( $text eq 'q' ) {
            $tickit->stop;
            undef $tickit;
        };
    },
);

# This window setup is basically taken from App::MatrixClient
sub new_room_tab( $console, $meeting_id ) {
    my ($headline,$floatbox);
    my $room_tab = $console->add_tab(
      name => $meeting_id,
      make_widget => sub {
         my ( $scroller ) = @_;

         my $vbox = Tickit::Widget::VBox->new;

         $vbox->add( $headline = Tickit::Widget::Static->new(
               text => $meeting_id,
               style => { bg => "blue" },
            ),
            expand => 0
         );
         $vbox->add( $scroller, expand => 1 );

         my $fb = Tickit::Widget::FloatBox->new();
         $fb->set_base_child( $vbox );
         return $fb;
      },
      #on_line => sub {
      #   my ( $tab, $line ) = @_;
      #   if( $line =~ s{^/}{} ) {
      #      my ( $cmd, @args ) = split m/\s+/, $line;
      #      if( my $code = $tab->can( "cmd_$cmd" ) ) {
      #         $room->adopt_future( $tab->$code( @args ) );
      #      }
      #      else {
      #         $self->do_command( $line, $tab );
      #      }
      #   }
      #   else {
      #      $room->adopt_future( $room->send_message( $line ) );
      #      $room->typing_stop;
      #   }
      #},
   );
}

my $typing_line; # status, currently unused

sub add_chat( $user, $line ) {
    my $tab = $console->active_tab;
    if( $typing_line ) {
        my @after = $console->{scroller}->pop;
        $tab->append_line( $line );
        $tab->{scroller}->push( @after );
    }
    else {
        $tab->append_line( $line );
    }
}

my $received = $mech->target->add_listener('Network.webSocketFrameReceived', sub {
    my $d = $_[0]->{params}->{response}->{payloadData};
    use Data::Dumper;
    my $t = Dumper $d;

    # Baaad XML parsing :-)
    # <message type=\'groupchat\' to=\'b54b8218-350c-44f3-9dd5-1e9c31bf14a3@meet.jit.si/747lP2Ty\' from=\'test12345-max@conference.meet.jit.si/b54b8218\'
    # xmlns=\'jabber:client\'><body>bbb</body><nick xmlns=\'http://jabber.org/protocol/nick\'>Max</nick></message>
    if( $d =~ m!^<message[^>]+><body>(.*?)</body><nick[^>]*>([^<]+)</nick>!s ) {
        add_chat($2,$1);
    } else {
        add_chat('???', $t);
    };
});

# Consider entering chat via the console?!

$tickit = Tickit::Async->new(
    root => $console,
    use_altscreen => 0,
);

my $loop = IO::Async::Loop->new;
$loop->add( $tickit );

new_room_tab($console, $meeting_id);

#$tickit->bind_key( 'q', sub {
#    $tickit->stop;
#    undef $tickit;
#});

$tickit->run;
#while(1) {
#    $mech->sleep(60);
#};
