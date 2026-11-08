#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// Freeze Foundation NSDate "now" APIs at the first launch and persist that
// instant in the target app's standard defaults across later launches.
// This is a test hook for the app process; it does not change device time.

static NSString * const kDateFreezeDefaultsKey = @"DateFreeze.FrozenReferenceTime";
static NSDate *gFrozenDate = nil;

static id FrozenDateNow(id self, SEL command) {
    return gFrozenDate;
}

static id FrozenDateWithInterval(id self, SEL command, NSTimeInterval interval) {
    return [NSDate dateWithTimeInterval:interval sinceDate:gFrozenDate];
}

static NSTimeInterval FrozenTimeIntervalSinceNow(id self, SEL command) {
    return [(NSDate *)self timeIntervalSinceDate:gFrozenDate];
}

static void ReplaceClassMethod(Class targetClass, SEL selector, IMP replacement) {
    Class metaclass = object_getClass(targetClass);
    Method method = class_getInstanceMethod(metaclass, selector);
    if (!method) {
        NSLog(@"[DateFreeze] Class method unavailable: %@", NSStringFromSelector(selector));
        return;
    }
    class_replaceMethod(metaclass, selector, replacement, method_getTypeEncoding(method));
}

static void ReplaceInstanceMethod(Class targetClass, SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(targetClass, selector);
    if (!method) return;
    class_replaceMethod(targetClass, selector, replacement, method_getTypeEncoding(method));
}

static void __attribute__((constructor)) DateFreezeInitialize(void) {
    @autoreleasepool {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSNumber *savedTime = [defaults objectForKey:kDateFreezeDefaultsKey];
        NSTimeInterval referenceTime;

        if (savedTime) {
            referenceTime = savedTime.doubleValue;
        } else {
            referenceTime = [NSDate timeIntervalSinceReferenceDate];
            [defaults setDouble:referenceTime forKey:kDateFreezeDefaultsKey];
            [defaults synchronize];
        }

        gFrozenDate = [[NSDate alloc] initWithTimeIntervalSinceReferenceDate:referenceTime];

        ReplaceClassMethod([NSDate class], @selector(date), (IMP)FrozenDateNow);
        ReplaceClassMethod([NSDate class], @selector(now), (IMP)FrozenDateNow);
        ReplaceClassMethod([NSDate class], @selector(dateWithTimeIntervalSinceNow:),
                           (IMP)FrozenDateWithInterval);

        // NSDate is a class cluster. Install the instance hook on the public
        // base class and the concrete implementation class used by the factory.
        ReplaceInstanceMethod([NSDate class], @selector(timeIntervalSinceNow),
                              (IMP)FrozenTimeIntervalSinceNow);
        Class concreteDateClass = object_getClass(
            [[NSDate alloc] initWithTimeIntervalSinceReferenceDate:0.0]);
        if (concreteDateClass && concreteDateClass != [NSDate class]) {
            ReplaceInstanceMethod(concreteDateClass, @selector(timeIntervalSinceNow),
                                  (IMP)FrozenTimeIntervalSinceNow);
        }

        NSLog(@"[DateFreeze] NSDate frozen at %@", gFrozenDate);
    }
}
