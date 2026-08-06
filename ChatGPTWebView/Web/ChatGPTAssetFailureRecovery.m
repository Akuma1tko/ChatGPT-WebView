#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static const void *CPAssetRecoveryScriptInstalledKey = &CPAssetRecoveryScriptInstalledKey;
static const void *CPAssetRecoveryGenerationKey = &CPAssetRecoveryGenerationKey;
static const void *CPAssetRecoveryBannerKey = &CPAssetRecoveryBannerKey;
static const void *CPAssetRecoveryRepairingKey = &CPAssetRecoveryRepairingKey;
static const void *CPAssetRecoveryFailedURLsKey = &CPAssetRecoveryFailedURLsKey;

@interface WKWebView (ContextPortAssetFailureRecovery)
- (WKNavigation *)cp_assetRecovery_loadRequest:(NSURLRequest *)request;
- (WKNavigation *)cp_assetRecovery_reload;
@end

@implementation WKWebView (ContextPortAssetFailureRecovery)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method originalLoad = class_getInstanceMethod(self, @selector(loadRequest:));
        Method replacementLoad = class_getInstanceMethod(self, @selector(cp_assetRecovery_loadRequest:));
        method_exchangeImplementations(originalLoad, replacementLoad);

        Method originalReload = class_getInstanceMethod(self, @selector(reload));
        Method replacementReload = class_getInstanceMethod(self, @selector(cp_assetRecovery_reload));
        method_exchangeImplementations(originalReload, replacementReload);
    });
}

- (WKNavigation *)cp_assetRecovery_loadRequest:(NSURLRequest *)request {
    [self cp_installAssetFailureMonitorIfNeeded];
    WKNavigation *navigation = [self cp_assetRecovery_loadRequest:request];
    [self cp_scheduleAssetFailureProbeForURL:request.URL];
    return navigation;
}

- (WKNavigation *)cp_assetRecovery_reload {
    [self cp_installAssetFailureMonitorIfNeeded];
    WKNavigation *navigation = [self cp_assetRecovery_reload];
    [self cp_scheduleAssetFailureProbeForURL:self.URL];
    return navigation;
}

- (BOOL)cp_isChatGPTAssetRecoveryURL:(NSURL *)url {
    NSString *host = url.host.lowercaseString;
    if (host.length == 0) return NO;
    return [host isEqualToString:@"chatgpt.com"] || [host hasSuffix:@".chatgpt.com"];
}

- (void)cp_installAssetFailureMonitorIfNeeded {
    if ([objc_getAssociatedObject(self, CPAssetRecoveryScriptInstalledKey) boolValue]) return;

    NSString *source = @"(() => {"
        "if (window.__contextPortAssetFailureMonitor?.installed) return;"
        "const state={installed:true,failures:[]};"
        "const normalize=value=>{try{return new URL(String(value||''),location.href).href}catch(_){return ''}};"
        "const isChatGPTAsset=value=>{"
            "const url=normalize(value);if(!url)return false;"
            "try{const parsed=new URL(url);return /(^|\\.)chatgpt\\.com$/.test(parsed.hostname)&&/\\/cdn\\/assets\\/[^/?#]+\\.js(?:$|[?#])/.test(parsed.href)}catch(_){return false}"
        "};"
        "const record=(value,kind,message)=>{"
            "const url=normalize(value);if(!isChatGPTAsset(url))return;"
            "const existing=state.failures.find(item=>item.url===url);"
            "if(existing){existing.kind=kind||existing.kind;existing.message=String(message||existing.message||'').slice(0,240);existing.at=Date.now();return;}"
            "state.failures.push({url,kind:String(kind||'resource'),message:String(message||'').slice(0,240),at:Date.now()});"
            "if(state.failures.length>8)state.failures.splice(0,state.failures.length-8);"
        "};"
        "window.__contextPortAssetFailureMonitor=state;"
        "window.__contextPortAssetFailureSnapshot=()=>state.failures.slice();"
        "addEventListener('error',event=>{"
            "const target=event.target;"
            "if(target&&target!==window){"
                "const tag=String(target.tagName||'').toUpperCase();"
                "const rel=String(target.rel||'').toLowerCase();"
                "const url=target.src||target.href||'';"
                "if(tag==='SCRIPT'||(tag==='LINK'&&(rel.includes('modulepreload')||rel.includes('preload'))))record(url,'resource',event.message||'Resource load failed');"
                "return;"
            "}"
            "const message=String(event.message||'');"
            "const match=message.match(/https:\\/\\/chatgpt\\.com\\/cdn\\/assets\\/[^\\s\"'<>]+\\.js(?:[?#][^\\s\"'<>]*)?/i);"
            "if(match)record(match[0],'script',message);"
        "},true);"
        "addEventListener('unhandledrejection',event=>{"
            "const reason=event.reason;const message=String(reason?.message||reason||'');"
            "if(!/module|import|fetch/i.test(message))return;"
            "const match=message.match(/https:\\/\\/chatgpt\\.com\\/cdn\\/assets\\/[^\\s\"'<>]+\\.js(?:[?#][^\\s\"'<>]*)?/i);"
            "if(match)record(match[0],'promise',message);"
        "});"
    "})()";

    WKUserScript *script = [[WKUserScript alloc]
        initWithSource:source
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly:YES];
    [self.configuration.userContentController addUserScript:script];
    objc_setAssociatedObject(self, CPAssetRecoveryScriptInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)cp_scheduleAssetFailureProbeForURL:(NSURL *)url {
    if (![self cp_isChatGPTAssetRecoveryURL:url]) {
        [self cp_removeAssetRecoveryBanner];
        return;
    }

    NSNumber *generation = objc_getAssociatedObject(self, CPAssetRecoveryGenerationKey);
    NSInteger nextGeneration = generation.integerValue + 1;
    objc_setAssociatedObject(self, CPAssetRecoveryGenerationKey, @(nextGeneration), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, CPAssetRecoveryFailedURLsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self cp_removeAssetRecoveryBanner];

    __weak WKWebView *weakWebView = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(18.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WKWebView *webView = weakWebView;
        if (!webView) return;

        NSNumber *currentGeneration = objc_getAssociatedObject(webView, CPAssetRecoveryGenerationKey);
        if (currentGeneration.integerValue != nextGeneration) return;
        if (![webView cp_isChatGPTAssetRecoveryURL:webView.URL]) return;

        NSString *probe = @"(() => {"
            "const visible=e=>{if(!e)return false;const r=e.getBoundingClientRect();const s=getComputedStyle(e);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none'};"
            "const composer=[...document.querySelectorAll('textarea,[contenteditable=\"true\"],input[type=\"text\"]')].some(visible);"
            "const turns=document.querySelectorAll('[data-message-author-role],section[data-testid^=conversation-turn-],[data-testid*=conversation-turn]').length;"
            "const failures=Array.isArray(window.__contextPortAssetFailureMonitor?.failures)?window.__contextPortAssetFailureMonitor.failures.slice(-8):[];"
            "return JSON.stringify({ready:document.readyState,composer,turns,text:(document.body?.innerText||'').length,failures});"
        "})()";

        [webView evaluateJavaScript:probe completionHandler:^(id result, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                WKWebView *strongWebView = weakWebView;
                if (!strongWebView) return;

                NSNumber *latestGeneration = objc_getAssociatedObject(strongWebView, CPAssetRecoveryGenerationKey);
                if (latestGeneration.integerValue != nextGeneration) return;

                NSDictionary *status = nil;
                if ([result isKindOfClass:[NSString class]]) {
                    NSData *data = [(NSString *)result dataUsingEncoding:NSUTF8StringEncoding];
                    status = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                }

                NSArray *failures = [status[@"failures"] isKindOfClass:[NSArray class]] ? status[@"failures"] : @[];
                NSMutableArray<NSString *> *failedURLs = [NSMutableArray array];
                for (id item in failures) {
                    if (![item isKindOfClass:[NSDictionary class]]) continue;
                    NSString *failedURL = [item[@"url"] isKindOfClass:[NSString class]] ? item[@"url"] : nil;
                    if (failedURL.length > 0 && ![failedURLs containsObject:failedURL]) {
                        [failedURLs addObject:failedURL];
                    }
                    if (failedURLs.count >= 3) break;
                }

                if (failedURLs.count == 0) return;

                objc_setAssociatedObject(
                    strongWebView,
                    CPAssetRecoveryFailedURLsKey,
                    failedURLs.copy,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC
                );

                BOOL composer = [status[@"composer"] boolValue];
                BOOL stalled = strongWebView.loading || error != nil || !composer;
                if (stalled) {
                    [strongWebView cp_showAssetRecoveryBanner];
                }
            });
        }];
    });
}

- (void)cp_showAssetRecoveryBanner {
    if (objc_getAssociatedObject(self, CPAssetRecoveryBannerKey)) return;

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
    label.numberOfLines = 3;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.text = @"ChatGPT failed to load a JavaScript module. Repair retries only the failed asset, warms the WebKit cache, and reloads this page without clearing your login or Memory.";

    UIButton *repairButton = [UIButton buttonWithType:UIButtonTypeSystem];
    repairButton.translatesAutoresizingMaskIntoConstraints = NO;
    [repairButton setTitle:@"Repair" forState:UIControlStateNormal];
    repairButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [repairButton addTarget:self action:@selector(cp_repairFailedChatGPTAssets) forControlEvents:UIControlEventTouchUpInside];

    UIButton *dismissButton = [UIButton buttonWithType:UIButtonTypeSystem];
    dismissButton.translatesAutoresizingMaskIntoConstraints = NO;
    [dismissButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    dismissButton.tintColor = [UIColor secondaryLabelColor];
    [dismissButton addTarget:self action:@selector(cp_dismissAssetRecoveryBanner) forControlEvents:UIControlEventTouchUpInside];

    [banner addSubview:label];
    [banner addSubview:repairButton];
    [banner addSubview:dismissButton];
    [self addSubview:banner];

    UILayoutGuide *safe = self.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [banner.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12.0],
        [banner.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12.0],
        [banner.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12.0],

        [dismissButton.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-10.0],
        [dismissButton.topAnchor constraintEqualToAnchor:banner.topAnchor constant:10.0],
        [dismissButton.widthAnchor constraintEqualToConstant:28.0],
        [dismissButton.heightAnchor constraintEqualToConstant:28.0],

        [repairButton.trailingAnchor constraintEqualToAnchor:dismissButton.leadingAnchor constant:-8.0],
        [repairButton.centerYAnchor constraintEqualToAnchor:banner.centerYAnchor],
        [repairButton.widthAnchor constraintGreaterThanOrEqualToConstant:62.0],

        [label.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:14.0],
        [label.topAnchor constraintEqualToAnchor:banner.topAnchor constant:12.0],
        [label.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-12.0],
        [label.trailingAnchor constraintEqualToAnchor:repairButton.leadingAnchor constant:-10.0]
    ]];

    objc_setAssociatedObject(self, CPAssetRecoveryBannerKey, banner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)cp_repairFailedChatGPTAssets {
    NSNumber *isRepairing = objc_getAssociatedObject(self, CPAssetRecoveryRepairingKey);
    if (isRepairing.boolValue) return;

    NSArray<NSString *> *failedURLs = objc_getAssociatedObject(self, CPAssetRecoveryFailedURLsKey);
    if (![failedURLs isKindOfClass:[NSArray class]] || failedURLs.count == 0) {
        [self cp_reloadAfterAssetRepair];
        return;
    }

    objc_setAssociatedObject(self, CPAssetRecoveryRepairingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self cp_removeAssetRecoveryBanner];

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:[failedURLs subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)3, failedURLs.count))]
                                                       options:0
                                                         error:nil];
    NSString *json = jsonData ? [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] : @"[]";
    NSString *repairScript = [NSString stringWithFormat:
        @"(async()=>{const urls=%@;const results=[];for(const url of urls){try{const response=await fetch(url,{credentials:'include',cache:'reload'});if(!response.ok)throw new Error('HTTP '+response.status);const bytes=(await response.arrayBuffer()).byteLength;results.push({url,ok:true,bytes})}catch(error){results.push({url,ok:false,error:String(error?.message||error)})}}return JSON.stringify({ok:results.some(item=>item.ok),results})})()",
        json
    ];

    __weak WKWebView *weakWebView = self;
    [self evaluateJavaScript:repairScript completionHandler:^(__unused id result, __unused NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            WKWebView *webView = weakWebView;
            if (!webView) return;
            [webView cp_reloadAfterAssetRepair];
        });
    }];
}

- (void)cp_reloadAfterAssetRepair {
    NSURL *url = self.URL;
    [self stopLoading];

    if (url) {
        NSURLRequest *request = [NSURLRequest requestWithURL:url
                                                cachePolicy:NSURLRequestUseProtocolCachePolicy
                                            timeoutInterval:60.0];
        [self loadRequest:request];
    } else {
        [self loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://chatgpt.com/"]]];
    }

    __weak WKWebView *weakWebView = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WKWebView *webView = weakWebView;
        if (!webView) return;
        objc_setAssociatedObject(webView, CPAssetRecoveryRepairingKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

- (void)cp_dismissAssetRecoveryBanner {
    [self cp_removeAssetRecoveryBanner];
}

- (void)cp_removeAssetRecoveryBanner {
    UIView *banner = objc_getAssociatedObject(self, CPAssetRecoveryBannerKey);
    [banner removeFromSuperview];
    objc_setAssociatedObject(self, CPAssetRecoveryBannerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end
