/*
 Copyright 2017 OpenMarket Ltd

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "MXRoomSummary.h"

#import "MXRoom.h"
#import "MXSession.h"

#import <objc/runtime.h>
#import <objc/message.h>

NSString *const kMXRoomSummaryDidChangeNotification = @"kMXRoomSummaryDidChangeNotification";

@implementation MXRoomSummary

- (instancetype)initWithRoomId:(NSString *)theRoomId andMatrixSession:(MXSession *)matrixSession
{
    self = [super init];
    if (self)
    {
        _roomId = theRoomId;
        _mxSession = matrixSession;
        _stateOthers = [NSMutableDictionary dictionary];
        _lastEventOthers = [NSMutableDictionary dictionary];
        _others = [NSMutableDictionary dictionary];

        // Listen to the event sent state changes
        // This is used to follow evolution of local echo events
        // (ex: when a sentState change from sending to sentFailed)
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(eventDidChangeSentState:) name:kMXEventDidChangeSentStateNotification object:nil];
    }

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:kMXEventDidChangeSentStateNotification object:nil];
}

- (void)setMatrixSession:(MXSession *)mxSession
{
    _mxSession = mxSession;
}

- (void)save
{
    if ([_mxSession.store respondsToSelector:@selector(storeSummaryForRoom:summary:)])
    {
        [_mxSession.store storeSummaryForRoom:_roomId summary:self];
    }
    if ([_mxSession.store respondsToSelector:@selector(commit)])
    {
        [_mxSession.store commit];
    }

    // Broadcast the change
    [[NSNotificationCenter defaultCenter] postNotificationName:kMXRoomSummaryDidChangeNotification object:self userInfo:nil];
}

- (MXRoom *)room
{
    // That makes self.room a really weak reference
    return [_mxSession roomWithRoomId:_roomId];
}

#pragma mark - Data related to room state

- (void)resetRoomStateData
{
    // Reset data
    MXRoom *room = self.room;

    // @TODO: Manage all summary state properties
    _avatar = room.state.avatar;
    _displayname = room.state.displayname;
    _topic = room.state.topic;
    [_stateOthers removeAllObjects];

    // @TODO: How to call the update?
}


#pragma mark - Data related to the last event

- (MXEvent *)lastEvent
{
    MXEvent *lastEvent;

    // Is it a true matrix event or a local echo?
    if (![_lastEventId hasPrefix:kMXEventLocalEventIdPrefix])
    {
        lastEvent = [_mxSession.store eventWithEventId:_lastEventId inRoom:_roomId];
    }
    else
    {
        for (MXEvent *event in [_mxSession.store outgoingMessagesInRoom:_roomId])
        {
            if ([event.eventId isEqualToString:_lastEventId])
            {
                lastEvent = event;
                break;
            }
        }
    }

    return lastEvent;
}

- (MXHTTPOperation *)resetLastEvent:(void (^)())complete failure:(void (^)(NSError *))failure
{
    _lastEventId = nil;
    _lastEventString = nil;
    _lastEventAttribytedString = nil;
    [_lastEventOthers removeAllObjects];

    MXHTTPOperation *operation;
    [self fetchLastEvent:complete failure:failure lastEventIdChecked:nil operation:&operation];
    return operation;
}

/**
 Find the event to be used as last event.

 @param success A block object called when the operation completes.
 @param failure A block object called when the operation fails.
 @param lastEventIdChecked the id of the event candidate to be the room last event.
        Nil means we will start checking from the last event in the store.
 @param operation the current http operation if any.
        The method may need several requests before fetching the right last event. 
        If it happens, the first one is mutated with [MXHTTPOperation mutateTo:].
 */
- (void)fetchLastEvent:(void (^)())complete failure:(void (^)(NSError *))failure lastEventIdChecked:(NSString*)lastEventIdChecked operation:(MXHTTPOperation **)operation
{
    MXRoom *room = self.room;
    if (!room)
    {
        if (failure)
        {
            failure(nil);
        }
    }

    // Start by checking events we have in the store
    MXRoomState *state = self.room.state;
    id<MXEventsEnumerator> messagesEnumerator = room.enumeratorForStoredMessages;
    MXEvent *event = messagesEnumerator.nextEvent;

    // 1.1 Find where we stopped at the previous call
    if (lastEventIdChecked)
    {
        while (event)
        {
            if ([event.eventId isEqualToString:lastEventIdChecked])
            {
                event = messagesEnumerator.nextEvent;
                break;
            }
        }
    }

    // Check events one by one until finding the right last event for the room
    BOOL lastEventUpdated = NO;
    while (event)
    {
        if (event.isState)
        {
            // @TODO: udpate state
        }

        // Decrypt event if necessary
        if (event.eventType == MXEventTypeRoomEncrypted)
        {
            if (![self.mxSession decryptEvent:event inTimeline:nil])
            {
                NSLog(@"[MXKRoomDataSource] lastMessageWithEventFormatter: Warning: Unable to decrypt event: %@\nError: %@", event.content[@"body"], event.decryptionError);
            }
        }

        lastEventIdChecked = event.eventId;

        // Propose the event as last event
        lastEventUpdated = [_mxSession.roomSummaryUpdateDelegate session:_mxSession updateRoomSummary:self withLastEvent:event oldState:state];
        if (lastEventUpdated)
        {
            break;
        }

        event = messagesEnumerator.nextEvent;
    }

    // If lastEventId is still nil, fetch events from the homeserver
    if (!_lastEventId && [room.liveTimeline canPaginate:MXTimelineDirectionBackwards])
    {
        // Reset pagination the first time
        if (!*operation)
        {
            [room.liveTimeline resetPagination];
        }

        // Paginate events from the homeserver
        MXHTTPOperation *newOperation;
        newOperation = [room.liveTimeline paginate:30 direction:MXTimelineDirectionBackwards onlyFromStore:NO complete:^{

            // Received messages have been stored in the store. We can make a new loop
            [self fetchLastEvent:complete failure:failure lastEventIdChecked:lastEventIdChecked operation:operation];

        } failure:failure];

        // Update the current HTTP operation
        if (!*operation)
        {
            *operation = newOperation;
        }
        else
        {
            [(*operation) mutateTo:newOperation];
        }

    }
    else
    {
        if (complete)
        {
            complete();
        }

        [self save];
    }

}

- (void)eventDidChangeSentState:(NSNotification *)notif
{
    MXEvent *event = notif.object;

    // If the last event is a local echo, update it.
    // Do nothing when its sentState becomes sent. In this case, the last event will be
    // updated by the true event coming back from the homeserver.
    if (event.sentState != MXEventSentStateSent && [event.eventId isEqualToString:_lastEventId])
    {
        [self handleEvent:event];
    }
}

#pragma mark - Server sync
- (void)handleJoinedRoomSync:(MXRoomSync*)roomSync
{
    // Handle first changes due to state events
    BOOL updated = NO;
    for (MXEvent *event in roomSync.state.events)
    {
        updated |= [_mxSession.roomSummaryUpdateDelegate session:_mxSession updateRoomSummary:self withStateEvent:event];
    }

    // There may be state events in the timeline too
    for (MXEvent *event in roomSync.timeline.events)
    {
        if (event.isState)
        {
            updated |= [_mxSession.roomSummaryUpdateDelegate session:_mxSession updateRoomSummary:self withStateEvent:event];
        }
    }

    // Handle the last event starting by the more recent one
    // Then, if the delegate refuses it as last event, pass the previous event.
    BOOL lastEventUpdated = NO;
    MXRoomState *state = self.room.state;
    for (MXEvent *event in roomSync.timeline.events.reverseObjectEnumerator)
    {
        if (event.isState)
        {
            // @TODO: udpate state
        }

        lastEventUpdated = [_mxSession.roomSummaryUpdateDelegate session:_mxSession updateRoomSummary:self withLastEvent:event oldState:state];
        if (lastEventUpdated)
        {
            break;
        }
    }

    if (updated || lastEventUpdated)
    {
        [self save];
    }
}

- (void)handleInvitedRoomSync:(MXInvitedRoomSync*)invitedRoomSync
{
    BOOL updated = NO;

    for (MXEvent *event in invitedRoomSync.inviteState.events)
    {
        updated |= [_mxSession.roomSummaryUpdateDelegate session:_mxSession updateRoomSummary:self withStateEvent:event];
    }

    // Fake the last event with the invitation event contained in invitedRoomSync.inviteState
    // @TODO: Make sure that is true
    [_mxSession.roomSummaryUpdateDelegate session:_mxSession updateRoomSummary:self withLastEvent:invitedRoomSync.inviteState.events.lastObject oldState:self.room.state];

    if (updated)
    {
        [self save];
    }
}


#pragma mark - Single update

- (void)handleEvent:(MXEvent*)event
{
    MXRoom *room = self.room;

    if (room)
    {
        BOOL updated = [_mxSession.roomSummaryUpdateDelegate session:_mxSession updateRoomSummary:self withLastEvent:event oldState:room.state];

        if (updated)
        {
            [self save];
        }
    }
}



#pragma mark - NSCoding
- (instancetype)initWithCoder:(NSCoder *)aDecoder
{
    self = [self init];
    if (self)
    {
        _roomId = [aDecoder decodeObjectForKey:@"roomId"];

        for (NSString *key in [MXRoomSummary propertyKeys])
        {
            id value = [aDecoder decodeObjectForKey:key];
            if (value)
            {
                [self setValue:value forKey:key];
            }
        }
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder
{
    [aCoder encodeObject:_roomId forKey:@"roomId"];

    for (NSString *key in [MXRoomSummary propertyKeys])
    {
        id value = [self valueForKey:key];
        if (value)
        {
            [aCoder encodeObject:value forKey:key];
        }
    }
}

// Took at http://stackoverflow.com/a/8938097
// in order to automatically NSCoding the class properties
+ (NSArray *)propertyKeys
{
    static NSMutableArray *propertyKeys;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        
        propertyKeys = [NSMutableArray array];
        Class class = [self class];
        while (class != [NSObject class])
        {
            unsigned int propertyCount;
            objc_property_t *properties = class_copyPropertyList(class, &propertyCount);
            for (int i = 0; i < propertyCount; i++)
            {
                //get property
                objc_property_t property = properties[i];
                const char *propertyName = property_getName(property);
                NSString *key = [NSString stringWithCString:propertyName encoding:NSUTF8StringEncoding];

                //check if read-only
                BOOL readonly = NO;
                const char *attributes = property_getAttributes(property);
                NSString *encoding = [NSString stringWithCString:attributes encoding:NSUTF8StringEncoding];
                if ([[encoding componentsSeparatedByString:@","] containsObject:@"R"])
                {
                    readonly = YES;
                }

                if (!readonly)
                {
                    //exclude read-only properties
                    [propertyKeys addObject:key];
                }
            }
            free(properties);
            class = [class superclass];
        }


        NSLog(@"[MXRoomSummary] Stored properties: %@", propertyKeys);
    });

    return propertyKeys;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"%@ %@: %@ - %@", super.description, _roomId, _displayname, _lastEventString];
}


@end
