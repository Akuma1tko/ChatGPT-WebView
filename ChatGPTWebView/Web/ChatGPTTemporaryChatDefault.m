#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static NSString * const CPStartChatGPTChatsAsTemporaryDefaultsKey = @"StartChatGPTChatsAsTemporary";
static const void *CPTemporaryChatScriptInstalledKey = &CPTemporaryChatScriptInstalledKey;
static NSHashTable<WKWebView *> *CPTemporaryChatWebViews;

static BOOL CPStartChatGPTChatsAsTemporaryEnabled(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:CPStartChatGPTChatsAsTemporaryDefaultsKey] == nil) {
        return YES;
    }
    return [defaults boolForKey:CPStartChatGPTChatsAsTemporaryDefaultsKey];
}

static NSString *CPJavaScriptBoolean(BOOL value) {
    return value ? @"true" : @"false";
}

@interface WKWebView (ContextPortTemporaryChatDefault)
- (void)cp_temporaryChatDefault_didMoveToWindow;
@end

@implementation WKWebView (ContextPortTemporaryChatDefault)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CPTemporaryChatWebViews = [NSHashTable weakObjectsHashTable];

        Method originalMove = class_getInstanceMethod(self, @selector(didMoveToWindow));
        Method replacementMove = class_getInstanceMethod(self, @selector(cp_temporaryChatDefault_didMoveToWindow));
        method_exchangeImplementations(originalMove, replacementMove);

        [[NSNotificationCenter defaultCenter]
            addObserverForName:NSUserDefaultsDidChangeNotification
            object:nil
            queue:[NSOperationQueue mainQueue]
            usingBlock:^(__unused NSNotification *notification) {
                NSString *enabled = CPJavaScriptBoolean(CPStartChatGPTChatsAsTemporaryEnabled());
                NSString *update = [NSString stringWithFormat:
                    @"window.__contextPortTemporaryChatDefault?.setEnabled(%@)",
                    enabled
                ];

                for (WKWebView *webView in CPTemporaryChatWebViews.allObjects) {
                    [webView evaluateJavaScript:update completionHandler:nil];
                }
            }];
    });
}

- (void)cp_temporaryChatDefault_didMoveToWindow {
    [self cp_temporaryChatDefault_didMoveToWindow];
    [CPTemporaryChatWebViews addObject:self];
    [self cp_installTemporaryChatDefaultIfNeeded];
}

- (BOOL)cp_isChatGPTTemporaryChatURL:(NSURL *)url {
    NSString *host = url.host.lowercaseString;
    if (host.length == 0) return NO;
    return [host isEqualToString:@"chatgpt.com"] || [host hasSuffix:@".chatgpt.com"];
}

- (NSString *)cp_temporaryChatDefaultScript {
    NSString *enabled = CPJavaScriptBoolean(CPStartChatGPTChatsAsTemporaryEnabled());
    return [NSString stringWithFormat:
        @"(() => {"
         "if (!/(^|\\.)chatgpt\\.com$/.test(location.hostname)) return;"
         "const stateKey='__contextPortTemporaryChatDefault';"
         "const existing=window[stateKey];"
         "if(existing?.installed){existing.setEnabled(%@);return;}"
         "const state={installed:true,enabled:%@,homeHandled:false,lastPathname:location.pathname,scheduled:false,lastHref:location.href,timer:null};"
         "const isHome=()=>location.pathname==='/'||location.pathname==='';"
         "const hasTemporaryParameter=()=>new URLSearchParams(location.search).get('temporary-chat')==='true';"
         "const temporaryURL=()=>{const url=new URL(location.href);url.pathname='/';url.searchParams.set('temporary-chat','true');return url.href};"
         "const evaluate=()=>{"
           "state.scheduled=false;"
           "if(location.pathname!==state.lastPathname){state.lastPathname=location.pathname;state.homeHandled=false;}"
           "if(!isHome()){state.homeHandled=false;return;}"
           "if(hasTemporaryParameter()){state.homeHandled=true;return;}"
           "if(!state.enabled||state.homeHandled)return;"
           "state.homeHandled=true;"
           "location.replace(temporaryURL());"
         "};"
         "const schedule=()=>{if(state.scheduled)return;state.scheduled=true;requestAnimationFrame(evaluate)};"
         "state.setEnabled=enabled=>{state.enabled=Boolean(enabled);if(state.enabled)schedule()};"
         "const wrapHistoryMethod=name=>{"
           "const original=history[name];"
           "if(typeof original!=='function'||original.__contextPortTemporaryChatWrapped)return;"
           "const wrapped=function(){const result=original.apply(this,arguments);schedule();return result};"
           "wrapped.__contextPortTemporaryChatWrapped=true;"
           "history[name]=wrapped;"
         "};"
         "wrapHistoryMethod('pushState');"
         "wrapHistoryMethod('replaceState');"
         "addEventListener('popstate',schedule);"
         "addEventListener('pageshow',schedule);"
         "if(window.navigation?.addEventListener)window.navigation.addEventListener('navigatesuccess',schedule);"
         "state.timer=setInterval(()=>{if(location.href===state.lastHref)return;state.lastHref=location.href;schedule()},750);"
         "window[stateKey]=state;"
         "evaluate();"
        "})()",
        enabled,
        enabled
    ];
}

- (void)cp_installTemporaryChatDefaultIfNeeded {
    if ([objc_getAssociatedObject(self, CPTemporaryChatScriptInstalledKey) boolValue]) return;

    NSString *source = [self cp_temporaryChatDefaultScript];
    WKUserScript *script = [[WKUserScript alloc]
        initWithSource:source
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly:YES];
    [self.configuration.userContentController addUserScript:script];
    objc_setAssociatedObject(
        self,
        CPTemporaryChatScriptInstalledKey,
        @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    if ([self cp_isChatGPTTemporaryChatURL:self.URL]) {
        [self evaluateJavaScript:source completionHandler:nil];
    }
}

@end
