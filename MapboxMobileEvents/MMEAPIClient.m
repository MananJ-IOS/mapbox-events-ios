#import "MMEAPIClient.h"
#import "MMEAPIClient_Private.h"
#import "MMEConstants.h"
#import "MMENSURLSessionWrapper.h"
#import "MMEDate.h"
#import "MMEEvent.h"
#import "MMEMetricsManager.h"
#import "MMEEventsManager.h"
#import "MMEEventsManager_Private.h"
#import "MMELogger.h"
#import "NSError+APIClient.h"
#import "NSURLRequest+APIClientFactory.h"
#import "MMENSURLRequestFactory.h"

#import "NSData+MMEGZIP.h"
#import "NSUserDefaults+MMEConfiguration.h"
#import "NSUserDefaults+MMEConfiguration_Private.h"

@import MobileCoreServices;

// MARK: -

@interface MMEAPIClient ()
@property (nonatomic) NSTimer *configurationUpdateTimer;
@property (nonatomic) id<MMENSURLSessionWrapper> sessionWrapper;
@property (nonatomic) NSBundle *applicationBundle;
@property (nonatomic) MMEMetricsManager *metricsManager;
@property (nonatomic) id<MMEEventConfigProviding> config;
@property (nonatomic) MMENSURLRequestFactory *requestFactory;

@end

int const kMMEMaxRequestCount = 1000;

// MARK: -

@implementation MMEAPIClient


- (instancetype)initWithConfig:(id <MMEEventConfigProviding>)config
                metricsManager:(MMEMetricsManager*)metricsManager {
    self = [super init];
    if (self) {
        _config = config;
        _requestFactory = [[MMENSURLRequestFactory alloc] initWithConfig:config];
        _sessionWrapper = [[MMENSURLSessionWrapper alloc] init];
        self.metricsManager = metricsManager;
        [self startGettingConfigUpdates];
    }
    return self;
}

- (void) dealloc {
    [self stopGettingConfigUpdates];
    [self.sessionWrapper invalidate];
}

// MARK: - Events Service

- (NSArray *)batchFromEvents:(NSArray *)events {
    NSMutableArray *eventBatches = [[NSMutableArray alloc] init];
    int eventsRemaining = (int)[events count];
    int i = 0;
    
    while (eventsRemaining) {
        NSRange range = NSMakeRange(i, MIN(kMMEMaxRequestCount, eventsRemaining));
        NSArray *batchArray = [events subarrayWithRange:range];
        [eventBatches addObject:batchArray];
        eventsRemaining -= range.length;
        i += range.length;
    }
    
    return eventBatches;
}

- (void)postEvents:(NSArray *)events completionHandler:(nullable void (^)(NSError * _Nullable error))completionHandler {
    [self.metricsManager updateMetricsFromEventQueue:events];
    
    NSArray *eventBatches = [self batchFromEvents:events];
    
    for (NSArray *batch in eventBatches) {
        NSURLRequest *request = [self requestForEvents:batch];
        if (request) {
            [self.sessionWrapper processRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
                // check the response object for HTTP error code
                if (response && [response isKindOfClass:NSHTTPURLResponse.class]) {
                    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                    NSError *statusError = [[NSError alloc] initWith:request httpResponse:httpResponse error:error];

                    if (statusError) { // report the status error
                        [MMEEventsManager.sharedManager reportError:statusError];
                    }

                    // check the data object, log the Rx bytes and try to load the config
                    if (data) {
                        [self.metricsManager updateReceivedBytes:data.length];
                    }
                }
                else if (error) { // check the session error and report it if the response appears invalid
                    [MMEEventsManager.sharedManager reportError:error];
                }
                
                [self.metricsManager updateMetricsFromEventCount:events.count request:request error:error];
                
                if (completionHandler) {
                    completionHandler(error);
                }
            }];
        }
        [self.metricsManager updateMetricsFromEventCount:events.count request:nil error:nil];
    }

    [self.metricsManager generateTelemetryMetricsEvent];
}

- (void)postEvent:(MMEEvent *)event completionHandler:(nullable void (^)(NSError * _Nullable error))completionHandler {
    [self postEvents:@[event] completionHandler:completionHandler];
}

// MARK: - Metadata Service

- (void)postMetadata:(NSArray *)metadata filePaths:(NSArray *)filePaths completionHandler:(nullable void (^)(NSError * _Nullable error))completionHandler {
    NSString *boundary = NSUUID.UUID.UUIDString;
    NSData *binaryData = [self createBodyWithBoundary:boundary metadata:metadata filePaths:filePaths];
    NSURLRequest* request = [self.requestFactory multipartURLRequestWithMethod:MMEAPIClientHTTPMethodPost
                                                                       baseURL:self.config.mme_eventsServiceURL
                                                                          path:MMEAPIClientAttachmentsPath
                                                             additionalHeaders:@{}
                                                                          data:binaryData
                                                                      boundary:boundary];

    [self.sessionWrapper processRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        
        // check the response object for HTTP error code
        if (response && [response isKindOfClass:NSHTTPURLResponse.class]) {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            NSError *statusError = [[NSError alloc] initWith:request httpResponse:httpResponse error:error];

            if (statusError) { // always report the status error
                [MMEEventsManager.sharedManager reportError:statusError];
            }
            
            if (data) { // always log the Rx bytes
                [self.metricsManager updateReceivedBytes:data.length];
            }
        }
        else if (error) { // check the session error and report it if the response appears invalid
            [MMEEventsManager.sharedManager reportError:error];
        }

        [self.metricsManager updateMetricsFromEventCount:filePaths.count request:request error:error];
        [self.metricsManager generateTelemetryMetricsEvent];
        
        if (completionHandler) {
            completionHandler(error);
        }
    }];
}

// MARK: - Configuration Service

- (void)startGettingConfigUpdates {
    if (self.isGettingConfigUpdates) {
        [self stopGettingConfigUpdates];
    }

    if (@available(iOS 10.0, macos 10.12, tvOS 10.0, watchOS 3.0, *)) {

        __weak __typeof__(self) weakSelf = self;
        self.configurationUpdateTimer = [NSTimer
            scheduledTimerWithTimeInterval:NSUserDefaults.mme_configuration.mme_configUpdateInterval
            repeats:YES
            block:^(NSTimer * _Nonnull timer) {

                __strong __typeof__(weakSelf) strongSelf = weakSelf;
                if (strongSelf == nil) {
                    return;
                }

                NSURLRequest *request = [NSURLRequest configurationRequest];
                [strongSelf.sessionWrapper processRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
                    // check the response object for HTTP error code, update the local clock offset
                    if (response && [response isKindOfClass:NSHTTPURLResponse.class]) {
                        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                        NSError *statusError = [[NSError alloc] initWith:request httpResponse:httpResponse error:error];

                        if (!statusError) {
                            // check for time-offset from the server
                            NSString *dateHeader = httpResponse.allHeaderFields[@"Date"];
                            if (dateHeader) {
                                // parse the server date, compute the offset
                                NSDate *date = [MMEDate.HTTPDateFormatter dateFromString:dateHeader];
                                if (date) {
                                    [MMEDate recordTimeOffsetFromServer:date];
                                } // else failed to parse date
                            }

                            // check the data object, log the Rx bytes and try to load the config
                            if (data) {
                                [self.metricsManager updateReceivedBytes:data.length];

                                NSError *configError = [NSUserDefaults.mme_configuration mme_updateFromConfigServiceData:(NSData * _Nonnull)data];
                                if (configError) {
                                    [MMEEventsManager.sharedManager reportError:configError];
                                }
                                
                                NSUserDefaults.mme_configuration.mme_configUpdateDate = MMEDate.date;
                            }
                        }
                        else {
                            [MMEEventsManager.sharedManager reportError:statusError];
                        }
                    }
                    else if (error) { // check the session error and report it if the response appears invalid
                        [MMEEventsManager.sharedManager reportError:error];
                    }

                    [self.metricsManager updateMetricsFromEventCount:0 request:request error:error];
                    [self.metricsManager generateTelemetryMetricsEvent];
                }];
            }];
        
        // be power conscious and give this timer a minute of slack so it can be coalesced
        self.configurationUpdateTimer.tolerance = 60;

        // check to see if time since the last update is greater than our update interval
        if (!NSUserDefaults.mme_configuration.mme_configUpdateDate // we've never updated
         || (fabs(NSUserDefaults.mme_configuration.mme_configUpdateDate.timeIntervalSinceNow)
          > NSUserDefaults.mme_configuration.mme_configUpdateInterval)) { // or it's been a while
            [self.configurationUpdateTimer fire]; // update now
        }
    }
}

- (void)stopGettingConfigUpdates {
    [self.configurationUpdateTimer invalidate];
    self.configurationUpdateTimer = nil;
}

- (BOOL)isGettingConfigUpdates {
    return self.configurationUpdateTimer.isValid;
}

// MARK: - Utilities

- (NSURLRequest *)requestForEvents:(NSArray *)events {

    NSMutableArray *eventAttributes = [NSMutableArray arrayWithCapacity:events.count];
    [events enumerateObjectsUsingBlock:^(MMEEvent * _Nonnull event, NSUInteger idx, BOOL * _Nonnull stop) {
        if (event.attributes) {
            [eventAttributes addObject:event.attributes];
        }
    }];

    NSDictionary<NSString*, NSString*>* additionalHeaders = @{
        MMEAPIClientHeaderFieldContentTypeKey: MMEAPIClientHeaderFieldContentTypeValue
    };

    NSError* jsonError = nil;
    NSURLRequest* request = [self.requestFactory urlRequestWithMethod:MMEAPIClientHTTPMethodPost
                                      baseURL:self.config.mme_eventsServiceURL
                                         path:MMEAPIClientEventsPath
                            additionalHeaders:additionalHeaders
                                   shouldGZIP: events.count >= 2
                                   jsonObject:eventAttributes
                                        error:&jsonError];

   if (jsonError) {
        [self.metricsManager.logger logEvent:[MMEEvent debugEventWithError:jsonError]];
        return nil;
    }
    
    return [request copy];
}

- (NSString *)mimeTypeForPath:(NSString *)path {
    CFStringRef extension = (__bridge CFStringRef)[path pathExtension];
    CFStringRef UTI = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, extension, NULL);
    if (UTI == NULL) {
        return nil;
    }
    
    NSString *mimetype = CFBridgingRelease(UTTypeCopyPreferredTagWithClass(UTI, kUTTagClassMIMEType));
    
    CFRelease(UTI);
    
    return mimetype;
}

- (NSData *)createBodyWithBoundary:(NSString *)boundary metadata:(NSArray *)metadata filePaths:(NSArray *)filePaths {
    NSMutableData *httpBody = [NSMutableData data];
    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:metadata options:0 error:&jsonError];

    [httpBody appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [httpBody appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"attachments\"\r\n"] dataUsingEncoding:NSUTF8StringEncoding]];

    if (jsonData) { // add json metadata part
        [httpBody appendData:[[NSString stringWithFormat:@"Content-Type: application/json\r\n\r\n"] dataUsingEncoding:NSUTF8StringEncoding]];
        [httpBody appendData:jsonData];
        [httpBody appendData:[[NSString stringWithFormat:@"\r\n\r\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    } else if (jsonError) {
        [self.metricsManager.logger logEvent:[MMEEvent debugEventWithError:jsonError]];
    }

    for (NSString *path in filePaths) { // add a file part for each
        NSString *filename  = [path lastPathComponent];
        NSData   *data      = [NSData dataWithContentsOfFile:path];
        NSString *mimetype  = [self mimeTypeForPath:path];

        [httpBody appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
        [httpBody appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"file\"; filename=\"%@\"\r\n", filename] dataUsingEncoding:NSUTF8StringEncoding]];
        [httpBody appendData:[[NSString stringWithFormat:@"Content-Type: %@\r\n\r\n", mimetype] dataUsingEncoding:NSUTF8StringEncoding]];
        [httpBody appendData:data];
        [httpBody appendData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    }
    
    [httpBody appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    
    return httpBody;
}

@end
