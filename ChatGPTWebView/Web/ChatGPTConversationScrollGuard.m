#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static const void *CPConversationScrollGuardInstalledKey = &CPConversationScrollGuardInstalledKey;

@interface WKWebView (ContextPortConversationScrollGuard)
- (void)cp_conversationScrollGuard_didMoveToWindow;
@end

@implementation WKWebView (ContextPortConversationScrollGuard)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method originalMove = class_getInstanceMethod(self, @selector(didMoveToWindow));
        Method replacementMove = class_getInstanceMethod(self, @selector(cp_conversationScrollGuard_didMoveToWindow));
        method_exchangeImplementations(originalMove, replacementMove);
    });
}

- (void)cp_conversationScrollGuard_didMoveToWindow {
    [self cp_conversationScrollGuard_didMoveToWindow];
    [self cp_installConversationScrollGuardIfNeeded];
}

- (BOOL)cp_isChatGPTConversationScrollGuardURL:(NSURL *)url {
    NSString *host = url.host.lowercaseString;
    if (host.length == 0) return NO;
    return [host isEqualToString:@"chatgpt.com"] || [host hasSuffix:@".chatgpt.com"];
}

- (void)cp_installConversationScrollGuardIfNeeded {
    if ([objc_getAssociatedObject(self, CPConversationScrollGuardInstalledKey) boolValue]) return;

    NSString *source = @"(() => {"
        "if (!/(^|\\.)chatgpt\\.com$/.test(location.hostname)) return;"
        "if (window.__contextPortConversationScrollGuard?.installed) return;"
        "const turnSelector='[data-message-author-role],section[data-testid^=conversation-turn-],[data-testid*=conversation-turn]';"
        "const surfaceSelector='[role=dialog],[aria-modal=true],aside,nav,[data-testid*=sidebar],[data-testid*=settings],[data-testid*=modal],[class*=sidebar],[class*=settings],[class*=modal],[class*=drawer]';"
        "const guard={installed:true,pausedByGuard:false,resumeWasEnabled:false,scheduled:false,timer:null,observer:null};"
        "const visible=e=>{if(!(e instanceof Element)||!e.isConnected)return false;const r=e.getBoundingClientRect();const s=getComputedStyle(e);return r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden'&&s.opacity!=='0'};"
        "const pointTurn=()=>{const points=[[.5,.2],[.5,.4],[.5,.6],[.5,.8],[.25,.35],[.75,.35],[.25,.7],[.75,.7]];for(const p of points){const hit=document.elementFromPoint(innerWidth*p[0],innerHeight*p[1]);const turn=hit?.closest?.(turnSelector);if(turn&&visible(turn))return turn}return null};"
        "const state=()=>window.__contextPortChatScrollRecoveryState;"
        "const ownsConversation=e=>e instanceof HTMLElement&&Boolean(e.querySelector(turnSelector));"
        "const blockingSurface=()=>{for(const e of document.querySelectorAll(surfaceSelector)){if(!visible(e))continue;const r=e.getBoundingClientRect();if(e.matches('[role=dialog],[aria-modal=true]')||r.width>=innerWidth*.65||r.height>=innerHeight*.65)return e}return null};"
        "const detachInvalidTarget=s=>{const target=s?.scrollTarget;if(!target||ownsConversation(target))return;if(s.scrollListener)try{target.removeEventListener('scroll',s.scrollListener)}catch(_){}s.scrollTarget=null;s.scrollListener=null;s.lastTop=0};"
        "const pause=()=>{const s=state();if(!s)return;if(!guard.pausedByGuard)guard.resumeWasEnabled=Boolean(s.followLatest);guard.pausedByGuard=true;s.followLatest=false;detachInvalidTarget(s)};"
        "const evaluate=()=>{guard.scheduled=false;const s=state();if(!s)return;const target=s.scrollTarget;if(target&&!ownsConversation(target)){pause();return}const turn=pointTurn();const blocked=blockingSurface();if(!turn&&blocked){pause();return}if(guard.pausedByGuard&&turn&&!blocked){const resume=guard.resumeWasEnabled;guard.pausedByGuard=false;guard.resumeWasEnabled=false;if(resume){s.followLatest=true;s.followStartedAt=Date.now()}}};"
        "const schedule=()=>{if(guard.scheduled)return;guard.scheduled=true;requestAnimationFrame(evaluate)};"
        "document.addEventListener('scroll',event=>{const target=event.target===document?document.scrollingElement:event.target;if(!(target instanceof Element)||ownsConversation(target))return;if(target.matches(surfaceSelector)||target.closest(surfaceSelector))pause()},{capture:true,passive:true});"
        "for(const type of ['wheel','touchstart','pointerdown'])document.addEventListener(type,event=>{const target=event.target instanceof Element?event.target:null;if(!target)return;if(target.matches(surfaceSelector)||target.closest(surfaceSelector)){pause();return}const control=target.closest('button,a,[role=button]');if(control&&!control.closest(turnSelector)){const label=String(control.getAttribute('aria-label')||control.getAttribute('title')||control.innerText||control.textContent||'');if(/settings|sidebar|menu|navigation|profile|account/i.test(label))pause()}},{capture:true,passive:true});"
        "document.addEventListener('focusin',event=>{const target=event.target instanceof Element?event.target:null;if(target&&(target.matches(surfaceSelector)||target.closest(surfaceSelector)))pause()},true);"
        "guard.observer=new MutationObserver(schedule);"
        "const observe=()=>{const root=document.documentElement;if(!root){setTimeout(observe,0);return}guard.observer.observe(root,{subtree:true,childList:true,attributes:true,attributeFilter:['aria-hidden','aria-modal','data-state','open','style']})};"
        "window.__contextPortConversationScrollGuard=guard;"
        "observe();"
        "guard.timer=setInterval(evaluate,200);"
        "evaluate();"
    "})()";

    WKUserScript *script = [[WKUserScript alloc]
        initWithSource:source
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
        forMainFrameOnly:YES];
    [self.configuration.userContentController addUserScript:script];
    objc_setAssociatedObject(self, CPConversationScrollGuardInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if ([self cp_isChatGPTConversationScrollGuardURL:self.URL]) {
        [self evaluateJavaScript:source completionHandler:nil];
    }
}

@end
