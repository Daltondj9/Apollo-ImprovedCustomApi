#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "fishhook.h"
#import "RedditAPICredentialViewController.h"

static NSString * const kImgurClientID = @"IMGUR_CLIENT_ID_GOES_HERE";

static NSDictionary *stripGroupAccessAttr(CFDictionaryRef attributes) {
    NSMutableDictionary *newAttributes = [[NSMutableDictionary alloc] initWithDictionary:(__bridge id)attributes];
    [newAttributes removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
    return newAttributes;
}

static void *SecItemAdd_orig;
static OSStatus SecItemAdd_replacement(CFDictionaryRef query, CFTypeRef *result) {
	NSDictionary *strippedQuery = stripGroupAccessAttr(query);
	return ((OSStatus (*)(CFDictionaryRef, CFTypeRef *))SecItemAdd_orig)((__bridge CFDictionaryRef)strippedQuery, result);
}

static void *SecItemCopyMatching_orig;
static OSStatus SecItemCopyMatching_replacement(CFDictionaryRef query, CFTypeRef *result) {
    NSDictionary *strippedQuery = stripGroupAccessAttr(query);
	return ((OSStatus (*)(CFDictionaryRef, CFTypeRef *))SecItemCopyMatching_orig)((__bridge CFDictionaryRef)strippedQuery, result);
}

static void *SecItemUpdate_orig;
static OSStatus SecItemUpdate_replacement(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
	NSDictionary *strippedQuery = stripGroupAccessAttr(query);
	return ((OSStatus (*)(CFDictionaryRef, CFDictionaryRef))SecItemUpdate_orig)((__bridge CFDictionaryRef)strippedQuery, attributesToUpdate);
}

__attribute__ ((constructor)) static void init(void) {

	rebind_symbols((struct rebinding[3]) {
		{"SecItemAdd", SecItemAdd_replacement, (void *)&SecItemAdd_orig},
		{"SecItemCopyMatching", SecItemCopyMatching_replacement, (void *)&SecItemCopyMatching_orig},
		{"SecItemUpdate", SecItemUpdate_replacement, (void *)&SecItemUpdate_orig}
	}, 3);

	if (![[NSUserDefaults standardUserDefaults] valueForKey:@"ApolloRedditAPIClientID"]) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{

			UIWindow *mainWindow = ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject).windows.firstObject;

			UIWindow *window = [[UIWindow alloc] initWithFrame:mainWindow.frame];
			[window makeKeyAndVisible];
			[mainWindow addSubview:window];

			UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:[[UIViewController alloc] init]];
			[window addSubview:navController.view];

			RedditAPICredentialViewController *viewController = [[RedditAPICredentialViewController alloc] init];
			[navController presentViewController:viewController animated:YES completion:nil];
		});
	}

	// Reddit API Credentials
	Class _RDKOAuthCredential = objc_getClass("RDKOAuthCredential");
	if (_RDKOAuthCredential) {

		Method clientIdMethod = class_getInstanceMethod(_RDKOAuthCredential, sel_registerName("clientIdentifier"));
		IMP replacementImp = imp_implementationWithBlock(^NSString *(id _self) {
			return [[NSUserDefaults standardUserDefaults] valueForKey:@"ApolloRedditAPIClientID"];
		});

		method_setImplementation(clientIdMethod, replacementImp);
	}

	// Randomize User-Agent
	Class _RDKClient = objc_getClass("RDKClient");
	if (_RDKClient) {

		Method userAgentMethod = class_getInstanceMethod(_RDKClient, sel_registerName("userAgent"));
		IMP userAgentReplacementImp = imp_implementationWithBlock(^NSString *(id _self) {
			static dispatch_once_t once;
			static NSString *newUserAgent;
			dispatch_once(&once, ^{
				newUserAgent = [NSString stringWithFormat:@"iOS: com.%@.%@ v%d.%d.%d (by /u/%@)", RANDSTRING, RANDSTRING, RANDINT, RANDINT, RANDINT, RANDSTRING];
			});

			return newUserAgent;
		});

		method_setImplementation(userAgentMethod, userAgentReplacementImp);
	}

	// Imgur API credentials
	Class ___NSCFLocalSessionTask = objc_getClass("__NSCFLocalSessionTask");
	Method onqueueResumeMethod = class_getInstanceMethod(___NSCFLocalSessionTask, sel_registerName("_onqueue_resume"));
	IMP originalOnqueueImp = method_getImplementation(onqueueResumeMethod);
	IMP replacementOnqueueImp = imp_implementationWithBlock(^void (id _self) {

		// Grab the request url
		NSURLRequest *request =  [_self valueForKey:@"_originalRequest"];
		NSString *requestURL = request.URL.absoluteString;

		// Drop requests to analytics/apns services
		if ([requestURL containsString:@"https://apollopushserver.xyz"] || [requestURL containsString:@"telemetrydeck.com"]) {
			return;
		}

		// Catch requests to Apollo's Imgur proxy and Rapidshare. The URLs will be replaced with the real Imgur API
		if ([requestURL containsString:@"https://apollogur.download/api/"] || [requestURL containsString:@"https://imgur-apiv3.p.rapidapi.com"]) {

			NSMutableURLRequest *mutableRequest = [request mutableCopy];

			// Replace proxy urls with the real imgur api
			NSString *newURLString = [request.URL.absoluteString stringByReplacingOccurrencesOfString:@"https://apollogur.download/api/" withString:@"https://api.imgur.com/3/"];
			newURLString = [request.URL.absoluteString stringByReplacingOccurrencesOfString:@"https://imgur-apiv3.p.rapidapi.com/" withString:@"https://api.imgur.com/"];
			mutableRequest.URL = [NSURL URLWithString:newURLString];

			// Insert the api credential and update the request on this session task
			[mutableRequest setValue:[NSString stringWithFormat:@"Client-ID %@", kImgurClientID] forHTTPHeaderField:@"Authorization"];
			[_self setValue:mutableRequest forKey:@"_originalRequest"];
			[_self setValue:mutableRequest forKey:@"_currentRequest"];
		}

		((void (*)(id, SEL))originalOnqueueImp)(_self, sel_registerName("_onqueue_resume"));
	});

	method_setImplementation(onqueueResumeMethod, replacementOnqueueImp);
}
