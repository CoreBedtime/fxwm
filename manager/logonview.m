#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CommonCrypto/CommonCrypto.h>
#import <CommonCrypto/CommonKeyDerivation.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#import <unistd.h>

#import "metal_renderer.h"
#import "protein_events.h"
#import "mouse_events.h"
#import "ui.h"

// Helper to verify PBKDF2-SHA512 hash
static BOOL VerifyPBKDF2(NSString *password, NSData *entropy, NSData *salt, uint32_t iterations) {
    if (!entropy || !salt || iterations == 0) return NO;

    NSMutableData *derivedKey = [NSMutableData dataWithLength:entropy.length];
    int result = CCKeyDerivationPBKDF(
        kCCPBKDF2,                  // algorithm
        password.UTF8String,        // password
        password.length,            // passwordLen
        salt.bytes,                 // salt
        salt.length,                // saltLen
        kCCPRFHmacAlgSHA512,              // PRF
        iterations,                 // rounds
        derivedKey.mutableBytes,     // derivedKey
        derivedKey.length           // derivedKeyLen
    );

    if (result != kCCSuccess) return NO;
    return [derivedKey isEqualToData:entropy];
}

Boolean DoLogon(const char* username, const char* password) {
    if (!username || !password) return false;

    @autoreleasepool {
        NSString *nsUsername = [NSString stringWithUTF8String:username];
        NSString *nsPassword = [NSString stringWithUTF8String:password];

        // Path to user plist in local nodes
        NSString *userPlistPath = [NSString stringWithFormat:@"/var/db/dslocal/nodes/Default/users/%@.plist", nsUsername];
        NSDictionary *userPlist = [NSDictionary dictionaryWithContentsOfFile:userPlistPath];

        if (!userPlist) {
            NSLog(@"[Protein] DoLogon: Failed to read user plist at %@", userPlistPath);
            return false;
        }

        // ShadowHashData is an array of data, first element is a binary plist
        NSArray *shadowHashArray = userPlist[@"ShadowHashData"];
        if (!shadowHashArray || shadowHashArray.count == 0) {
            NSLog(@"[Protein] DoLogon: No ShadowHashData found for %@", nsUsername);
            return false;
        }

        NSData *shadowHashData = shadowHashArray[0];
        NSError *error = nil;
        NSDictionary *shadowDict = [NSPropertyListSerialization propertyListWithData:shadowHashData
                                                                           options:NSPropertyListImmutable
                                                                            format:NULL
                                                                             error:&error];
        if (!shadowDict) {
            NSLog(@"[Protein] DoLogon: Failed to parse ShadowHashData: %@", error);
            return false;
        }

        // Modern macOS uses SALTED-SHA512-PBKDF2
        NSDictionary *pbkdf2Dict = shadowDict[@"SALTED-SHA512-PBKDF2"];
        if (pbkdf2Dict) {
            NSData *entropy = pbkdf2Dict[@"entropy"];
            NSData *salt = pbkdf2Dict[@"salt"];
            uint32_t iterations = [pbkdf2Dict[@"iterations"] unsignedIntValue];

            if (VerifyPBKDF2(nsPassword, entropy, salt, iterations)) {
                NSLog(@"[Protein] DoLogon: PBKDF2 Authentication successful for %@", nsUsername);
                return true;
            }
        } else {
            NSLog(@"[Protein] DoLogon: SALTED-SHA512-PBKDF2 not found in shadow dict");
        }

        NSLog(@"[Protein] DoLogon: Authentication failed for %@", nsUsername);
        return false;
    }
}

static NSString *gSelectedUsername = nil;

NSArray* GetUserList() {
    NSMutableArray *users = [NSMutableArray array];
    NSString *path = @"/var/db/dslocal/nodes/Default/users/";
    NSError *error = nil;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:&error];

    if (error) {
        NSLog(@"[Protein] Failed to read users directory: %@", error);
        return @[@"bedtime"]; // Fallback
    }

    for (NSString *file in files) {
        if ([file hasSuffix:@".plist"] && ![file hasPrefix:@"_"]) {
            NSString *username = [file stringByDeletingPathExtension];
            [users addObject:username];
        }
    }
    return users;
}

extern
void CreateDesktopView(PVView *gRootView, char * username);

void CreateLogonView(PVView *gRootView) {
    NSArray *users = GetUserList();
    gSelectedUsername = [users firstObject];

    // Add a label for instructions/status
    PVLabel *statusLbl = [[PVLabel alloc] init];
    statusLbl.frame = CGRectMake(800, 500, 400, 30);
    statusLbl.text = [NSString stringWithFormat:@"Login as: %@", gSelectedUsername ?: @"none"];
    statusLbl.backgroundColor = 0x00000000;
    statusLbl.textColor = 0xFFFFFFFF;
    [gRootView addSubview:statusLbl];

    // Create ScrollView for User List
    PVScrollView *sv = [[PVScrollView alloc] init];
    sv.frame = CGRectMake(800, 100, 200, 350);
    sv.backgroundColor = 0x222222FF;
    sv.contentSize = CGSizeMake(200, users.count * 50);
    [gRootView addSubview:sv];

    for (int i = 0; i < users.count; i++) {
        NSString *user = users[i];
        PVButton *btn = [[PVButton alloc] init];
        btn.frame = CGRectMake(5, i * 50 + 5, 190, 40);
        btn.title = user;
        btn.backgroundColor = 0x444444FF;
        btn.onClick = ^{
            gSelectedUsername = user;
            statusLbl.text = [NSString stringWithFormat:@"Login as: %@", user];
            statusLbl.textColor = 0xFFFFFFFF;
        };
        [sv addSubview:btn];
    }

    // Add a text field for password
    PVTextField *tf = [[PVTextField alloc] init];
    tf.frame = CGRectMake(800, 550, 200, 40);
    tf.placeholder = @"Type password...";
    tf.backgroundColor = 0x000000FF; // Black
    tf.textColor = 0xFFFFFFFF; // White
    tf.secureTextEntry = YES;
    tf.onEnter = ^(NSString *text) {
        if (!gSelectedUsername) return;

        // Trim whitespace/newlines
        NSString *trimmedText = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

        NSLog(@"[Protein] Password Attempt for %@ (length: %lu)", gSelectedUsername, (unsigned long)trimmedText.length);

        Boolean loginSucceded = DoLogon(gSelectedUsername.UTF8String, trimmedText.UTF8String);
        if (loginSucceded) {
            [statusLbl removeFromSuperview];
            [tf removeFromSuperview];
            [sv removeFromSuperview];

            CreateDesktopView(gRootView, gSelectedUsername.UTF8String);
        } else {
            statusLbl.text = @"Login failed. Try again.";
            statusLbl.textColor = 0xFF0000FF; // Red
            tf.text = @""; // Clear password on failure
        }
    };
    [gRootView addSubview:tf];
}
