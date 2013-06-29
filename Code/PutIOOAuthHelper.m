//
//  PutIOOAuthHelper.m
//  Put.io for Mac
//
//  Created by Boris Bügling on 29.06.13.
//  Copyright (c) 2013 Boris Bügling. All rights reserved.
//

#import <AFNetworking/AFNetworking.h>
#import <PutioKit/PutioKit.h>
#import <PutioKit/PutIONetworkConstants.h>

#import "PutIOOAuthHelper.h"

// https://put.io/v2/docs/#authentication

// The order of this is

// Redirect to the OAuth dialog
// Put in the creds ourselves
// Get redirected to the "accept the application page" tap via js
// Then call to putio:/ method which is treated as an error.

@interface PutIOOAuthHelper () {
    NSString *_username;
    NSString *_password;
    BOOL _attemptedLogin;
}
@end

#pragma mark -

@implementation PutIOOAuthHelper

- (id)init {
    self = [super init];
    if (self) {
        self.webView = [[WebView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 0.0, 0.0)];
    }
    return self;
}

- (void)loginWithUsername:(NSString *)username andPassword:(NSString *)password {
    _webView.frameLoadDelegate = self;
    _attemptedLogin = NO;
    
    [self loadAuthPage];
    _username = username;
    _password = password;
}

- (void)loadAuthPage {
    NSString *address = [NSString stringWithFormat:PKFormatOauthLoginURL, _clientID, PKAppOAuthCallback];
    NSURL * url = [NSURL URLWithString:address];
    [_webView.mainFrame loadRequest:[NSURLRequest requestWithURL:url]];
}

#pragma mark -
#pragma mark Webview delegate methods

-(void)webView:(WebView *)sender didStartProvisionalLoadForFrame:(WebFrame *)frame {
    // After you log in, it redrects to root, we actually want it
    if ([[frame.dataSource.request.URL absoluteString] isEqualToString:PKRootURL] ||
        [[frame.dataSource.request.URL absoluteString] hasPrefix: @"https://put.io/search"]) {
        [self loadAuthPage];
        [frame stopLoading];
    }
}

- (void)getAccessTokenFromOauthCode:(NSString *)code {
    // https://api.put.io/v2/oauth2/access_token?client_id=YOUR_CLIENT_ID&client_secret=YOUR_CLIENT_SECRET&grant_type=authorization_code&redirect_uri=YOUR_REGISTERED_REDIRECT_URI&code=CODE
    
    NSString *address = [NSString stringWithFormat:PTFormatOauthTokenURL, _clientID, _clientSecret, @"authorization_code", PKCallbackOriginal, code];
    
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:address]];
    AFJSONRequestOperation *operation = [AFJSONRequestOperation JSONRequestOperationWithRequest:request success:^(NSURLRequest *request, NSHTTPURLResponse *response, id JSON) {
        
        NSString *appAuthToken = [JSON valueForKeyPath:@"access_token"];
        [[NSUserDefaults standardUserDefaults] setObject:appAuthToken forKey:PKAppAuthTokenDefault];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [[NSNotificationCenter defaultCenter] postNotificationName:PKAppAuthTokenUpdatedNotification object:nil];
        [self.delegate authHelperDidLogin:self];
        
    } failure:^(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error, id JSON) {
        NSLog(@"error %@", error);
    }];
    [operation start];
}

- (void)webView:(WebView *)sender didFailLoadWithError:(NSError *)error forFrame:(WebFrame *)frame {
    if (error.code == 101) {
        NSString *code = [error userInfo][@"NSErrorFailingURLStringKey"];
        NSString *seperator = @"%3D";
        
        if ([code rangeOfString:@"="].location != NSNotFound) {
            seperator = @"=";
        }
        NSArray *URLComponents = [code componentsSeparatedByString:seperator];
        
        // We've successfully got a code from the callback
        // now we just need to get the OAuth token
        
        if (URLComponents.count > 1) {
            [self getAccessTokenFromOauthCode:URLComponents[1]];
        }
    }else{
        if (error.code == 102 || error.code == -999) {
            // no-op as the puttio:// url causes both errors 101/102
        }else if (error.code == -1009) {
            [self.delegate authHelperLoginFailedWithDescription:@"You are currently offline."];
        }else {
            // actually unexpected
            [self.delegate authHelperHasDeclaredItScrewed];
        }
    }
}

- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame {
    NSString *address = frame.dataSource.request.URL.absoluteString;
    NSString *loginpath = @"oauth2/login";
    
    // Load the Oauth Page, look for the right input boxes then submit the form
    if([address rangeOfString:loginpath].location != NSNotFound && !_attemptedLogin){
        _attemptedLogin = YES;
        NSString *setUsername = [NSString stringWithFormat:@"document.querySelectorAll('input[type=text]')[0].value = '%@'", _username];
        [_webView stringByEvaluatingJavaScriptFromString:setUsername];
        
        NSString *setPassword = [NSString stringWithFormat:@"  document.querySelectorAll('input[type=password]')[0].value = '%@'", _password];
        [_webView stringByEvaluatingJavaScriptFromString:setPassword];
        
        [_webView stringByEvaluatingJavaScriptFromString:@"document.getElementsByTagName('form')[0].submit()"];
    }
    
    // If we're redirected to the same page its because the auth is bad probably
    else if([address rangeOfString:loginpath].location != NSNotFound && _attemptedLogin){
        [self.delegate authHelperLoginFailedWithDescription:@"Wrong Username / Password combo"];
    }
    
    // If we're asked for the Allow / Deny form hit the allow button
    else if ([address rangeOfString:@"oauth2/authenticate"].location != NSNotFound) {
        NSString *submitForm = @"document.getElementsByTagName('input[type=submit]')[0].click()";
        [_webView stringByEvaluatingJavaScriptFromString:submitForm];
        
    } else if ([address rangeOfString:@"put.io/login"].location != NSNotFound) {
        // Do nothing as this is whilst we're grabbing the tokens
    }
    
    // No idea what's going on anymore, show the OAuth Screen and hope for the best.
    else {
        [self.delegate authHelperHasDeclaredItScrewed];
    }
}

@end
