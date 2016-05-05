//
// Copyright (c) 2014 Mixpanel. All rights reserved.

#import "Mixpanel.h"
#import "MPABTestDesignerChangeRequestMessage.h"
#import "MPABTestDesignerClearRequestMessage.h"
#import "MPABTestDesignerConnection.h"
#import "MPABTestDesignerDeviceInfoRequestMessage.h"
#import "MPABTestDesignerDisconnectMessage.h"
#import "MPABTestDesignerMessage.h"
#import "MPABTestDesignerSnapshotRequestMessage.h"
#import "MPABTestDesignerSnapshotResponseMessage.h"
#import "MPABTestDesignerTweakRequestMessage.h"
#import "MPDesignerEventBindingMessage.h"
#import "MPDesignerSessionCollection.h"
#import "MPLogger.h"
#import "MPSwizzler.h"
#import "MPResources.h"

NSString * const kSessionVariantKey = @"session_variant";
static const int connectivityIndicatorSize = 50;

@interface MPABTestDesignerConnection () <MPWebSocketDelegate>
@property (strong, nonatomic) UIWindow *connectivityIndicatorWindow;
@end

@implementation MPABTestDesignerConnection

{
    /* The difference between _open and _connected is that open
     is set when the socket is open, and _connected is set when
     we actually have started sending/receiving messages from
     the server. A connection can become _open/not _open in quick
     succession if the websocket proxy rejects the request, but
     we will only try and reconnect if we were actually _connected.
     */
    BOOL _open;
    BOOL _connected;

    NSURL *_url;
    NSMutableDictionary *_session;
    NSDictionary *_typeToMessageClassMap;
    MPWebSocket *_webSocket;
    NSOperationQueue *_commandQueue;
    CGPoint indicatorPrevPoint;
    UIDynamicAnimator *indicatorAnimator;
    void (^_connectCallback)();
    void (^_disconnectCallback)();
    
}

- (instancetype)initWithURL:(NSURL *)url keepTrying:(BOOL)keepTrying connectCallback:(void (^)())connectCallback disconnectCallback:(void (^)())disconnectCallback
{
    self = [super init];
    if (self) {
        _typeToMessageClassMap = @{
            MPABTestDesignerSnapshotRequestMessageType   : [MPABTestDesignerSnapshotRequestMessage class],
            MPABTestDesignerChangeRequestMessageType     : [MPABTestDesignerChangeRequestMessage class],
            MPABTestDesignerDeviceInfoRequestMessageType : [MPABTestDesignerDeviceInfoRequestMessage class],
            MPABTestDesignerTweakRequestMessageType      : [MPABTestDesignerTweakRequestMessage class],
            MPABTestDesignerClearRequestMessageType      : [MPABTestDesignerClearRequestMessage class],
            MPABTestDesignerDisconnectMessageType        : [MPABTestDesignerDisconnectMessage class],
            MPDesignerEventBindingRequestMessageType     : [MPDesignerEventBindingRequestMessage class],
        };

        _open = NO;
        _connected = NO;
        _sessionEnded = NO;
        _session = [[NSMutableDictionary alloc] init];
        _url = url;
        _connectCallback = connectCallback;
        _disconnectCallback = disconnectCallback;

        _commandQueue = [[NSOperationQueue alloc] init];
        _commandQueue.maxConcurrentOperationCount = 1;
        _commandQueue.suspended = YES;

        if (keepTrying) {
            [self open:YES maxInterval:30 maxRetries:40];
        } else {
            [self open:YES maxInterval:0 maxRetries:0];
        }
    }

    return self;
}

- (instancetype)initWithURL:(NSURL *)url
{
    return [self initWithURL:url keepTrying:NO connectCallback:nil disconnectCallback:nil];
}


- (void)open:(BOOL)initiate maxInterval:(int)maxInterval maxRetries:(int)maxRetries
{
    static int retries = 0;
    BOOL inRetryLoop = retries > 0;

    MessagingDebug(@"In open. initiate = %d, retries = %d, maxRetries = %d, maxInterval = %d, connected = %d", initiate, retries, maxRetries, maxInterval, _connected);

    if (self.sessionEnded || _connected || (inRetryLoop && retries >= maxRetries) ) {
        // break out of retry loop if any of the success conditions are met.
        retries = 0;
    } else if (initiate ^ inRetryLoop) {
        // If we are initiating a new connection, or we are already in a
        // retry loop (but not both). Then open a socket.
        if (!_open) {
            MessagingDebug(@"Attempting to open WebSocket to: %@, try %d/%d ", _url, retries, maxRetries);
            _open = YES;
            _webSocket = [[MPWebSocket alloc] initWithURL:_url];
            _webSocket.delegate = self;
            [_webSocket open];
        }
        if (retries < maxRetries) {
            __weak MPABTestDesignerConnection *weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MIN(pow(1.4, retries), maxInterval) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                MPABTestDesignerConnection *strongSelf = weakSelf;
                [strongSelf open:NO maxInterval:maxInterval maxRetries:maxRetries];
            });
            retries++;
        }
    }
}

- (void)close
{
    [_webSocket close];
    for (NSString *key in [_session keyEnumerator]) {
        id value = [_session valueForKey:key];
        if ([value conformsToProtocol:@protocol(MPDesignerSessionCollection)]) {
            [value cleanup];
        }
    }
    _session = nil;
}

- (void)dealloc
{
    _webSocket.delegate = nil;
    [self close];
}

- (void)setSessionObject:(id)object forKey:(NSString *)key
{
    NSParameterAssert(key != nil);

    @synchronized (_session)
    {
        _session[key] = object ?: [NSNull null];
    }
}

- (id)sessionObjectForKey:(NSString *)key
{
    NSParameterAssert(key != nil);

    @synchronized (_session)
    {
        id object = _session[key];
        return [object isEqual:[NSNull null]] ? nil : object;
    }
}

- (void)sendMessage:(id<MPABTestDesignerMessage>)message
{
    if (_connected) {
        MessagingDebug(@"Sending message: %@", [message debugDescription]);
        NSString *jsonString = [[NSString alloc] initWithData:[message JSONData] encoding:NSUTF8StringEncoding];
        [_webSocket send:jsonString];
    } else {
        MessagingDebug(@"Not sending message as we are not connected: %@", [message debugDescription]);
    }
}

- (id <MPABTestDesignerMessage>)designerMessageForMessage:(id)message
{
    MessagingDebug(@"raw message: %@", message);

    NSParameterAssert([message isKindOfClass:[NSString class]] || [message isKindOfClass:[NSData class]]);

    id <MPABTestDesignerMessage> designerMessage = nil;

    NSData *jsonData = [message isKindOfClass:[NSString class]] ? [(NSString *)message dataUsingEncoding:NSUTF8StringEncoding] : message;

    NSError *error = nil;
    id jsonObject = [NSJSONSerialization JSONObjectWithData:jsonData options:(NSJSONReadingOptions)0 error:&error];
    if ([jsonObject isKindOfClass:[NSDictionary class]]) {
        NSDictionary *messageDictionary = (NSDictionary *)jsonObject;
        NSString *type = messageDictionary[@"type"];
        NSDictionary *payload = messageDictionary[@"payload"];

        designerMessage = [_typeToMessageClassMap[type] messageWithType:type payload:payload];
    } else {
        MessagingDebug(@"Badly formed socket message expected JSON dictionary: %@", error);
    }

    return designerMessage;
}

#pragma mark - MPWebSocketDelegate Methods

- (void)webSocket:(MPWebSocket *)webSocket didReceiveMessage:(id)message
{
    if (!_connected) {
        _connected = YES;
        [self showConnectedView];
        if (_connectCallback) {
            _connectCallback();
        }
    }
    id<MPABTestDesignerMessage> designerMessage = [self designerMessageForMessage:message];
    MessagingDebug(@"WebSocket received message: %@", [designerMessage debugDescription]);

    NSOperation *commandOperation = [designerMessage responseCommandWithConnection:self];

    if (commandOperation) {
        [_commandQueue addOperation:commandOperation];
    }
}

- (void)webSocketDidOpen:(MPWebSocket *)webSocket
{
    MessagingDebug(@"WebSocket %@ did open.", webSocket);
    _commandQueue.suspended = NO;
}

- (void)webSocket:(MPWebSocket *)webSocket didFailWithError:(NSError *)error
{
    MessagingDebug(@"WebSocket did fail with error: %@", error);
    _commandQueue.suspended = YES;
    [_commandQueue cancelAllOperations];
    [self hideConnectedView];
    _open = NO;
    if (_connected) {
        _connected = NO;
        [self open:YES maxInterval:10 maxRetries:10];
        if (_disconnectCallback) {
            _disconnectCallback();
        }
    }
}

- (void)webSocket:(MPWebSocket *)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean
{
    MessagingDebug(@"WebSocket did close with code '%d' reason '%@'.", (int)code, reason);

    _commandQueue.suspended = YES;
    [_commandQueue cancelAllOperations];
    [self hideConnectedView];
    _open = NO;
    if (_connected) {
        _connected = NO;
        [self open:YES maxInterval:10 maxRetries:10];
        if (_disconnectCallback) {
            _disconnectCallback();
        }
    }
}

- (void)showConnectedView
{
    if (!self.connectivityIndicatorWindow) {
        self.connectivityIndicatorWindow = [[UIWindow alloc] initWithFrame:CGRectMake(0, 20, connectivityIndicatorSize, connectivityIndicatorSize)];
        self.connectivityIndicatorWindow.backgroundColor = [UIColor clearColor];
        self.connectivityIndicatorWindow.windowLevel = UIWindowLevelAlert;
        self.connectivityIndicatorWindow.alpha = 0;
        self.connectivityIndicatorWindow.hidden = NO;
        UIImageView *bubbleView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, connectivityIndicatorSize, connectivityIndicatorSize)];
        bubbleView.contentMode = UIViewContentModeScaleAspectFill;
        bubbleView.image = [MPResources imageNamed:@"MPConnectivityIndicator"];
        [self.connectivityIndicatorWindow addSubview:bubbleView];
        
        UIPanGestureRecognizer *panRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(moveConnectivityIndicator:)];
        [self.connectivityIndicatorWindow addGestureRecognizer:panRecognizer];
        indicatorAnimator = [[UIDynamicAnimator alloc] initWithReferenceView:self.connectivityIndicatorWindow];
        
        [UIView animateWithDuration:0.3 animations:^{
            self.connectivityIndicatorWindow.alpha = 1;
        }];
    }
}

- (void)hideConnectedView
{
    if (self.connectivityIndicatorWindow) {
        self.connectivityIndicatorWindow.hidden = YES;
    }
    
    indicatorAnimator = nil;
    self.connectivityIndicatorWindow = nil;
}

- (void)moveConnectivityIndicator:(UIPanGestureRecognizer *)gesture
{
    if (!self.connectivityIndicatorWindow) {
        return;
    }
    
    CGPoint currPoint = [gesture locationInView:gesture.view];
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: {
            [indicatorAnimator removeAllBehaviors];
            indicatorPrevPoint = currPoint;
            break;
        }
        case UIGestureRecognizerStateEnded: {
            UIWindow *mainWindow = [UIApplication sharedApplication].keyWindow;
            CGPoint velocity = [gesture velocityInView:mainWindow];
            CGFloat magnitude = sqrt((velocity.x * velocity.x) + (velocity.y * velocity.y));
            
            UICollisionBehavior *collisionBehavior = [[UICollisionBehavior alloc] initWithItems:@[self.connectivityIndicatorWindow]];
            UIBezierPath *path = [UIBezierPath bezierPathWithRect:[UIScreen mainScreen].bounds];
            [collisionBehavior addBoundaryWithIdentifier:@"border" forPath:path];
            [indicatorAnimator addBehavior:collisionBehavior];
            
            UIPushBehavior *pushBehavior = [[UIPushBehavior alloc]
                                            initWithItems:@[self.connectivityIndicatorWindow]
                                            mode:UIPushBehaviorModeInstantaneous];
            pushBehavior.pushDirection = CGVectorMake(velocity.x, velocity.y);
            pushBehavior.magnitude = magnitude / 500;
            [indicatorAnimator addBehavior:pushBehavior];
            
            UIDynamicItemBehavior *itemBehavior = [[UIDynamicItemBehavior alloc] initWithItems:@[self.connectivityIndicatorWindow]];
            itemBehavior.resistance = 10;
            itemBehavior.allowsRotation = NO;
            [indicatorAnimator addBehavior:itemBehavior];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            CGFloat newCenterX = MIN(
                                     MAX(gesture.view.center.x + (currPoint.x - indicatorPrevPoint.x), connectivityIndicatorSize/2),
                                     [UIScreen mainScreen].bounds.size.width - connectivityIndicatorSize/2
                                     );
            CGFloat newCenterY = MIN(
                                     MAX(gesture.view.center.y + (currPoint.y - indicatorPrevPoint.y), connectivityIndicatorSize/2),
                                     [UIScreen mainScreen].bounds.size.height - connectivityIndicatorSize/2
                                     );
            gesture.view.center = CGPointMake(newCenterX, newCenterY);
            break;
        }
        default:
            break;
    }
}

@end

