#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static const void *CPWorkRecoveryGenerationKey = &CPWorkRecoveryGenerationKey;
static const void *CPWorkRecoveryBannerKey = &CPWorkRecoveryBannerKey;
static const void *CPWorkRecoveryReloadingKey = &CPWorkRecoveryReloadingKey;

@interface WKWebView (ContextPortWorkRecovery)
- (WKNavigation *)cp_workRecovery_loadRequest:(NSURLRequest *)request;
- (WKNavigation *)cp_workRecovery_reload;
@end

@implementation WKWebView (ContextPortWorkRecovery)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method originalLoad = class_getInstanceMethod(self, @selector(loadRequest:));
        Method replacementLoad = class_getInstanceMethod(self, @selector(cp_workRecovery_loadRequest:));
        method_exchangeImplementations(originalLoad, replacementLoad);

        Method originalReload = class_getInstanceMethod(self, @selector(reload));
        Method replacementReload = class_getInstanceMethod(self, @selector(cp_workRecovery_reload));
        method_exchangeImplementations(originalReload, replacementReload);
    });
}

- (WKNavigation *)cp_workRecovery_loadRequest:(NSURLRequest *)request {
    WKNavigation *navigation = [self cp_workRecovery_loadRequest:request];
    [self cp_scheduleWorkRecoveryForURL:request.URL];
    return navigation;
}

- (WKNavigation *)cp_workRecovery_reload {
    WKNavigation *navigation = [self cp_workRecovery_reload];
    [self cp_scheduleWorkRecoveryForURL:self.URL];
    return navigation;
}

- (void)cp_scheduleWorkRecoveryForURL:(NSURL *)url {
    if (![self cp_isChatGPTURL:url]) {
        [self cp_removeWorkRecoveryBanner];
        return;
    }

    NSNumber *generation = objc_getAssociatedObject(self, CPWorkRecoveryGenerationKey);
    NSInteger nextGeneration = generation.integerValue + 1;
    objc_setAssociatedObject(self, CPWorkRecoveryGenerationKey, @(nextGeneration), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self cp_removeWorkRecoveryBanner];

    __weak WKWebView *weakWebView = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WKWebView *webView = weakWebView;
        if (!webView) return;

        NSNumber *currentGeneration = objc_getAssociatedObject(webView, CPWorkRecoveryGenerationKey);
        if (currentGeneration.integerValue != nextGeneration) return;
        if (![webView cp_isChatGPTURL:webView.URL]) return;

        NSString *probe = @"(() => {"
            "const visible = e => { if (!e) return false; const r=e.getBoundingClientRect(); const s=getComputedStyle(e); return r.width>0 && r.height>0 && s.visibility!=='hidden' && s.display!=='none'; };"
            "const composer=[...document.querySelectorAll('textarea,[contenteditable=\"true\"],input[type=\"text\"]')].some(visible);"
            "const workControls=[...document.querySelectorAll('button,a,[role=\"button\"]')].some(e => visible(e) && /work|new|create|start/i.test((e.innerText||e.textContent||e.getAttribute('aria-label')||'')));"
            "return JSON.stringify({ready:document.readyState,composer,workControls,text:(document.body?.innerText||'').length});"
        "})()";

        [webView evaluateJavaScript:probe completionHandler:^(id result, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                WKWebView *strongWebView = weakWebView;
                if (!strongWebView) return;

                NSNumber *latestGeneration = objc_getAssociatedObject(strongWebView, CPWorkRecoveryGenerationKey);
                if (latestGeneration.integerValue != nextGeneration) return;

                BOOL shouldOfferRecovery = strongWebView.loading || error != nil;
                if ([result isKindOfClass:[NSString class]]) {
                    NSData *data = [(NSString *)result dataUsingEncoding:NSUTF8StringEncoding];
                    NSDictionary *status = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                    BOOL composer = [status[@"composer"] boolValue];
                    BOOL workControls = [status[@"workControls"] boolValue];
                    NSInteger textLength = [status[@"text"] integerValue];
                    shouldOfferRecovery = shouldOfferRecovery || (!composer && !workControls && textLength < 250);
                }

                if (shouldOfferRecovery) {
                    [strongWebView cp_showWorkRecoveryBanner];
                }
            });
        }];
    });
}

- (BOOL)cp_isChatGPTURL:(NSURL *)url {
    NSString *host = url.host.lowercaseString;
    if (host.length == 0) return NO;
    return [host isEqualToString:@"chatgpt.com"] || [host hasSuffix:@".chatgpt.com"];
}

- (void)cp_showWorkRecoveryBanner {
    if (objc_getAssociatedObject(self, CPWorkRecoveryBannerKey)) return;

    UIView *banner = [[UIView alloc] initWithFrame:CGRectZero];
    banner.translatesAutoresizingMaskIntoConstraints = NO;
    banner.backgroundColor = [UIColor secondarySystemBackgroundColor];
    banner.layer.cornerRadius = 12.0;
    banner.layer.borderWidth = 1.0;
    banner.layer.borderColor = [UIColor separatorColor].CGColor;
    banner.layer.shadowColor = [UIColor blackColor].CGColor;
    banner.layer.shadowOpacity = 0.18;
    banner.layer.shadowRadius = 8.0;
    banner.layer.shadowOffset = CGSizeMake(0, 3);

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.numberOfLines = 2;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.text = @"The ChatGPT Work session is taking too long to initialize. Reload the page without clearing your login or Memory.";

    UIButton *reloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    reloadButton.translatesAutoresizingMaskIntoConstraints = NO;
    [reloadButton setTitle:@"Reload" forState:UIControlStateNormal];
    reloadButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [reloadButton addTarget:self action:@selector(cp_retryWorkSession) forControlEvents:UIControlEventTouchUpInside];

    UIButton *dismissButton = [UIButton buttonWithType:UIButtonTypeSystem];
    dismissButton.translatesAutoresizingMaskIntoConstraints = NO;
    [dismissButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    dismissButton.tintColor = [UIColor secondaryLabelColor];
    [dismissButton addTarget:self action:@selector(cp_dismissWorkRecoveryBanner) forControlEvents:UIControlEventTouchUpInside];

    [banner addSubview:label];
    [banner addSubview:reloadButton];
    [banner addSubview:dismissButton];
    [self addSubview:banner];

    UILayoutGuide *safe = self.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [banner.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12.0],
        [banner.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12.0],
        [banner.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12.0],

        [dismissButton.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-10.0],
        [dismissButton.topAnchor constraintEqualToAnchor:banner.topAnchor constant:10.0],
        [dismissButton.widthAnchor constraintEqualToConstant:28.0],
        [dismissButton.heightAnchor constraintEqualToConstant:28.0],

        [reloadButton.trailingAnchor constraintEqualToAnchor:dismissButton.leadingAnchor constant:-8.0],
        [reloadButton.centerYAnchor constraintEqualToAnchor:banner.centerYAnchor],
        [reloadButton.widthAnchor constraintGreaterThanOrEqualToConstant:62.0],

        [label.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:14.0],
        [label.topAnchor constraintEqualToAnchor:banner.topAnchor constant:12.0],
        [label.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-12.0],
        [label.trailingAnchor constraintEqualToAnchor:reloadButton.leadingAnchor constant:-10.0]
    ]];

    objc_setAssociatedObject(self, CPWorkRecoveryBannerKey, banner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)cp_retryWorkSession {
    NSNumber *isReloading = objc_getAssociatedObject(self, CPWorkRecoveryReloadingKey);
    if (isReloading.boolValue) return;

    objc_setAssociatedObject(self, CPWorkRecoveryReloadingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self cp_removeWorkRecoveryBanner];
    [self stopLoading];

    NSURL *url = self.URL;
    if (url) {
        NSURLRequest *request = [NSURLRequest requestWithURL:url
                                               cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                           timeoutInterval:30.0];
        [self loadRequest:request];
    } else {
        [self loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://chatgpt.com/"]]];
    }

    __weak WKWebView *weakWebView = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WKWebView *webView = weakWebView;
        if (!webView) return;
        objc_setAssociatedObject(webView, CPWorkRecoveryReloadingKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

- (void)cp_dismissWorkRecoveryBanner {
    [self cp_removeWorkRecoveryBanner];
}

- (void)cp_removeWorkRecoveryBanner {
    UIView *banner = objc_getAssociatedObject(self, CPWorkRecoveryBannerKey);
    [banner removeFromSuperview];
    objc_setAssociatedObject(self, CPWorkRecoveryBannerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end
