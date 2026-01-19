#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <AppKit/AppKit.h>
#include <pwd.h>

#import "metal_renderer.h"
#import "protein_events.h"
#import "mouse_events.h"
#import "ui.h"
#import "subprocess.h"

@interface DesktopSession : NSObject
@property (nonatomic, strong) NSString *username;
@property (nonatomic, strong) NSString *homeDirectory;
@property (nonatomic, assign) uid_t uid;
@property (nonatomic, assign) gid_t gid;
@end

@implementation DesktopSession
@end

static DesktopSession *gDesktopSession = nil;

static PVView *gDesktopContainer = nil;
static PVScrollView *gLogScrollView = nil;
static PVView *gLogContentView = nil;
static NSMutableArray *gLogMessages = nil;

void addLogMessage(NSString *message) {
    if (!gLogMessages) {
        gLogMessages = [[NSMutableArray alloc] init];
    }

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"HH:mm:ss";
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];
    NSString *logEntry = [NSString stringWithFormat:@"[%@] %@", timestamp, message];

    [gLogMessages addObject:logEntry];

    if (gLogContentView) {
        PVLabel *logLabel = [[PVLabel alloc] init];
        logLabel.frame = CGRectMake(5, gLogContentView.subviews.count * 20, gLogContentView.frame.size.width - 10, 20);
        logLabel.text = logEntry;
        logLabel.backgroundColor = 0x00000000;
        logLabel.textColor = 0xFFFFFFFF;
        [gLogContentView addSubview:logLabel];

        gLogContentView.frame = CGRectMake(0, 0, gLogScrollView.frame.size.width, gLogContentView.subviews.count * 20);
        gLogScrollView.contentSize = gLogContentView.frame.size;

        if (gLogScrollView.contentSize.height > gLogScrollView.frame.size.height) {
            CGPoint contentOffset = CGPointMake(0, gLogScrollView.contentSize.height - gLogScrollView.frame.size.height);
            gLogScrollView.contentOffset = contentOffset;
        }
    }
}

void monitorFinderProcess(subprocess_t *process) {
    if (!process) return;

    char buffer[1024];
    fd_set read_fds;
    struct timeval timeout;

    while (subprocess_is_running(process)) {
        FD_ZERO(&read_fds);
        FD_SET(process->stdout_fd, &read_fds);
        FD_SET(process->stderr_fd, &read_fds);

        timeout.tv_sec = 0;
        timeout.tv_usec = 100000; // 100ms timeout

        int max_fd = (process->stdout_fd > process->stderr_fd) ? process->stdout_fd : process->stderr_fd;
        int result = select(max_fd + 1, &read_fds, NULL, NULL, &timeout);

        if (result > 0) {
            if (FD_ISSET(process->stdout_fd, &read_fds)) {
                ssize_t bytes_read = subprocess_read_stdout(process, buffer, sizeof(buffer) - 1);
                if (bytes_read > 0) {
                    buffer[bytes_read] = '\0';
                    NSString *output = [NSString stringWithUTF8String:buffer];
                    addLogMessage([NSString stringWithFormat:@"Finder stdout: %@", [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]]);
                }
            }

            if (FD_ISSET(process->stderr_fd, &read_fds)) {
                ssize_t bytes_read = subprocess_read_stderr(process, buffer, sizeof(buffer) - 1);
                if (bytes_read > 0) {
                    buffer[bytes_read] = '\0';
                    NSString *output = [NSString stringWithUTF8String:buffer];
                    addLogMessage([NSString stringWithFormat:@"Finder stderr: %@", [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]]);
                }
            }
        }
    }

    int exit_code = subprocess_wait(process);
    addLogMessage([NSString stringWithFormat:@"Finder process exited with code: %d", exit_code]);

    subprocess_cleanup(process);
}

void spawnFinder() {
    if (!gDesktopSession) {
        addLogMessage(@"Error: No active desktop session.");
        return;
    }

    addLogMessage([NSString stringWithFormat:@"Launching Finder.app as user %@...", gDesktopSession.username]);

    const char *argv[] = {"/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", NULL};

    // Use subprocess_execute_as_user to run as the logged-in user
    subprocess_t *process = subprocess_execute_as_user(
        "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
        argv,
        NULL, // Working dir
        gDesktopSession.username.UTF8String
    );

    if (process) {
        addLogMessage([NSString stringWithFormat:@"Finder process started with PID: %d", process->pid]);

        // Start monitoring in background
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            monitorFinderProcess(process);
        });
    } else {
        addLogMessage(@"Failed to launch Finder.app");
    }
}

void CreateDesktopView(PVView *gRootView, char * username, char * password) {
    // Initialize Desktop Session
    gDesktopSession = [[DesktopSession alloc] init];
    gDesktopSession.username = [NSString stringWithUTF8String:username];

    struct passwd *pw = getpwnam(username);
    if (pw) {
        gDesktopSession.uid = pw->pw_uid;
        gDesktopSession.gid = pw->pw_gid;
        gDesktopSession.homeDirectory = [NSString stringWithUTF8String:pw->pw_dir];
    }

    // Create desktop container view
    gDesktopContainer = [[PVView alloc] init];
    gDesktopContainer.frame = gRootView.frame;
    gDesktopContainer.backgroundColor = 0x018281FF; // Blue background
    [gRootView addSubview:gDesktopContainer];

    // Add Wallpaper
    PVImage *wallpaper = [[PVImage alloc] init];
    wallpaper.frame = gRootView.frame;
    wallpaper.imagePath = @"/private/var/protein/wallpaper.png";
    wallpaper.contentMode = PVContentModeTile;
    [gDesktopContainer addSubview:wallpaper];

    // Create log view on the right side
    gLogScrollView = [[PVScrollView alloc] init];
    gLogScrollView.frame = CGRectMake(1400, 100, 400, 800);
    gLogScrollView.backgroundColor = 0x1A1A1AFF;
    [gDesktopContainer addSubview:gLogScrollView];

    gLogContentView = [[PVView alloc] init];
    gLogContentView.frame = CGRectMake(0, 0, 400, 0);
    gLogContentView.backgroundColor = 0x00000000;
    [gLogScrollView addSubview:gLogContentView];

    // Add log header
    PVLabel *logHeader = [[PVLabel alloc] init];
    logHeader.frame = CGRectMake(1400, 60, 400, 30);
    logHeader.text = @"System Log";
    logHeader.backgroundColor = 0x00000000;
    logHeader.textColor = 0xFFFFFFFF;
    [gDesktopContainer addSubview:logHeader];

    // Create Finder button
    PVButton *finderButton = [[PVButton alloc] init];
    finderButton.frame = CGRectMake(50, 50, 120, 40);
    finderButton.backgroundColor = 0x3498DBFF;
    finderButton.title = @"Open Finder";
    finderButton.textColor = 0xFFFFFFFF;
    finderButton.onClick = ^{
        spawnFinder();
    };
    [gDesktopContainer addSubview:finderButton];

    // Add initial log message
    addLogMessage([NSString stringWithFormat:@"Desktop session created for user: %@", gDesktopSession.username]);
    addLogMessage([NSString stringWithFormat:@"Session UID: %d, GID: %d, Home: %@", gDesktopSession.uid, gDesktopSession.gid, gDesktopSession.homeDirectory]);
}
