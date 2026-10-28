// RedditTranslate.m
// Плавающая кнопка 🌐: переводит видимый на экране текст постов прямо в интерфейсе.
//  - короткое нажатие: перевести видимое / повторно нажать, когда всё переведено — вернуть оригинал
//  - долгое нажатие: диагностика (копирует в буфер список текстовых вью на экране)
//  - кнопку можно перетаскивать
// Язык перевода меняется константой ниже.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define RT_TARGET_LANG @"ru"
#define RT_MAX_ITEMS 30

static const void *kOrigKey = &kOrigKey;
static UIButton *gButton;
static UIView *gPanel;
static NSHashTable<UIView *> *gTranslated;
static BOOL gBusy;

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#pragma mark - Утилиты

static UIWindow *KeyWindow(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        if (s.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            if (w.isKeyWindow) return w;
        }
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

static void Toast(NSString *msg) {
    UIWindow *w = KeyWindow();
    if (!w) return;
    UILabel *l = [UILabel new];
    l.text = msg;
    l.numberOfLines = 0;
    l.font = [UIFont systemFontOfSize:14];
    l.textColor = UIColor.whiteColor;
    l.textAlignment = NSTextAlignmentCenter;
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
    l.layer.cornerRadius = 10;
    l.clipsToBounds = YES;
    CGSize sz = [l sizeThatFits:CGSizeMake(w.bounds.size.width - 80, CGFLOAT_MAX)];
    l.frame = CGRectMake(0, 0, sz.width + 20, sz.height + 14);
    l.center = CGPointMake(w.bounds.size.width / 2, w.safeAreaInsets.top + 60);
    [w addSubview:l];
    [UIView animateWithDuration:0.4 delay:2.2 options:0 animations:^{ l.alpha = 0; }
                     completion:^(BOOL f) { [l removeFromSuperview]; }];
}

static NSString *TextOf(UIView *v) {
    if ([v isKindOfClass:UILabel.class]) return ((UILabel *)v).text;
    if ([v isKindOfClass:UITextView.class]) return ((UITextView *)v).text;
    return nil;
}

static BOOL OnScreen(UIView *v) {
    UIWindow *w = v.window;
    if (!w) return NO;
    for (UIView *p = v; p; p = p.superview) {
        if (p.hidden || p.alpha < 0.05) return NO;
    }
    CGRect r = [v convertRect:v.bounds toView:nil];
    return r.size.height > 8 && r.size.width > 8 && CGRectIntersectsRect(r, w.bounds);
}

static BOOL Eligible(NSString *t) {
    NSString *s = [t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (s.length < 15) return NO;
    if ([s rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location == NSNotFound) return NO;
    if ([s hasPrefix:@"r/"] || [s hasPrefix:@"u/"] || [s hasPrefix:@"/r/"] || [s hasPrefix:@"/u/"]) return NO;
    return YES;
}

static BOOL IsTranslated(UIView *v) {
    NSArray *rec = objc_getAssociatedObject(v, kOrigKey);
    return rec && [TextOf(v) isEqualToString:rec[1]];
}

#pragma mark - Перевод (неофициальный эндпоинт Google Translate)

static NSString *Enc(NSString *s) {
    NSMutableCharacterSet *cs = [NSMutableCharacterSet alphanumericCharacterSet];
    [cs addCharactersInString:@"-._~"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:cs];
}

static void Translate(NSString *text, void (^done)(NSString *tr, NSString *src)) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *c = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        c.timeoutIntervalForRequest = 15;
        session = [NSURLSession sessionWithConfiguration:c];
    });
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://translate.googleapis.com/translate_a/single"]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/x-www-form-urlencoded; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    NSString *body = [NSString stringWithFormat:@"client=gtx&sl=auto&tl=%@&dt=t&q=%@",
                      RT_TARGET_LANG, Enc(text)];
    req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSString *out = nil, *src = nil;
        if (data && !err) {
            id j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([j isKindOfClass:NSArray.class] && [j count] > 0 && [j[0] isKindOfClass:NSArray.class]) {
                NSMutableString *acc = [NSMutableString string];
                for (id seg in (NSArray *)j[0]) {
                    if ([seg isKindOfClass:NSArray.class] && [seg count] > 0 &&
                        [seg[0] isKindOfClass:NSString.class]) {
                        [acc appendString:seg[0]];
                    }
                }
                if (acc.length) out = acc;
                if ([j count] > 2 && [j[2] isKindOfClass:NSString.class]) src = j[2];
            }
        }
        done(out, src);
    }] resume];
}

#pragma mark - Подмена и восстановление текста

static NSAttributedString *Rebuild(NSAttributedString *orig, NSString *tr) {
    NSMutableDictionary *a = orig.length
        ? [[orig attributesAtIndex:0 effectiveRange:NULL] mutableCopy]
        : [NSMutableDictionary dictionary];
    [a removeObjectForKey:NSLinkAttributeName];
    return [[NSAttributedString alloc] initWithString:tr attributes:a];
}

static void Apply(UIView *v, NSString *tr) {
    NSAttributedString *orig = nil;
    if ([v isKindOfClass:UILabel.class]) {
        UILabel *l = (UILabel *)v;
        orig = l.attributedText ?: [[NSAttributedString alloc] initWithString:l.text ?: @""];
        l.attributedText = Rebuild(orig, tr);
    } else if ([v isKindOfClass:UITextView.class]) {
        UITextView *t = (UITextView *)v;
        orig = t.attributedText;
        t.attributedText = Rebuild(orig, tr);
    } else {
        return;
    }
    objc_setAssociatedObject(v, kOrigKey, @[orig, tr], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [gTranslated addObject:v];
}

static NSInteger RestoreAll(void) {
    NSInteger n = 0;
    for (UIView *v in gTranslated.allObjects) {
        NSArray *rec = objc_getAssociatedObject(v, kOrigKey);
        // восстанавливаем только если вью всё ещё показывает наш перевод (ячейки переиспользуются)
        if (rec && [TextOf(v) isEqualToString:rec[1]]) {
            if ([v isKindOfClass:UILabel.class]) ((UILabel *)v).attributedText = rec[0];
            else if ([v isKindOfClass:UITextView.class]) ((UITextView *)v).attributedText = rec[0];
            n++;
        }
        objc_setAssociatedObject(v, kOrigKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [gTranslated removeAllObjects];
    return n;
}

#pragma mark - Сбор текста с экрана

static void Collect(UIView *root, NSMutableArray<UIView *> *out, NSMutableOrderedSet<NSString *> *a11y) {
    if (root == gButton || root == gPanel || root.hidden || root.alpha < 0.05) return;
    if ([root isKindOfClass:UITextView.class] && ((UITextView *)root).isEditable) return;

    NSString *t = TextOf(root);
    if (t) {
        if (Eligible(t) && !IsTranslated(root) && OnScreen(root)) [out addObject:root];
    } else {
        NSString *a = root.accessibilityLabel;
        if (a.length >= 30 && OnScreen(root)) [a11y addObject:a];
    }
    for (UIView *s in root.subviews) Collect(s, out, a11y);
}

static void DumpWalk(UIView *v, NSMutableString *out, NSInteger *count) {
    if (v == gButton || v == gPanel) return;
    NSString *t = TextOf(v);
    if (!t.length) t = v.accessibilityLabel;
    if (t.length && OnScreen(v)) {
        NSString *sup = NSStringFromClass(class_getSuperclass(v.class));
        [out appendFormat:@"%@ < %@ | %@\n", NSStringFromClass(v.class), sup,
         [t substringToIndex:MIN((NSUInteger)70, t.length)]];
        (*count)++;
    }
    for (UIView *s in v.subviews) DumpWalk(s, out, count);
}

#pragma mark - Панель-фолбэк (если текст нельзя подменить на месте)

static void ShowPanel(NSString *text) {
    UIWindow *w = KeyWindow();
    if (!w) return;
    [gPanel removeFromSuperview];
    UIView *p = [[UIView alloc] initWithFrame:CGRectInset(w.bounds, 16, 90)];
    p.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.96];
    p.layer.cornerRadius = 14;
    p.clipsToBounds = YES;

    UITextView *tv = [[UITextView alloc] initWithFrame:
        CGRectMake(0, 44, p.bounds.size.width, p.bounds.size.height - 44)];
    tv.editable = NO;
    tv.backgroundColor = UIColor.clearColor;
    tv.textColor = UIColor.whiteColor;
    tv.font = [UIFont systemFontOfSize:16];
    tv.text = text;
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [p addSubview:tv];

    UIButton *x = [UIButton buttonWithType:UIButtonTypeSystem];
    x.frame = CGRectMake(p.bounds.size.width - 48, 0, 44, 44);
    x.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    x.titleLabel.font = [UIFont systemFontOfSize:20];
    [x setTitle:@"✕" forState:UIControlStateNormal];
    [x setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [x addTarget:p action:@selector(removeFromSuperview) forControlEvents:UIControlEventTouchUpInside];
    [p addSubview:x];

    gPanel = p;
    [w addSubview:p];
}

#pragma mark - Контроллер кнопки

@interface RTHelper : NSObject
+ (instancetype)shared;
- (void)ensureButton;
- (void)tap;
- (void)longPress:(UILongPressGestureRecognizer *)g;
- (void)pan:(UIPanGestureRecognizer *)g;
@end

@implementation RTHelper

+ (instancetype)shared {
    static RTHelper *h;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [RTHelper new]; });
    return h;
}

- (void)ensureButton {
    UIWindow *w = KeyWindow();
    if (!w) return;
    if (!gButton) {
        gButton = [UIButton buttonWithType:UIButtonTypeSystem];
        gButton.frame = CGRectMake(w.bounds.size.width - 60, w.bounds.size.height * 0.5, 48, 48);
        gButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.65];
        gButton.layer.cornerRadius = 24;
        gButton.titleLabel.font = [UIFont systemFontOfSize:22];
        [gButton setTitle:@"🌐" forState:UIControlStateNormal];
        [gButton addTarget:self action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];
        [gButton addGestureRecognizer:[[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(longPress:)]];
        [gButton addGestureRecognizer:[[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(pan:)]];
    }
    if (gButton.superview != w) [w addSubview:gButton];
    else [w bringSubviewToFront:gButton];
}

- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
}

- (void)longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIWindow *w = KeyWindow();
    if (!w) return;
    NSMutableString *out = [NSMutableString string];
    NSInteger n = 0;
    DumpWalk(w, out, &n);
    UIPasteboard.generalPasteboard.string = out;
    Toast([NSString stringWithFormat:@"Диагностика: %ld строк скопировано в буфер", (long)n]);
}

- (void)tap {
    if (gBusy) return;
    UIWindow *w = KeyWindow();
    if (!w) return;

    NSMutableArray<UIView *> *views = [NSMutableArray array];
    NSMutableOrderedSet<NSString *> *a11y = [NSMutableOrderedSet orderedSet];
    Collect(w, views, a11y);

    if (views.count > 0) {
        if (views.count > RT_MAX_ITEMS) [views removeObjectsInRange:NSMakeRange(RT_MAX_ITEMS, views.count - RT_MAX_ITEMS)];
        gBusy = YES;
        [gButton setTitle:@"…" forState:UIControlStateNormal];
        dispatch_group_t grp = dispatch_group_create();
        __block NSInteger changed = 0;
        for (UIView *v in views) {
            NSString *text = TextOf(v);
            dispatch_group_enter(grp);
            Translate(text, ^(NSString *tr, NSString *src) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (tr.length && ![src isEqualToString:RT_TARGET_LANG] &&
                        [TextOf(v) isEqualToString:text]) {
                        Apply(v, tr);
                        changed++;
                    }
                    dispatch_group_leave(grp);
                });
            });
        }
        dispatch_group_notify(grp, dispatch_get_main_queue(), ^{
            gBusy = NO;
            [gButton setTitle:@"🌐" forState:UIControlStateNormal];
            if (changed == 0) Toast(@"Перевод не потребовался или не удался");
        });
        return;
    }

    if (RestoreAll() > 0) {
        Toast(@"Оригинал восстановлен");
        return;
    }

    if (a11y.count > 0) {
        // Текст не в UILabel/UITextView (например, Texture/SwiftUI): подменить на месте нельзя,
        // поэтому показываем перевод в отдельной панели.
        NSMutableString *joined = [NSMutableString string];
        NSInteger i = 0;
        for (NSString *s in a11y) {
            if (i++ >= 6 || joined.length > 4000) break;
            [joined appendFormat:@"%@\n\n", s];
        }
        gBusy = YES;
        [gButton setTitle:@"…" forState:UIControlStateNormal];
        Translate(joined, ^(NSString *tr, NSString *src) {
            dispatch_async(dispatch_get_main_queue(), ^{
                gBusy = NO;
                [gButton setTitle:@"🌐" forState:UIControlStateNormal];
                if (tr.length) ShowPanel(tr); else Toast(@"Не удалось перевести");
            });
        });
        return;
    }

    Toast(@"Текст не найден. Удерживайте кнопку для диагностики");
}

@end

#pragma mark - Запуск

__attribute__((constructor))
static void RTInit(void) {
    gTranslated = [NSHashTable weakObjectsHashTable];
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *t) {
            [[RTHelper shared] ensureButton];
        }];
    });
}
