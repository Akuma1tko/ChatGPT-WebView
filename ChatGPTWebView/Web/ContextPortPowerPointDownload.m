#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static const void *CPDownloadProxyKey = &CPDownloadProxyKey;

static BOOL CPIsPowerPointURL(NSURL *url) {
    if (!url) return NO;
    NSString *extension = url.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"ppt"] ||
        [extension isEqualToString:@"pptx"] ||
        [extension isEqualToString:@"pps"] ||
        [extension isEqualToString:@"ppsx"]) {
        return YES;
    }

    NSString *decoded = url.absoluteString.stringByRemovingPercentEncoding.lowercaseString ?: url.absoluteString.lowercaseString;
    return [decoded containsString:@".pptx"] ||
           [decoded containsString:@".ppt"] ||
           [decoded containsString:@".ppsx"] ||
           [decoded containsString:@".pps"];
}

static BOOL CPIsPowerPointMIMEType(NSString *mimeType) {
    NSString *value = mimeType.lowercaseString;
    if (value.length == 0) return NO;
    return [value containsString:@"presentationml"] ||
           [value containsString:@"ms-powerpoint"] ||
           [value isEqualToString:@"application/vnd.ms-powerpoint"];
}

static UIViewController *CPTopViewController(UIViewController *root) {
    if ([root isKindOfClass:[UINavigationController class]]) {
        return CPTopViewController(((UINavigationController *)root).visibleViewController);
    }
    if ([root isKindOfClass:[UITabBarController class]]) {
        return CPTopViewController(((UITabBarController *)root).selectedViewController);
    }
    if (root.presentedViewController) {
        return CPTopViewController(root.presentedViewController);
    }
    return root;
}

@interface CPDownloadNavigationDelegateProxy : NSObject <WKNavigationDelegate, WKDownloadDelegate>
@property (nonatomic, weak) id<WKNavigationDelegate> forwardingDelegate;
@property (nonatomic, weak) WKWebView *webView;
@property (nonatomic, strong) NSMapTable<WKDownload *, NSURL *> *destinations;
- (instancetype)initWithDelegate:(id<WKNavigationDelegate>)delegate webView:(WKWebView *)webView;
@end

@implementation CPDownloadNavigationDelegateProxy

- (instancetype)initWithDelegate:(id<WKNavigationDelegate>)delegate webView:(WKWebView *)webView {
    self = [super init];
    if (self) {
        _forwardingDelegate = delegate;
        _webView = webView;
        _destinations = [NSMapTable weakToStrongObjectsMapTable];
    }
    return self;
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    return [super respondsToSelector:aSelector] || [self.forwardingDelegate respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    if ([self.forwardingDelegate respondsToSelector:aSelector]) {
        return self.forwardingDelegate;
    }
    return [super forwardingTargetForSelector:aSelector];
}

- (void)webView:(WKWebView *)webView
 decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
 decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    if (CPIsPowerPointURL(navigationAction.request.URL)) {
        decisionHandler(WKNavigationActionPolicyDownload);
        return;
    }

    id<WKNavigationDelegate> delegate = self.forwardingDelegate;
    if ([delegate respondsToSelector:@selector(webView:decidePolicyForNavigationAction:decisionHandler:)]) {
        [delegate webView:webView
 decidePolicyForNavigationAction:navigationAction
         decisionHandler:decisionHandler];
    } else {
        decisionHandler(WKNavigationActionPolicyAllow);
    }
}

- (void)webView:(WKWebView *)webView
 decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
 decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    NSURLResponse *response = navigationResponse.response;
    if (CPIsPowerPointURL(response.URL) || CPIsPowerPointMIMEType(response.MIMEType)) {
        decisionHandler(WKNavigationResponsePolicyDownload);
        return;
    }

    id<WKNavigationDelegate> delegate = self.forwardingDelegate;
    if ([delegate respondsToSelector:@selector(webView:decidePolicyForNavigationResponse:decisionHandler:)]) {
        [delegate webView:webView
 decidePolicyForNavigationResponse:navigationResponse
         decisionHandler:decisionHandler];
    } else {
        decisionHandler(WKNavigationResponsePolicyAllow);
    }
}

- (void)webView:(WKWebView *)webView
 navigationAction:(WKNavigationAction *)navigationAction
 didBecomeDownload:(WKDownload *)download API_AVAILABLE(ios(14.5)) {
    download.delegate = self;
}

- (void)webView:(WKWebView *)webView
 navigationResponse:(WKNavigationResponse *)navigationResponse
 didBecomeDownload:(WKDownload *)download API_AVAILABLE(ios(14.5)) {
    download.delegate = self;
}

- (void)download:(WKDownload *)download
 decideDestinationUsingResponse:(NSURLResponse *)response
 suggestedFilename:(NSString *)suggestedFilename
 completionHandler:(void (^)(NSURL * _Nullable destination))completionHandler API_AVAILABLE(ios(14.5)) {
    NSString *filename = [suggestedFilename stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (filename.length == 0) {
        filename = CPIsPowerPointMIMEType(response.MIMEType) ? @"ContextPort Download.pptx" : @"ContextPort Download.ppt";
    }
    filename = [[filename stringByReplacingOccurrencesOfString:@"/" withString:@"_"]
                stringByReplacingOccurrencesOfString:@":" withString:@"_"];

    NSURL *folder = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                              isDirectory:YES];
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtURL:folder
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:&error];
    if (error) {
        completionHandler(nil);
        return;
    }

    NSURL *destination = [folder URLByAppendingPathComponent:filename isDirectory:NO];
    [self.destinations setObject:destination forKey:download];
    completionHandler(destination);
}

- (void)downloadDidFinish:(WKDownload *)download API_AVAILABLE(ios(14.5)) {
    NSURL *destination = [self.destinations objectForKey:download];
    [self.destinations removeObjectForKey:download];
    if (!destination) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow) {
                    keyWindow = window;
                    break;
                }
            }
            if (keyWindow) break;
        }

        UIViewController *presenter = CPTopViewController(keyWindow.rootViewController);
        if (!presenter) return;

        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
            initForExportingURLs:@[destination]
            asCopy:YES];
        [presenter presentViewController:picker animated:YES completion:nil];
    });
}

- (void)download:(WKDownload *)download
 didFailWithError:(NSError *)error
 resumeData:(NSData *)resumeData API_AVAILABLE(ios(14.5)) {
    [self.destinations removeObjectForKey:download];
}

@end

@interface WKWebView (ContextPortPowerPointDownload)
- (void)cp_download_setNavigationDelegate:(id<WKNavigationDelegate>)navigationDelegate;
@end

@implementation WKWebView (ContextPortPowerPointDownload)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getInstanceMethod(self, @selector(setNavigationDelegate:));
        Method replacement = class_getInstanceMethod(self, @selector(cp_download_setNavigationDelegate:));
        method_exchangeImplementations(original, replacement);
    });
}

- (void)cp_download_setNavigationDelegate:(id<WKNavigationDelegate>)navigationDelegate {
    if (!navigationDelegate || [navigationDelegate isKindOfClass:[CPDownloadNavigationDelegateProxy class]]) {
        objc_setAssociatedObject(self, CPDownloadProxyKey, navigationDelegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self cp_download_setNavigationDelegate:navigationDelegate];
        return;
    }

    CPDownloadNavigationDelegateProxy *proxy = [[CPDownloadNavigationDelegateProxy alloc]
        initWithDelegate:navigationDelegate
        webView:self];
    objc_setAssociatedObject(self, CPDownloadProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self cp_download_setNavigationDelegate:proxy];
}

@end
