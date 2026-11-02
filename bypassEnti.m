#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// Replacement class methods used when the app asks SiriKit for these objects.
// Returning nil avoids the entitlement-gated constructors; callers must
// tolerate a nil result for the affected Siri features to remain disabled.
@interface BypassIntents : NSObject
+ (id)sharedPreferences;
+ (id)sharedVocabulary;
@end

@implementation BypassIntents
+ (id)sharedPreferences { return nil; }
+ (id)sharedVocabulary { return nil; }
@end

static void ReplaceClassMethod(Class originalClass, SEL originalSelector,
                               Class replacementClass, SEL replacementSelector) {
    Method original = class_getClassMethod(originalClass, originalSelector);
    Method replacement = class_getClassMethod(replacementClass, replacementSelector);
    if (!original || !replacement) {
        NSLog(@"[bypassEnti] Method unavailable: %@", NSStringFromSelector(originalSelector));
        return;
    }
    method_exchangeImplementations(original, replacement);
    NSLog(@"[bypassEnti] Replaced %@", NSStringFromSelector(originalSelector));
}

static void __attribute__((constructor)) BypassEntitlementInitialize(void) {
    @autoreleasepool {
        Class preferences = objc_getClass("INPreferences");
        if (preferences) {
            ReplaceClassMethod(preferences, @selector(sharedPreferences),
                               [BypassIntents class], @selector(sharedPreferences));
        }

        Class vocabulary = objc_getClass("INVocabulary");
        if (vocabulary) {
            ReplaceClassMethod(vocabulary, @selector(sharedVocabulary),
                               [BypassIntents class], @selector(sharedVocabulary));
        }
    }
}
