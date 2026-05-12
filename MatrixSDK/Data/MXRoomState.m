/*
 Copyright 2014 OpenMarket Ltd
 Copyright 2017 Vector Creations Ltd
 
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

#import "MXRoomState.h"

#import "MXSDKOptions.h"

#import "MXSession.h"
#import "MXTools.h"
#import "MXCallManager.h"

@interface MXRoomState ()
{
    MXSession *mxSession;

    /**
     State events ordered by type.
     */
    NSMutableDictionary<NSString*, NSMutableArray<MXEvent*>*> *stateEvents;

    /**
     The room aliases. The key is the domain.
     */
    NSMutableDictionary<NSString*, MXEvent*> *roomAliases;

    /**
     The third party invites. The key is the token provided by the homeserver.
     */
    NSMutableDictionary<NSString*, MXRoomThirdPartyInvite*> *thirdPartyInvites;

    /**
     Maximum power level observed in power level list
     */
    NSInteger maxPowerLevel;

    /** Synchronises access to mutable room state. Recursive because back-state processing can recurse. */
    NSRecursiveLock *stateLock;

    /**
     Cache for [self memberWithThirdPartyInviteToken].
     The key is the 3pid invite token.
     */
    NSMutableDictionary<NSString*, MXRoomMember*> *membersWithThirdPartyInviteTokenCache;

    /**
     The cache for the conference user id.
     */
    NSString *conferenceUserId;
}
@end

@implementation MXRoomState
@synthesize powerLevels;

- (id)initWithRoomId:(NSString*)roomId
    andMatrixSession:(MXSession*)matrixSession
        andDirection:(BOOL)isLive
{
    self = [super init];
    if (self)
    {
        mxSession = matrixSession;
        _roomId = roomId;
        
        _isLive = isLive;
        stateLock = [NSRecursiveLock new];
        stateEvents = [NSMutableDictionary dictionary];
        _members = [[MXRoomMembers alloc] initWithRoomState:self andMatrixSession:mxSession];
        _membersCount = [[MXRoomMembersCount alloc] initWithMembers:_members.members.count
                                                             joined:_members.joinedMembers.count
                                                            invited:[_members membersWithMembership:MXMembershipInvite].count];
        roomAliases = [NSMutableDictionary dictionary];
        thirdPartyInvites = [NSMutableDictionary dictionary];
        membersWithThirdPartyInviteTokenCache = [NSMutableDictionary dictionary];
    }
    return self;
}

- (id)initWithRoomId:(NSString*)roomId
    andMatrixSession:(MXSession*)matrixSession
         andInitialSync:(MXRoomInitialSync*)initialSync
        andDirection:(BOOL)isLive
{
    self = [self initWithRoomId:roomId andMatrixSession:matrixSession andDirection:isLive];
    if (self)
    {
        // Store optional metadata
        if (initialSync)
        {
            if (initialSync.membership)
            {
                _membership = [MXTools membership:initialSync.membership];
            }
        }
    }
    return self;
}

+ (void)loadRoomStateFromStore:(id<MXStore>)store
                  withRoomId:(NSString *)roomId
               matrixSession:(MXSession *)matrixSession
                  onComplete:(void (^)(MXRoomState *roomState))onComplete
{
    NSString *logId = [NSUUID UUID].UUIDString;
    MXLogDebug(@"[MXRoomState] loadRoomStateFromStore(%@): Loading state for room %@", logId, roomId)
    
    MXRoomState *roomState = [[MXRoomState alloc] initWithRoomId:roomId andMatrixSession:matrixSession andDirection:YES];
    if (roomState)
    {
        [store stateOfRoom:roomId success:^(NSArray<MXEvent *> * _Nonnull stateEvents) {
            if (!stateEvents.count) {
                MXLogWarning(@"[MXRoomState] loadRoomStateFromStore(%@): No state events stored, loading from API", logId);
                
                if (!matrixSession)
                {
                    MXLogError(@"[MXRoomState] loadRoomStateFromStore: Missing session, unable to load from API")
                    onComplete(roomState);
                }
                else
                {
                    [matrixSession.matrixRestClient stateOfRoom:roomId success:^(NSArray *JSONData) {
                        NSArray<MXEvent *> *events = [MXEvent modelsFromJSON:JSONData];
                        MXLogDebug(@"[MXRoomState] loadRoomStateFromStore(%@): Loaded %lu events from api", logId, events.count);
                        
                        [roomState handleStateEvents:events];
                        onComplete(roomState);
                    } failure:^(NSError *error) {
                        NSDictionary *details = @{
                            @"log_id": logId ?: @"unknown",
                            @"error": error ?: @"unknown"
                        };
                        MXLogErrorDetails(@"[MXRoomState] loadRoomStateFromStore: Failed to load any events from API", details);
                        
                        onComplete(roomState);
                    }];
                }
            } else {
                MXLogDebug(@"[MXRoomState] loadRoomStateFromStore(%@): Initializing with %lu state events", logId, stateEvents.count);
                
                [roomState handleStateEvents:stateEvents];
                onComplete(roomState);
            }

        } failure:nil];
    }
}

- (id)initBackStateWith:(MXRoomState*)state
{
    self = [state copy];
    if (self)
    {
        _isLive = NO;
        _members = [[MXRoomMembers alloc] initWithMembers:_members isLive:NO];

        // At the beginning of pagination, the back room state must be the same
        // as the current current room state.
        // So, use the same state events content.
        // @TODO: Find another way than modifying the event content.
        [stateLock lock];
        for (NSArray<MXEvent*> *events in stateEvents.allValues)
        {
            for (MXEvent *event in events)
            {
                event.prevContent = event.content;
            }
        }
        [stateLock unlock];
    }
    return self;
}

// According to the direction of the instance, we are interested either by
// the content of the event or its prev_content
- (NSDictionary<NSString *, id> *)contentOfEvent:(MXEvent*)event
{
    NSDictionary<NSString *, id> *content;
    if (event)
    {
        if (_isLive)
        {
            content = event.content;
        }
        else
        {
            content = event.prevContent;
        }
    }
    return content;
}

/** Build a writable copy of state events. Caller must hold stateLock. */
- (NSMutableDictionary<NSString *, NSMutableArray<MXEvent *> *> *)mutableStateEventsCopyLocked
{
    NSMutableDictionary<NSString *, NSMutableArray<MXEvent *> *> *stateEventsCopy = [[NSMutableDictionary alloc] initWithCapacity:stateEvents.count];
    for (NSString *key in stateEvents)
    {
        stateEventsCopy[key] = [stateEvents[key] mutableCopy];
    }
    return stateEventsCopy;
}

/** Build state events array. Caller must hold stateLock. */
- (NSArray<MXEvent *> *)stateEventsSnapshotLocked
{
    NSMutableArray<MXEvent *> *state = [NSMutableArray array];
    for (NSArray<MXEvent*> *events in stateEvents.allValues)
    {
        [state addObjectsFromArray:events];
    }
    for (MXRoomMember *roomMember in _members.members)
    {
        [state addObject:roomMember.originalEvent];
    }
    for (MXEvent *event in roomAliases.allValues)
    {
        [state addObject:event];
    }
    for (MXRoomThirdPartyInvite *thirdPartyInvite in thirdPartyInvites.allValues)
    {
        [state addObject:thirdPartyInvite.originalEvent];
    }
    return state;
}

- (NSArray<MXEvent *> *)stateEvents
{
    [stateLock lock];
    NSArray<MXEvent *> *state = [self stateEventsSnapshotLocked];
    [stateLock unlock];
    return state;
}

- (NSArray<MXRoomThirdPartyInvite *> *)thirdPartyInvites
{
    [stateLock lock];
    NSArray *invites = [thirdPartyInvites.allValues copy];
    [stateLock unlock];
    return invites;
}

- (NSArray<NSString *> *)relatedGroups
{
    [stateLock lock];
    NSArray<NSString *> *relatedGroups;
    MXEvent *event = [stateEvents objectForKey:kMXEventTypeStringRoomRelatedGroups].lastObject;
    if (event && [self contentOfEvent:event])
    {
        MXJSONModelSetArray(relatedGroups, [self contentOfEvent:event][@"groups"]);
        relatedGroups = [relatedGroups copy];
    }
    [stateLock unlock];
    return relatedGroups;
}

- (NSArray<NSString *> *)aliases
{
    NSMutableArray<NSString *> *aliases = [NSMutableArray array];
    
    // Merge here all the bunches of aliases (one bunch by domain)
    for (MXEvent *event in roomAliases.allValues)
    {
        NSDictionary<NSString *, id> *eventContent = [self contentOfEvent:event];
        NSArray<NSString *> *aliasesBunch = eventContent[@"aliases"];
        
        if ([aliasesBunch isKindOfClass:[NSArray class]] && aliasesBunch.count)
        {
            [aliases addObjectsFromArray:aliasesBunch];
        }
    }
    
    //  include canonicalAlias into aliases array
    NSString *canonicalAlias = self.canonicalAlias;
    if (canonicalAlias)
    {
        [aliases addObject:canonicalAlias];
    }
    
    return aliases.count ? aliases : nil;
}

- (NSString*)canonicalAlias
{
    [stateLock lock];
    NSString *canonicalAlias;
    MXEvent *event = [stateEvents objectForKey:kMXEventTypeStringRoomCanonicalAlias].lastObject;
    if (event && [self contentOfEvent:event])
    {
        MXJSONModelSetString(canonicalAlias, [self contentOfEvent:event][@"alias"]);
        canonicalAlias = [canonicalAlias copy];
    }
    [stateLock unlock];
    return canonicalAlias;
}

- (NSString *)name
{
    [stateLock lock];
    NSString *name;
    MXEvent *event = [stateEvents objectForKey:kMXEventTypeStringRoomName].lastObject;
    if (event && [self contentOfEvent:event])
    {
        MXJSONModelSetString(name, [self contentOfEvent:event][@"name"]);
        name = [name copy];
    }
    [stateLock unlock];
    return name;
}

- (NSString *)topic
{
    [stateLock lock];
    NSString *topic;
    MXEvent *event = [stateEvents objectForKey:kMXEventTypeStringRoomTopic].lastObject;
    if (event && [self contentOfEvent:event])
    {
        MXJSONModelSetString(topic, [self contentOfEvent:event][@"topic"]);
        topic = [topic copy];
    }
    [stateLock unlock];
    return topic;
}

- (NSString *)avatar
{
    [stateLock lock];
    NSString *avatar;
    MXEvent *event = [stateEvents objectForKey:kMXEventTypeStringRoomAvatar].lastObject;
    if (event && [self contentOfEvent:event])
    {
        MXJSONModelSetString(avatar, [self contentOfEvent:event][@"url"]);
        avatar = [avatar copy];
    }
    [stateLock unlock];
    return avatar;
}

- (NSString *)roomVersion
{
    [stateLock lock];
    NSString *roomVersion;
    MXEvent *event = [stateEvents objectForKey:kMXEventTypeStringRoomCreate].lastObject;
    NSDictionary<NSString *, id> *eventContent = [self contentOfEvent:event];
    if (event && eventContent)
    {
        MXJSONModelSetString(roomVersion, eventContent[@"room_version"]);
        roomVersion = [roomVersion copy];
    }
    [stateLock unlock];
    return roomVersion;
}

- (NSString *)creatorUserId
{
    [stateLock lock];
    NSString *creatorUserId;
    MXEvent *event = [stateEvents objectForKey:kMXEventTypeStringRoomCreate].lastObject;
    NSString* sender = [event sender];
    if (event && sender)
    {
        creatorUserId = [sender copy];
    }
    [stateLock unlock];
    return creatorUserId;
}

- (NSArray<NSString*> *)additionalCreators
{
    [stateLock lock];
    NSArray<NSString*> *additionalCreators = @[];
    MXEvent *event = [stateEvents objectForKey:kMXEventTypeStringRoomCreate].lastObject;
    NSDictionary<NSString *, id> *eventContent = [self contentOfEvent:event];
    if (event && eventContent)
    {
        MXJSONModelSetArray(additionalCreators, eventContent[@"additional_creators"]);
        additionalCreators = [additionalCreators copy];
    }
    [stateLock unlock];
    return additionalCreators;
}

- (MXRoomHistoryVisibility)historyVisibility
{
    [stateLock lock];
    MXRoomHistoryVisibility historyVisibility = kMXRoomHistoryVisibilityShared;
    MXEvent *event = [stateEvents objectForKey:kMXEventTypeStringRoomHistoryVisibility].lastObject;
    if (event && [self contentOfEvent:event])
    {
        MXJSONModelSetString(historyVisibility, [self contentOfEvent:event][@"history_visibility"]);
        historyVisibility = [historyVisibility copy];
    }
    [stateLock unlock];
    return historyVisibility;
}

- (MXRoomJoinRule)joinRule
{
    [stateLock lock];
    MXRoomJoinRule joinRule = kMXRoomJoinRuleInvite;
    MXEvent *event = [stateEvents objectForKey:kMXEventTypeStringRoomJoinRules].lastObject;
    if (event && [self contentOfEvent:event])
    {
        MXJSONModelSetString(joinRule, [self contentOfEvent:event][@"join_rule"]);
        joinRule = [joinRule copy];
    }
    [stateLock unlock];
    return joinRule;
}

- (BOOL)isJoinRulePublic
{
    return [self.joinRule isEqualToString:kMXRoomJoinRulePublic];
}

- (MXRoomGuestAccess)guestAccess
{
    [stateLock lock];
    MXRoomGuestAccess guestAccess = kMXRoomGuestAccessForbidden;
    MXEvent *event = [stateEvents objectForKey:kMXEventTypeStringRoomGuestAccess].lastObject;
    if (event && [self contentOfEvent:event])
    {
        MXJSONModelSetString(guestAccess, [self contentOfEvent:event][@"guest_access"]);
        guestAccess = [guestAccess copy];
    }
    [stateLock unlock];
    return guestAccess;
}

- (BOOL)isEncrypted
{
    [stateLock lock];
    BOOL isEncrypted = stateEvents[kMXEventTypeStringRoomEncryption] != nil;
    [stateLock unlock];
    return isEncrypted;
}

- (NSArray<NSString *> *)pinnedEvents
{
    [stateLock lock];
    NSArray<NSString *> *pinnedEvents;
    MXEvent *event = stateEvents[kMXEventTypeStringRoomPinnedEvents].lastObject;
    MXJSONModelSetArray(pinnedEvents, [self contentOfEvent:event][@"pinned"]);
    [stateLock unlock];
    return pinnedEvents;
}

- (NSString *)encryptionAlgorithm
{
    [stateLock lock];
    NSString *algorithm = [stateEvents[kMXEventTypeStringRoomEncryption].lastObject.content[@"algorithm"] copy];
    [stateLock unlock];
    return algorithm;
}

- (BOOL)isObsolete
{
    return self.tombStoneContent != nil;
}

- (MXRoomTombStoneContent*)tombStoneContent
{
    [stateLock lock];
    MXRoomTombStoneContent *roomTombStoneContent = nil;
    MXEvent *event = stateEvents[kMXEventTypeStringRoomTombStone].lastObject;
    NSDictionary *eventContent = [self contentOfEvent:event];
    if (eventContent)
    {
        roomTombStoneContent = [MXRoomTombStoneContent modelFromJSON:eventContent];
    }
    [stateLock unlock];
    return roomTombStoneContent;
}

- (NSArray<MXBeaconInfo*>*)beaconInfos
{
    NSMutableArray *beaconInfoEvents = [NSMutableArray new];
    
    NSArray *stateEvents = [self stateEventsWithType:kMXEventTypeStringBeaconInfoMSC3672];
    
    for (MXEvent *event in stateEvents)
    {
        MXBeaconInfo *beaconInfo = [[MXBeaconInfo alloc] initWithMXEvent:event];
        
        if (beaconInfo)
        {
            [beaconInfoEvents addObject:beaconInfo];
        }
    }
    
    return beaconInfoEvents;
}

#pragma mark - State events handling
- (void)handleStateEvents:(NSArray<MXEvent *> *)events;
{
    NSMutableArray<MXRoomMember *> *conferenceUserUpdates;
    NSArray<MXEvent *> *stateSnapshot = nil;
    NSString *roomIdSnapshot = nil;
    BOOL shouldPersistState = NO;
    __block NSMutableDictionary<NSString *, NSMutableArray<MXEvent *> *> *updatedStateEvents = nil;
    __block NSMutableDictionary<NSString *, MXEvent *> *updatedRoomAliases = nil;
    __block NSMutableDictionary<NSString *, MXRoomThirdPartyInvite *> *updatedThirdPartyInvites = nil;
    __block NSMutableDictionary<NSString *, MXRoomMember *> *updatedMembersWithThirdPartyInviteTokenCache = nil;

    void (^commitPendingDictionaryUpdates)(void) = ^{
        if (updatedStateEvents)
        {
            stateEvents = updatedStateEvents;
            updatedStateEvents = nil;
        }
        if (updatedRoomAliases)
        {
            roomAliases = updatedRoomAliases;
            updatedRoomAliases = nil;
        }
        if (updatedThirdPartyInvites)
        {
            thirdPartyInvites = updatedThirdPartyInvites;
            updatedThirdPartyInvites = nil;
        }
        if (updatedMembersWithThirdPartyInviteTokenCache)
        {
            membersWithThirdPartyInviteTokenCache = updatedMembersWithThirdPartyInviteTokenCache;
            updatedMembersWithThirdPartyInviteTokenCache = nil;
        }
    };

    [stateLock lock];
    // Process the update on room members
    if ([_members handleStateEvents:events])
    {
        // Update counters for currently known room members
        _membersCount.members = _members.members.count;
        _membersCount.joined = _members.joinedMembers.count;
        _membersCount.invited =  [_members membersWithMembership:MXMembershipInvite].count;
    }

    @autoreleasepool
    {
        for (MXEvent *event in events)
        {
            switch (event.eventType)
            {
                case MXEventTypeRoomMember:
                {
                    // User in this membership event
                    NSString *userId = event.stateKey ? event.stateKey : event.sender;

                    NSDictionary *content = [self contentOfEvent:event];

                    // Compute my user membership indepently from MXRoomMembers
                    if ([userId isEqualToString:mxSession.myUserId])
                    {
                        MXRoomMember *roomMember = [[MXRoomMember alloc] initWithMXEvent:event andEventContent:content];
                        _membership = roomMember.membership;
                    }

                    if (content[@"third_party_invite"][@"signed"][@"token"])
                    {
                        // Cache room member event that is successor of a third party invite event
                        MXRoomMember *roomMember = [[MXRoomMember alloc] initWithMXEvent:event andEventContent:content];
                        if (roomMember.thirdPartyInviteToken.length)
                        {
                            if (!updatedMembersWithThirdPartyInviteTokenCache)
                            {
                                updatedMembersWithThirdPartyInviteTokenCache = [membersWithThirdPartyInviteTokenCache mutableCopy];
                            }
                            updatedMembersWithThirdPartyInviteTokenCache[roomMember.thirdPartyInviteToken] = roomMember;
                        }
                    }

                    // In case of invite, process the provided but incomplete room state
                    if (self.membership == MXMembershipInvite && event.inviteRoomState)
                    {
                        commitPendingDictionaryUpdates();
                        [self handleStateEvents:event.inviteRoomState];
                    }
                    else if (_isLive && self.membership == MXMembershipJoin && _membersCount.members > 2)
                    {
                        if ([userId isEqualToString:self.conferenceUserId])
                        {
                            MXRoomMember *roomMember = [[MXRoomMember alloc] initWithMXEvent:event andEventContent:content];
                            if (!conferenceUserUpdates)
                            {
                                conferenceUserUpdates = [NSMutableArray array];
                            }
                            [conferenceUserUpdates addObject:roomMember];
                        }
                    }

                    break;
                }
                    case MXEventTypeRoomThirdPartyInvite:
                    {
                        // The content and the prev_content of a m.room.third_party_invite event are the same.
                        // So, use isLive to know if the invite must be added or removed (case of back state).
                        if (_isLive)
                        {
                            MXRoomThirdPartyInvite *thirdPartyInvite = [[MXRoomThirdPartyInvite alloc] initWithMXEvent:event];
                            if (thirdPartyInvite.token.length)
                            {
                                if (!updatedThirdPartyInvites)
                                {
                                    updatedThirdPartyInvites = [thirdPartyInvites mutableCopy];
                                }
                                updatedThirdPartyInvites[thirdPartyInvite.token] = thirdPartyInvite;
                            }
                        }
                        else
                        {
                            // Note: the 3pid invite token is stored in the event state key
                            if (event.stateKey.length)
                            {
                                if (!updatedThirdPartyInvites)
                                {
                                    updatedThirdPartyInvites = [thirdPartyInvites mutableCopy];
                                }
                                [updatedThirdPartyInvites removeObjectForKey:event.stateKey];
                            }
                        }
                        break;
                    }
                    case MXEventTypeRoomAliases:
                    {
                        // Sanity check
                        if (event.stateKey.length)
                        {
                            // Store the bunch of aliases for the domain (which is the state_key)
                            if (!updatedRoomAliases)
                            {
                                updatedRoomAliases = [roomAliases mutableCopy];
                            }
                            updatedRoomAliases[event.stateKey] = event;
                        }
                        break;
                    }
                    case MXEventTypeRoomPowerLevels:
                    {
                        powerLevels = [MXRoomPowerLevels modelFromJSON:[self contentOfEvent:event]];
                        // Compute max power level
                        maxPowerLevel = powerLevels.usersDefault;
                        NSArray<NSNumber *> *array = powerLevels.users.allValues;
                        for (NSNumber *powerLevel in array)
                        {
                            NSInteger level = 0;
                            MXJSONModelSetInteger(level, powerLevel);
                            if (level > maxPowerLevel)
                            {
                                maxPowerLevel = level;
                            }
                        }

                        // Do not break here to store the event into the stateEvents dictionary.
                    }
                    default:
                    {
                        // Store other states into the stateEvents dictionary.
                        MXEventTypeString eventType = event.type;
                        if (!eventType.length)
                        {
                            MXLogWarning(@"[MXRoomState] handleStateEvents: Ignore malformed state event with no type. roomId: %@ eventId: %@", _roomId, event.eventId);
                            break;
                        }

                        if (!updatedStateEvents)
                        {
                            updatedStateEvents = [self mutableStateEventsCopyLocked];
                        }

                        if (!updatedStateEvents[eventType])
                        {
                            updatedStateEvents[eventType] = [NSMutableArray array];
                        }
                        [updatedStateEvents[eventType] addObject:event];
                        break;
                    }
            }
        }
    }

    commitPendingDictionaryUpdates();

    if (_isLive && [mxSession.store respondsToSelector:@selector(storeStateForRoom:stateEvents:)])
    {
        shouldPersistState = YES;
        roomIdSnapshot = [_roomId copy];
        stateSnapshot = [self stateEventsSnapshotLocked];
    }
    [stateLock unlock];

    for (MXRoomMember *roomMember in conferenceUserUpdates)
    {
        [mxSession.callManager handleConferenceUserUpdate:roomMember inRoom:roomIdSnapshot ?: _roomId];
    }

    if (shouldPersistState)
    {
        [mxSession.store storeStateForRoom:roomIdSnapshot stateEvents:stateSnapshot];
    }
}

- (NSArray<MXEvent*> *)stateEventsWithType:(MXEventTypeString)eventType
{
    if (!eventType.length)
    {
        return nil;
    }

    [stateLock lock];
    NSArray *result = [stateEvents[eventType] copy];
    [stateLock unlock];
    return result;
}

- (MXRoomMember *)memberWithThirdPartyInviteToken:(NSString *)thirdPartyInviteToken
{
    if (!thirdPartyInviteToken.length)
    {
        return nil;
    }

    [stateLock lock];
    MXRoomMember *member = membersWithThirdPartyInviteTokenCache[thirdPartyInviteToken];
    [stateLock unlock];
    return member;
}

- (MXRoomThirdPartyInvite *)thirdPartyInviteWithToken:(NSString *)thirdPartyInviteToken
{
    if (!thirdPartyInviteToken.length)
    {
        return nil;
    }

    [stateLock lock];
    MXRoomThirdPartyInvite *invite = thirdPartyInvites[thirdPartyInviteToken];
    [stateLock unlock];
    return invite;
}

- (float)memberNormalizedPowerLevel:(NSString*)userId
{
    float powerLevel = 0;
    
    // Get the user from the member list of the room
    // If the app asks for information about a user id, it means that we already
    // have the MXRoomMember data
    MXRoomMember *member = [self.members memberWithUserId:userId];
    
    // Ignore banned and left (kicked) members
    if (member.membership != MXMembershipLeave && member.membership != MXMembershipBan)
    {
        float userPowerLevelFloat = [self powerLevelOfUserWithUserID:userId];
        if (maxPowerLevel && userPowerLevelFloat >= maxPowerLevel)
        {
            powerLevel = 1;
        }
        else
        {
            powerLevel = maxPowerLevel ? userPowerLevelFloat / maxPowerLevel : 1;
        }
    }
    
    return powerLevel;
}

- (NSInteger)powerLevelOfUserWithUserID:(NSString *)userId
{
    if ([self isMSC4289Supported])
    {
        if ([userId isEqualToString: [self creatorUserId]] || [[self additionalCreators] containsObject: userId])
        {
            return NSIntegerMax;
        }
    }
    
    // By default, use usersDefault
    NSInteger userPowerLevel = powerLevels.usersDefault;

    NSNumber *powerLevel;
    MXJSONModelSetNumber(powerLevel, powerLevels.users[userId]);
    if (powerLevel)
    {
        userPowerLevel = [powerLevel integerValue];
    }

    return userPowerLevel;
}

- (BOOL)isMSC4289Supported {
    NSArray<NSString*> *supportedRoomVersions = @[@"org.matrix.hydra.11",@"12"];
    if ([self roomVersion])
    {
        return [supportedRoomVersions containsObject:[self roomVersion]];
    }
    return NO;
}

# pragma mark - Conference call
- (BOOL)isOngoingConferenceCall
{
    [stateLock lock];
    BOOL isOngoingConferenceCall = NO;
    MXRoomMember *conferenceUserMember = [self.members memberWithUserId:self.conferenceUserId];
    if (conferenceUserMember)
    {
        isOngoingConferenceCall = (conferenceUserMember.membership == MXMembershipJoin);
    }
    [stateLock unlock];
    return isOngoingConferenceCall;
}

- (BOOL)isConferenceUserRoom
{
    [stateLock lock];
    BOOL isConferenceUserRoom = NO;
    if (_membersCount.members == 2 && [self.members memberWithUserId:self.conferenceUserId])
    {
        isConferenceUserRoom = YES;
    }
    [stateLock unlock];
    return isConferenceUserRoom;
}

- (NSString *)conferenceUserId
{
    [stateLock lock];
    if (!conferenceUserId)
    {
        conferenceUserId = [MXCallManager conferenceUserIdForRoom:_roomId];
    }
    NSString *value = conferenceUserId;
    [stateLock unlock];
    return value;
}

#pragma mark - NSCopying
- (id)copyWithZone:(NSZone *)zone
{
    [stateLock lock];
    MXRoomState *stateCopy = [[MXRoomState allocWithZone:zone] init];

    stateCopy->mxSession = mxSession;
    stateCopy->_roomId = [_roomId copyWithZone:zone];
    stateCopy->_isLive = _isLive;

    // Copy the state events. A deep copy of each events array is necessary.
    stateCopy->stateEvents = [[NSMutableDictionary allocWithZone:zone] initWithCapacity:stateEvents.count];
    for (NSString *key in stateEvents)
    {
        stateCopy->stateEvents[key] = [[NSMutableArray allocWithZone:zone] initWithArray:stateEvents[key]];
    }

    stateCopy->_members = [_members copyWithZone:zone];
    stateCopy->_membersCount = [_membersCount copyWithZone:zone];
    stateCopy->roomAliases = [[NSMutableDictionary allocWithZone:zone] initWithDictionary:roomAliases];
    stateCopy->thirdPartyInvites = [[NSMutableDictionary allocWithZone:zone] initWithDictionary:thirdPartyInvites];
    stateCopy->membersWithThirdPartyInviteTokenCache = [[NSMutableDictionary allocWithZone:zone] initWithDictionary:membersWithThirdPartyInviteTokenCache];
    stateCopy->_membership = _membership;
    stateCopy->powerLevels = [powerLevels copy];
    stateCopy->maxPowerLevel = maxPowerLevel;

    if (conferenceUserId)
    {
        stateCopy->conferenceUserId = [conferenceUserId copyWithZone:zone];
    }

    stateCopy->stateLock = [NSRecursiveLock new];
    [stateLock unlock];
    return stateCopy;
}

@end
