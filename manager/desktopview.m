#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <AppKit/AppKit.h>

#import "metal_renderer.h"
#import "protein_events.h"
#import "mouse_events.h"
#import "ui.h"

// Desktop item structure
typedef struct {
    NSString *name;
    NSString *path;
    NSString *iconPath;
    CGRect frame;
} DesktopItem;

// Global desktop items
static NSMutableArray *gDesktopItems = nil;
static PVView *gDesktopContainer = nil;

// Get desktop items from user's Desktop folder
NSArray* GetDesktopItems() {
    NSMutableArray *items = [NSMutableArray array];
    NSString *desktopPath = @"/Users/bedtime/Desktop";

    if (!desktopPath) {
        NSLog(@"[Protein] Could not find Desktop directory");
        return items;
    }

    NSError *error = nil;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:desktopPath error:&error];

    if (error) {
        NSLog(@"[Protein] Failed to read Desktop directory: %@", error);
        return items;
    }

    // Create desktop items for each file/folder
    for (int i = 0; i < files.count; i++) {
        NSString *fileName = files[i];
        NSString *fullPath = [desktopPath stringByAppendingPathComponent:fileName];

        BOOL isDirectory;
        [[NSFileManager defaultManager] fileExistsAtPath:fullPath isDirectory:&isDirectory];

        DesktopItem item;
        item.name = fileName;
        item.path = fullPath;
        item.iconPath = nil; // Could be extended to load actual icons

        // Grid layout - 5 columns, calculate row and column
        int column = i % 5;
        int row = i / 5;
        item.frame = CGRectMake(50 + column * 150, 50 + row * 120, 120, 100);

        NSValue *itemValue = [NSValue valueWithBytes:&item objCType:@encode(DesktopItem)];
        [items addObject:itemValue];
    }

    return items;
}

// Handle double-click on desktop item
void HandleDesktopItemClick(DesktopItem *item) {
    if (!item || !item->path) return;

    NSLog(@"[Protein] Opening desktop item: %@", item->name);

    // Use NSWorkspace to open the item
    NSURL *url = [NSURL fileURLWithPath:item->path];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

void CreateDesktopView(PVView *gRootView, char * username) {
    // Initialize desktop items array
    gDesktopItems = [GetDesktopItems mutableCopy];

    // Create desktop container view
    gDesktopContainer = [[PVView alloc] init];
    gDesktopContainer.frame = CGRectMake(0, 0, 1920, 1080); // Full screen
    gDesktopContainer.backgroundColor = 0x1E3A8AFF; // Blue background
    [gRootView addSubview:gDesktopContainer];

    // Add desktop wallpaper effect (gradient)
    PVView *wallpaper = [[PVView alloc] init];
    wallpaper.frame = gDesktopContainer.frame;
    wallpaper.backgroundColor = 0x0F172AFF; // Dark blue gradient start
    wallpaper.onRender = ^(PVView *view) {
        // Could add custom rendering for wallpaper here
    };
    [gDesktopContainer addSubview:wallpaper];

    // Create desktop icons
    for (int i = 0; i < gDesktopItems.count; i++) {
        NSValue *itemValue = gDesktopItems[i];
        DesktopItem item;
        [itemValue getValue:&item];

        // Icon container
        PVView *iconContainer = [[PVView alloc] init];
        iconContainer.frame = item.frame;
        iconContainer.backgroundColor = 0x00000000; // Transparent
        [gDesktopContainer addSubview:iconContainer];

        // Icon placeholder (could be replaced with actual icon rendering)
        PVView *icon = [[PVView alloc] init];
        icon.frame = CGRectMake(35, 10, 50, 50);

        // Different colors for folders vs files
        BOOL isDirectory;
        [[NSFileManager defaultManager] fileExistsAtPath:item.path isDirectory:&isDirectory];
        icon.backgroundColor = isDirectory ? 0xFCD34DFF : 0x60A5FAFF; // Yellow for folders, blue for files
        [iconContainer addSubview:icon];

        // Label for item name
        PVLabel *label = [[PVLabel alloc] init];
        label.frame = CGRectMake(0, 65, 120, 35);
        label.text = item.name;
        label.textColor = 0xFFFFFFFF;
        label.backgroundColor = 0x00000000;
        [iconContainer addSubview:label];
    }

    // Add desktop menu bar at top
    PVView *menuBar = [[PVView alloc] init];
    menuBar.frame = CGRectMake(0, 0, 1920, 30);
    menuBar.backgroundColor = 0x000000AA; // Semi-transparent black
    [gDesktopContainer addSubview:menuBar];

    // Apple menu placeholder
    PVLabel *appleMenu = [[PVLabel alloc] init];
    appleMenu.frame = CGRectMake(10, 5, 50, 20);
    appleMenu.text = @"#";
    appleMenu.textColor = 0xFFFFFFFF;
    appleMenu.backgroundColor = 0x00000000;
    [menuBar addSubview:appleMenu];

    // Clock in menu bar
    PVLabel *clock = [[PVLabel alloc] init];
    clock.frame = CGRectMake(1820, 5, 80, 20);
    clock.textColor = 0xFFFFFFFF;
    clock.backgroundColor = 0x00000000;
    clock.onRender = ^(PVView *view) {
        NSDate *date = [NSDate date];
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm";
        clock.text = [formatter stringFromDate:date];
    };
    [menuBar addSubview:clock];

    NSLog(@"[Protein] Desktop view created with %lu items", (unsigned long)gDesktopItems.count);
}
