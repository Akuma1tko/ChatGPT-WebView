#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static const void *CPChatGPTScrollScriptInstalledKey = &CPChatGPTScrollScriptInstalledKey;
static const void *CPChatGPTScrollRecoveryGenerationKey = &CPChatGPTScrollRecoveryGenerationKey;

static NSString * const CPProgressiveChatAccessEnabledKey = @"ProgressiveChatAccessEnabled";
static NSString * const CPProgressiveChatAccessBucketCountKey = @"ProgressiveChatAccessBucketCount";
static NSString * const CPProgressiveAccessSettingsDidChangeNotification = @"ContextPortProgressiveAccessSettingsDidChange";

static NSHashTable<WKWebView *> *CPProgressiveAccessWebViews;

@interface WKWebView (ContextPortChatGPTScrollRecovery)
- (void)cp_scrollRecovery_didMoveToWindow;
- (void)cp_scheduleChatGPTScrollRecovery;
- (NSString *)cp_chatGPTScrollRecoveryScript;
@end

@implementation WKWebView (ContextPortChatGPTScrollRecovery)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CPProgressiveAccessWebViews = [NSHashTable weakObjectsHashTable];

        Method originalMove = class_getInstanceMethod(self, @selector(didMoveToWindow));
        Method replacementMove = class_getInstanceMethod(self, @selector(cp_scrollRecovery_didMoveToWindow));
        method_exchangeImplementations(originalMove, replacementMove);

        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserverForName:CPProgressiveAccessSettingsDidChangeNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *notification) {
            for (WKWebView *webView in CPProgressiveAccessWebViews.allObjects) {
                [webView cp_scheduleChatGPTScrollRecovery];
            }
        }];

        [center addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *notification) {
            for (WKWebView *webView in CPProgressiveAccessWebViews.allObjects) {
                if ([webView cp_boolForKey:@"ChatGPTRunRecoveryOnForegroundEnabled" defaultValue:YES]) {
                    [webView cp_scheduleChatGPTScrollRecovery];
                }
            }
        }];

        [center addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *notification) {
            for (WKWebView *webView in CPProgressiveAccessWebViews.allObjects) {
                if (![webView cp_boolForKey:@"ChatGPTRunRecoveryOnMemoryWarningEnabled" defaultValue:NO]) continue;
                [webView evaluateJavaScript:@"window.__contextPortMemoryPressureCleanup?.()" completionHandler:nil];
                [webView cp_scheduleChatGPTScrollRecovery];
            }
        }];
    });
}

- (void)cp_scrollRecovery_didMoveToWindow {
    [self cp_scrollRecovery_didMoveToWindow];
    [CPProgressiveAccessWebViews addObject:self];
    [self cp_installChatGPTScrollRecoveryScriptIfNeeded];

    if ([self cp_boolForKey:@"ChatGPTRunRecoveryOnAttachEnabled" defaultValue:YES]) {
        [self cp_scheduleChatGPTScrollRecovery];
    } else {
        [self cp_prepareNativeScrollViewForChatGPT];
    }
}

- (BOOL)cp_isChatGPTScrollRecoveryURL:(NSURL *)url {
    NSString *host = url.host.lowercaseString;
    if (host.length == 0) return NO;
    return [host isEqualToString:@"chatgpt.com"] || [host hasSuffix:@".chatgpt.com"];
}

- (BOOL)cp_boolForKey:(NSString *)key defaultValue:(BOOL)defaultValue {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:key] == nil) return defaultValue;
    return [defaults boolForKey:key];
}

- (NSInteger)cp_integerForKey:(NSString *)key
                defaultValue:(NSInteger)defaultValue
                     minimum:(NSInteger)minimum
                     maximum:(NSInteger)maximum {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSInteger value = [defaults objectForKey:key] == nil ? defaultValue : [defaults integerForKey:key];
    return MIN(MAX(value, minimum), maximum);
}

- (BOOL)cp_progressiveChatAccessEnabled {
    return [self cp_boolForKey:CPProgressiveChatAccessEnabledKey defaultValue:YES];
}

- (NSInteger)cp_progressiveAccessBucketCount {
    return [self cp_integerForKey:CPProgressiveChatAccessBucketCountKey
                    defaultValue:6
                         minimum:1
                         maximum:12];
}

- (BOOL)cp_diagnosticsEnabled {
    return [self cp_boolForKey:@"ChatGPTOptimizationDiagnosticsEnabled" defaultValue:NO];
}

- (void)cp_prepareNativeScrollViewForChatGPT {
    UIScrollView *scrollView = self.scrollView;
    BOOL forceNative = [self cp_boolForKey:@"ChatGPTForceNativeScrollEnabled" defaultValue:YES];

    if (!forceNative) {
        scrollView.directionalLockEnabled = NO;
        scrollView.bounces = YES;
        scrollView.alwaysBounceVertical = NO;
        scrollView.alwaysBounceHorizontal = NO;
        scrollView.delaysContentTouches = YES;
        scrollView.showsVerticalScrollIndicator = YES;
        scrollView.showsHorizontalScrollIndicator = YES;
        return;
    }

    scrollView.scrollEnabled = YES;
    scrollView.userInteractionEnabled = YES;
    scrollView.directionalLockEnabled = [self cp_boolForKey:@"ChatGPTDirectionalLockEnabled" defaultValue:YES];
    scrollView.panGestureRecognizer.enabled = YES;
    scrollView.delaysContentTouches = [self cp_boolForKey:@"ChatGPTDelayContentTouchesEnabled" defaultValue:NO];

    BOOL disableBounce = [self cp_boolForKey:@"ChatGPTDisableOuterBounceEnabled" defaultValue:YES];
    scrollView.bounces = !disableBounce;
    scrollView.alwaysBounceVertical = NO;
    scrollView.alwaysBounceHorizontal = NO;
    scrollView.showsVerticalScrollIndicator = [self cp_boolForKey:@"ChatGPTShowVerticalScrollIndicatorEnabled" defaultValue:YES];
    scrollView.showsHorizontalScrollIndicator = [self cp_boolForKey:@"ChatGPTShowHorizontalScrollIndicatorEnabled" defaultValue:NO];
}

- (void)cp_installChatGPTScrollRecoveryScriptIfNeeded {
    if ([objc_getAssociatedObject(self, CPChatGPTScrollScriptInstalledKey) boolValue]) return;

    WKUserScript *script = [[WKUserScript alloc]
        initWithSource:[self cp_chatGPTScrollRecoveryScript]
        injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
        forMainFrameOnly:YES];
    [self.configuration.userContentController addUserScript:script];
    objc_setAssociatedObject(self, CPChatGPTScrollScriptInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)cp_scheduleChatGPTScrollRecovery {
    NSNumber *generation = objc_getAssociatedObject(self, CPChatGPTScrollRecoveryGenerationKey);
    NSInteger nextGeneration = generation.integerValue + 1;
    objc_setAssociatedObject(
        self,
        CPChatGPTScrollRecoveryGenerationKey,
        @(nextGeneration),
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    if (![self cp_progressiveChatAccessEnabled]) return;

    [self cp_prepareNativeScrollViewForChatGPT];

    NSArray<NSNumber *> *allDelays = @[
        @0.25, @0.75, @2.0, @5.0, @10.0, @16.0,
        @24.0, @32.0, @45.0, @60.0, @90.0, @120.0
    ];
    NSInteger bucketCount = [self cp_progressiveAccessBucketCount];
    NSInteger scalePercent = [self cp_integerForKey:@"ChatGPTRecoveryDelayScalePercent"
                                       defaultValue:100
                                            minimum:25
                                            maximum:400];
    NSInteger passCount = [self cp_integerForKey:@"ChatGPTRecoveryPassCount"
                                    defaultValue:1
                                         minimum:1
                                         maximum:3];
    NSInteger passGap = [self cp_integerForKey:@"ChatGPTRecoveryPassGapSeconds"
                                  defaultValue:20
                                       minimum:5
                                       maximum:120];
    BOOL prepareEachAttempt = [self cp_boolForKey:@"ChatGPTPrepareNativeScrollEachAttemptEnabled" defaultValue:YES];

    if ([self cp_diagnosticsEnabled]) {
        NSLog(
            @"[ContextPort] Recovery buckets=%ld scale=%ld%% passes=%ld gap=%lds generation=%ld",
            (long)bucketCount,
            (long)scalePercent,
            (long)passCount,
            (long)passGap,
            (long)nextGeneration
        );
    }

    __weak WKWebView *weakWebView = self;
    for (NSInteger pass = 0; pass < passCount; pass += 1) {
        NSTimeInterval passOffset = pass * passGap;
        for (NSInteger index = 0; index < bucketCount; index += 1) {
            NSTimeInterval scaledDelay = allDelays[index].doubleValue * ((double)scalePercent / 100.0);
            NSTimeInterval delay = passOffset + scaledDelay;

            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                dispatch_get_main_queue(),
                ^{
                    WKWebView *webView = weakWebView;
                    if (!webView || ![webView cp_isChatGPTScrollRecoveryURL:webView.URL]) return;

                    NSNumber *currentGeneration = objc_getAssociatedObject(
                        webView,
                        CPChatGPTScrollRecoveryGenerationKey
                    );
                    if (currentGeneration.integerValue != nextGeneration) return;
                    if (![webView cp_progressiveChatAccessEnabled]) return;

                    if (prepareEachAttempt) {
                        [webView cp_prepareNativeScrollViewForChatGPT];
                    }
                    [webView evaluateJavaScript:[webView cp_chatGPTScrollRecoveryScript]
                              completionHandler:nil];
                }
            );
        }
    }
}

- (NSString *)cp_javascriptBoolean:(BOOL)value {
    return value ? @"true" : @"false";
}

- (NSString *)cp_chatGPTScrollRecoveryScript {
    BOOL followLatest = [self cp_boolForKey:@"ChatGPTFollowLatestEnabled" defaultValue:YES];
    BOOL startFollowing = [self cp_boolForKey:@"ChatGPTStartFollowingLatestEnabled" defaultValue:YES];
    BOOL rescanMissingTarget = [self cp_boolForKey:@"ChatGPTRescanMissingTargetEnabled" defaultValue:YES];
    BOOL includeDocumentRoots = [self cp_boolForKey:@"ChatGPTIncludeDocumentRootsEnabled" defaultValue:YES];
    BOOL preferConversation = [self cp_boolForKey:@"ChatGPTPreferConversationContainerEnabled" defaultValue:YES];
    BOOL useContentVisibility = [self cp_boolForKey:@"ChatGPTUseContentVisibilityEnabled" defaultValue:NO];
    BOOL useContainment = [self cp_boolForKey:@"ChatGPTUseCSSContainmentEnabled" defaultValue:NO];
    BOOL deferImages = [self cp_boolForKey:@"ChatGPTDeferOffscreenImagesEnabled" defaultValue:NO];
    BOOL pauseMedia = [self cp_boolForKey:@"ChatGPTPauseOffscreenMediaEnabled" defaultValue:NO];
    BOOL hideFrames = [self cp_boolForKey:@"ChatGPTHideEmbeddedFramesEnabled" defaultValue:NO];
    BOOL hideCanvas = [self cp_boolForKey:@"ChatGPTHideCanvasEnabled" defaultValue:NO];
    BOOL disableAnimations = [self cp_boolForKey:@"ChatGPTDisableAnimationsEnabled" defaultValue:NO];
    BOOL reduceEffects = [self cp_boolForKey:@"ChatGPTReduceVisualEffectsEnabled" defaultValue:NO];
    BOOL hideSidebar = [self cp_boolForKey:@"ChatGPTHideSidebarEnabled" defaultValue:NO];
    BOOL hideHeader = [self cp_boolForKey:@"ChatGPTHideHeaderEnabled" defaultValue:NO];
    BOOL optimizeCode = [self cp_boolForKey:@"ChatGPTOptimizeCodeBlocksEnabled" defaultValue:NO];
    BOOL diagnostics = [self cp_diagnosticsEnabled];
    BOOL logTargets = [self cp_boolForKey:@"ChatGPTLogTargetSelectionEnabled" defaultValue:NO];
    BOOL logCounts = [self cp_boolForKey:@"ChatGPTLogDOMCountsEnabled" defaultValue:NO];

    NSInteger followInterval = [self cp_integerForKey:@"ChatGPTFollowIntervalMilliseconds" defaultValue:500 minimum:250 maximum:3000];
    NSInteger nearBottom = [self cp_integerForKey:@"ChatGPTNearBottomThresholdPoints" defaultValue:80 minimum:20 maximum:300];
    NSInteger upwardThreshold = [self cp_integerForKey:@"ChatGPTUpwardScrollThresholdPoints" defaultValue:4 minimum:1 maximum:24];
    NSInteger scrollGuard = [self cp_integerForKey:@"ChatGPTProgrammaticScrollGuardMilliseconds" defaultValue:250 minimum:100 maximum:1500];
    NSInteger maxFollowSeconds = [self cp_integerForKey:@"ChatGPTMaximumFollowDurationSeconds" defaultValue:0 minimum:0 maximum:600];
    NSInteger minimumHeight = [self cp_integerForKey:@"ChatGPTTargetMinimumHeightPoints" defaultValue:160 minimum:80 maximum:600];
    NSInteger minimumRange = [self cp_integerForKey:@"ChatGPTTargetMinimumScrollRangePoints" defaultValue:40 minimum:20 maximum:400];
    NSInteger maximumImageHeight = [self cp_integerForKey:@"ChatGPTMaximumImageHeightPoints" defaultValue:0 minimum:0 maximum:1600];
    NSInteger optimizationInterval = [self cp_integerForKey:@"ChatGPTDOMOptimizationIntervalMilliseconds" defaultValue:2500 minimum:1000 maximum:10000];

    NSString *config = [NSString stringWithFormat:
        @"const cpConfig={followLatest:%@,startFollowing:%@,followInterval:%ld,nearBottom:%ld,upwardThreshold:%ld,scrollGuard:%ld,maxFollowSeconds:%ld,rescanMissingTarget:%@,includeDocumentRoots:%@,preferConversation:%@,minimumHeight:%ld,minimumRange:%ld,useContentVisibility:%@,useContainment:%@,deferImages:%@,pauseMedia:%@,hideFrames:%@,hideCanvas:%@,disableAnimations:%@,reduceEffects:%@,hideSidebar:%@,hideHeader:%@,optimizeCode:%@,maximumImageHeight:%ld,optimizationInterval:%ld,diagnostics:%@,logTargets:%@,logCounts:%@};",
        [self cp_javascriptBoolean:followLatest],
        [self cp_javascriptBoolean:startFollowing],
        (long)followInterval,
        (long)nearBottom,
        (long)upwardThreshold,
        (long)scrollGuard,
        (long)maxFollowSeconds,
        [self cp_javascriptBoolean:rescanMissingTarget],
        [self cp_javascriptBoolean:includeDocumentRoots],
        [self cp_javascriptBoolean:preferConversation],
        (long)minimumHeight,
        (long)minimumRange,
        [self cp_javascriptBoolean:useContentVisibility],
        [self cp_javascriptBoolean:useContainment],
        [self cp_javascriptBoolean:deferImages],
        [self cp_javascriptBoolean:pauseMedia],
        [self cp_javascriptBoolean:hideFrames],
        [self cp_javascriptBoolean:hideCanvas],
        [self cp_javascriptBoolean:disableAnimations],
        [self cp_javascriptBoolean:reduceEffects],
        [self cp_javascriptBoolean:hideSidebar],
        [self cp_javascriptBoolean:hideHeader],
        [self cp_javascriptBoolean:optimizeCode],
        (long)maximumImageHeight,
        (long)optimizationInterval,
        [self cp_javascriptBoolean:diagnostics],
        [self cp_javascriptBoolean:logTargets],
        [self cp_javascriptBoolean:logCounts]
    ];

    NSMutableString *script = [NSMutableString stringWithString:@"(() => { try {"];
    [script appendString:config];
    [script appendString:
        @"if (!/(^|\\.)chatgpt\\.com$/.test(location.hostname)) return false;"
         "const stateKey='__contextPortChatScrollRecoveryState';"
         "const currentURL=location.href;"
         "const signature=JSON.stringify(cpConfig);"
         "const previous=window[stateKey];"
         "if(previous&&previous.signature!==signature){"
           "if(previous.followTimer)clearInterval(previous.followTimer);"
           "if(previous.domTimer)clearInterval(previous.domTimer);"
           "previous.followTimer=null;previous.domTimer=null;"
         "}"
         "const state=previous||{url:currentURL,followLatest:cpConfig.startFollowing,scrollTarget:null,scrollListener:null,lastTop:0,programmaticUntil:0,followTimer:null,domTimer:null,followStartedAt:Date.now(),signature:null};"
         "state.signature=signature;window[stateKey]=state;"
         "const turnSelector='[data-message-author-role],section[data-testid^=conversation-turn-],[data-testid*=conversation-turn]';"
         "const candidateSelector='main,[role=main],[data-scroll-root],[class*=overflow-y-auto],[class*=overflow-y-scroll],[style*=overflow-y]';"
         "const distanceFromBottom=e=>Math.max(0,e.scrollHeight-e.clientHeight-e.scrollTop);"
         "const visible=e=>{const r=e.getBoundingClientRect();return r.width>0&&r.height>0&&r.bottom>0&&r.top<innerHeight};"
         "const offscreen=e=>{const r=e.getBoundingClientRect();return r.bottom<-innerHeight||r.top>innerHeight*2};"
         "const detachTarget=()=>{if(state.scrollTarget&&state.scrollListener)state.scrollTarget.removeEventListener('scroll',state.scrollListener);state.scrollTarget=null;state.scrollListener=null;state.lastTop=0};"
         "state.resetForURL=url=>{state.url=url;state.followLatest=cpConfig.startFollowing;state.followStartedAt=Date.now();state.programmaticUntil=0;detachTarget()};"
         "if(state.url!==currentURL)state.resetForURL(currentURL);"
         "const usable=e=>e instanceof HTMLElement&&e.isConnected&&visible(e)&&e.clientHeight>=cpConfig.minimumHeight&&e.scrollHeight-e.clientHeight>=cpConfig.minimumRange;"
         "const findBest=()=>{"
           "const roots=cpConfig.includeDocumentRoots?[document.scrollingElement,document.documentElement,document.body]:[];"
           "const items=[...roots,...document.querySelectorAll(candidateSelector)];let best=null,bestScore=-1;"
           "for(const e of [...new Set(items.filter(Boolean))]){if(!(e instanceof HTMLElement))continue;const range=Math.max(0,e.scrollHeight-e.clientHeight);if(range<cpConfig.minimumRange||e.clientHeight<cpConfig.minimumHeight||!visible(e))continue;const owns=Boolean(e.querySelector(turnSelector));const main=e.matches('main,[role=main]')||Boolean(e.closest('main,[role=main]'));let score=range+e.clientHeight*4;if(cpConfig.preferConversation){score+=owns?10000000:0;score+=main?1000000:0}if(score>bestScore){best=e;bestScore=score}}"
           "if(cpConfig.diagnostics&&cpConfig.logTargets)console.log('[ContextPort] scroll target',best,{bestScore,items:items.length});return best"
         "};"
         "const configure=e=>{e.style.setProperty('overflow-y','auto','important');e.style.setProperty('overflow-x','hidden','important');e.style.setProperty('-webkit-overflow-scrolling','touch','important');e.style.setProperty('touch-action','pan-y','important');e.style.setProperty('overscroll-behavior-y','contain','important');e.style.setProperty('overscroll-behavior-x','none','important');document.documentElement.style.setProperty('overflow-x','hidden','important');document.body?.style.setProperty('overflow-x','hidden','important')};"
         "const attach=e=>{if(state.scrollTarget===e&&state.scrollListener)return;detachTarget();state.scrollTarget=e;state.lastTop=e.scrollTop;state.scrollListener=()=>{const top=e.scrollTop,distance=distanceFromBottom(e);if(Date.now()<state.programmaticUntil){state.lastTop=top;return}if(distance<=cpConfig.nearBottom){state.followLatest=true;state.followStartedAt=Date.now()}else if(top<state.lastTop-cpConfig.upwardThreshold){state.followLatest=false}state.lastTop=top};e.addEventListener('scroll',state.scrollListener,{passive:true});configure(e)};"
         "const acquire=force=>{if(force){state.followLatest=true;state.followStartedAt=Date.now()}if(usable(state.scrollTarget))return state.scrollTarget;if(!cpConfig.rescanMissingTarget&&state.scrollTarget)return null;detachTarget();const target=findBest();if(!target)return null;attach(target);return target};"
         "const pin=e=>{if(distanceFromBottom(e)<=2){state.lastTop=e.scrollTop;return}state.programmaticUntil=Date.now()+cpConfig.scrollGuard;e.scrollLeft=0;e.scrollTop=e.scrollHeight;state.lastTop=e.scrollTop};"
         "const styleID='contextport-chat-optimization-style';"
         "const ensureStyle=()=>{let s=document.getElementById(styleID);if(!s){s=document.createElement('style');s.id=styleID;(document.head||document.documentElement).appendChild(s)}let css='';if(cpConfig.disableAnimations)css+='*,*::before,*::after{animation:none!important;transition:none!important;scroll-behavior:auto!important}';if(cpConfig.reduceEffects)css+='*{backdrop-filter:none!important;filter:none!important;text-shadow:none!important;box-shadow:none!important}';if(cpConfig.hideSidebar)css+='aside,nav[aria-label*=Chat],nav[aria-label*=chat]{display:none!important}';if(cpConfig.hideHeader)css+='header{display:none!important}';if(cpConfig.hideFrames)css+='iframe{display:none!important}';if(cpConfig.hideCanvas)css+='canvas{display:none!important}';s.textContent=css};"
         "const optimizeDOM=()=>{ensureStyle();const turns=[...document.querySelectorAll(turnSelector)];for(const turn of turns){const old=offscreen(turn);if(cpConfig.useContentVisibility){turn.style.setProperty('content-visibility','auto','important');turn.style.setProperty('contain-intrinsic-size','1px 500px','important')}else{turn.style.removeProperty('content-visibility');turn.style.removeProperty('contain-intrinsic-size')}if(cpConfig.useContainment&&old)turn.style.setProperty('contain','layout paint style','important');else turn.style.removeProperty('contain');for(const img of turn.querySelectorAll('img')){if(cpConfig.deferImages&&old){img.loading='lazy';img.decoding='async';try{img.fetchPriority='low'}catch(_){}}if(cpConfig.maximumImageHeight>0)img.style.setProperty('max-height',cpConfig.maximumImageHeight+'px','important');else img.style.removeProperty('max-height')}for(const media of turn.querySelectorAll('video,audio')){if(cpConfig.pauseMedia&&old){try{media.pause()}catch(_){}media.preload='none'}}for(const pre of turn.querySelectorAll('pre')){if(cpConfig.optimizeCode){pre.style.setProperty('content-visibility','auto','important');pre.style.setProperty('contain-intrinsic-size','1px 240px','important')}else{pre.style.removeProperty('content-visibility');pre.style.removeProperty('contain-intrinsic-size')}}}if(cpConfig.diagnostics&&cpConfig.logCounts)console.log('[ContextPort] DOM counts',{turns:turns.length,images:document.images.length,frames:document.querySelectorAll('iframe').length,media:document.querySelectorAll('video,audio').length})};"
         "const tick=()=>{if(location.href!==state.url)state.resetForURL(location.href);if(!cpConfig.followLatest||!state.followLatest)return;if(cpConfig.maxFollowSeconds>0&&Date.now()-state.followStartedAt>cpConfig.maxFollowSeconds*1000){state.followLatest=false;return}const target=acquire(false);if(target)pin(target)};"
         "window.__contextPortScrollToBottom=()=>{const target=acquire(true);if(!target)return false;pin(target);return true};"
         "window.__contextPortIsFollowingLatest=()=>Boolean(state.followLatest);"
         "window.__contextPortMemoryPressureCleanup=()=>{optimizeDOM();for(const media of document.querySelectorAll('video,audio')){if(offscreen(media)){try{media.pause()}catch(_){}media.preload='none'}}return true};"
         "optimizeDOM();tick();"
         "if(!state.followTimer)state.followTimer=setInterval(tick,cpConfig.followInterval);"
         "if(!state.domTimer)state.domTimer=setInterval(optimizeDOM,cpConfig.optimizationInterval);"
         "return true;"
         "}catch(error){try{console.error('[ContextPort] optimization error',error)}catch(_){}return false}})()"
    ];
    return script;
}

@end
