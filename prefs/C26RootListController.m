#import "C26RootListController.h"
#import <notify.h>

@implementation C26RootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)respring {
    notify_post("com.mcclock26.locktime/doRespring");
}

@end
